import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/local/local_store.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// Something a device told the [PatchPushServer].
sealed class DeviceSignal {
  const DeviceSignal(this.clientId);

  /// The updater's per-install id.
  final String clientId;
}

/// A device asked whether a patch is available.
class PatchCheckSignal extends DeviceSignal {
  /// Creates a [PatchCheckSignal].
  const PatchCheckSignal(
    super.clientId, {
    required this.arch,
    required this.currentPatchNumber,
    required this.offered,
  });

  /// The device's architecture (e.g. `aarch64`).
  final String arch;

  /// The patch the device is running, if any.
  final int? currentPatchNumber;

  /// Whether the server offered the device a patch.
  final bool offered;
}

/// A device reported a patch lifecycle event (download, install, failure).
class PatchEventSignal extends DeviceSignal {
  /// Creates a [PatchEventSignal].
  const PatchEventSignal(
    super.clientId, {
    required this.type,
    required this.patchNumber,
    this.message,
  });

  /// The event type, e.g. `__patch_download__` or `__patch_install__`.
  final String type;

  /// The patch the event is about.
  final int patchNumber;

  /// Extra detail for failures.
  final String? message;

  /// Whether this event means the device could not take the patch.
  bool get isFailure =>
      type == '__patch_install_failure__' || type == '__patch_update_failure__';
}

/// The patch a [PatchPushServer] hands out.
class PatchOffer {
  /// Creates a [PatchOffer].
  const PatchOffer({
    required this.appId,
    required this.releaseVersion,
    required this.platform,
    required this.number,
    required this.artifactsByArch,
    required this.rolledBackNumbers,
  });

  /// The app the patch belongs to.
  final String appId;

  /// The release version the patch applies to.
  final String releaseVersion;

  /// The platform the patch was built for.
  final ReleasePlatform platform;

  /// The patch number.
  final int number;

  /// Patch artifact rows from the [LocalStore], keyed by arch.
  final Map<String, Map<String, dynamic>> artifactsByArch;

  /// Patches of this release that have been rolled back.
  final List<int> rolledBackNumbers;
}

/// A short-lived HTTP endpoint speaking the updater's protocol, bound to
/// loopback only. It exists for the duration of a push and answers only for
/// the [offer] being pushed.
class PatchPushServer {
  PatchPushServer._(this._server, this.offer) {
    _server.listen(_handle);
  }

  /// Starts listening on `127.0.0.1:[port]`.
  static Future<PatchPushServer> start({
    required int port,
    required PatchOffer offer,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    return PatchPushServer._(server, offer);
  }

  final HttpServer _server;

  /// The patch being pushed.
  final PatchOffer offer;

  final _signals = StreamController<DeviceSignal>.broadcast();

  /// Patch checks and events as devices send them.
  Stream<DeviceSignal> get signals => _signals.stream;

  /// Stops listening.
  Future<void> close() async {
    await _server.close(force: true);
    await _signals.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/api/v1/patches/check') {
        await _check(request);
      } else if (request.method == 'POST' && path == '/api/v1/patches/events') {
        await _event(request);
      } else if (request.method == 'GET' && path.startsWith('/patches/')) {
        await _download(request, path.substring('/patches/'.length));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } on Exception catch (error) {
      logger.detail('[push] ${request.method} ${request.uri} failed: $error');
      response.statusCode = HttpStatus.badRequest;
    }
    await response.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async =>
      json.decode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;

  Future<void> _check(HttpRequest request) async {
    final body = await _readJson(request);
    logger.detail('[push] patch check: $body');
    final arch = body['arch'] as String;
    final artifact = offer.artifactsByArch[arch];
    final matches =
        body['app_id'] == offer.appId &&
        body['release_version'] == offer.releaseVersion &&
        body['platform'] == offer.platform.name &&
        artifact != null;

    request.response.headers.contentType = ContentType.json;
    request.response.write(
      json.encode({
        'patch_available': matches,
        if (matches)
          'patch': {
            'number': offer.number,
            'hash': artifact['hash'],
            'hash_signature': artifact['hash_signature'],
            'download_url':
                'http://${request.requestedUri.authority}'
                '/patches/${artifact['id']}',
          },
        'rolled_back_patch_numbers': offer.rolledBackNumbers,
      }),
    );
    _signals.add(
      PatchCheckSignal(
        body['client_id'] as String? ?? '',
        arch: arch,
        currentPatchNumber: body['current_patch_number'] as int?,
        offered: matches,
      ),
    );
  }

  Future<void> _event(HttpRequest request) async {
    final body = await _readJson(request);
    logger.detail('[push] event: $body');
    final event = body['event'] as Map<String, dynamic>;
    request.response.statusCode = HttpStatus.created;
    _signals.add(
      PatchEventSignal(
        event['client_id'] as String? ?? '',
        type: event['type'] as String,
        patchNumber: event['patch_number'] as int,
        message: event['message'] as String?,
      ),
    );
  }

  /// Serves a patch artifact, honoring `Range` so interrupted downloads
  /// resume the way the updater expects.
  Future<void> _download(HttpRequest request, String id) async {
    final artifact = offer.artifactsByArch.values.firstWhereOrNull(
      (a) => '${a['id']}' == id,
    );
    final response = request.response;
    if (artifact == null) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final file = File(artifact['path'] as String);
    final length = file.lengthSync();
    final range = RegExp(
      r'^bytes=(\d+)-$',
    ).firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    final start = range == null ? 0 : int.parse(range.group(1)!);
    if (range != null) {
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${length - 1}/$length',
        );
    }
    response
      ..headers.contentType = ContentType.binary
      ..contentLength = length - start;
    await response.addStream(file.openRead(start));
  }
}

/// Pushes a locally stored patch straight to devices: no hosted server, no
/// account. For each device it opens a loopback-only endpoint, tunnels the
/// device to it, relaunches the app so the updater pulls the patch, then
/// relaunches again and waits until the app reports it booted the patch.
class LocalPatchPusher {
  /// Creates a pusher reading from [store].
  LocalPatchPusher(this.store);

  /// The store holding the release and patch.
  final LocalStore store;

  /// How long to wait for the app to check in after each launch.
  static const checkInTimeout = Duration(seconds: 90);

  /// Pushes patch [patchNumber] of [releaseVersion] to [deviceIds], or to
  /// every connected device when [allDevices] is set. Returns an exit code.
  Future<int> push({
    required String appId,
    required String releaseVersion,
    required int patchNumber,
    required ReleasePlatform platform,
    required List<String> deviceIds,
    required bool allDevices,
  }) async {
    if (platform != ReleasePlatform.android) {
      logger.err(
        'Pushing to devices is supported for Android only so far '
        '(got ${platform.displayName}).',
      );
      return ExitCode.unavailable.code;
    }

    final release = store.find(
      'releases',
      (r) => r['app_id'] == appId && r['version'] == releaseVersion,
    );
    if (release == null) {
      logger.err('No release $releaseVersion found for app $appId.');
      return ExitCode.usage.code;
    }
    final patch = store.find(
      'patches',
      (p) => p['release_id'] == release['id'] && p['number'] == patchNumber,
    );
    if (patch == null) {
      logger.err('Release $releaseVersion has no patch $patchNumber.');
      return ExitCode.usage.code;
    }
    if (patch['is_rolled_back'] == true) {
      logger.err(
        'Patch $patchNumber is rolled back. Run '
        '${lightCyan.wrap('shorebird patches rollforward')} first.',
      );
      return ExitCode.usage.code;
    }

    final aab = store.find(
      'release_artifacts',
      (a) =>
          a['release_id'] == release['id'] &&
          a['platform'] == platform.name &&
          a['arch'] == 'aab',
    );
    if (aab == null) {
      logger.err('Release $releaseVersion has no Android app bundle.');
      return ExitCode.software.code;
    }
    final package = await bundletool.getPackageName(aab['path'] as String);

    final offer = PatchOffer(
      appId: appId,
      releaseVersion: releaseVersion,
      platform: platform,
      number: patchNumber,
      artifactsByArch: {
        for (final a in store.where(
          'patch_artifacts',
          (a) =>
              a['patch_id'] == patch['id'] &&
              a['platform'] == platform.name &&
              a['uploaded'] == true,
        ))
          a['arch'] as String: a,
      },
      rolledBackNumbers: store
          .where(
            'patches',
            (p) =>
                p['release_id'] == release['id'] && p['is_rolled_back'] == true,
          )
          .map((p) => p['number'] as int)
          .toList(),
    );

    final connected = await adb.devices();
    final List<String> targets;
    if (allDevices) {
      targets = [
        for (final id in connected)
          if (await adb.isInstalled(package: package, deviceId: id)) id,
      ];
      final skipped = connected.where((id) => !targets.contains(id));
      for (final id in skipped) {
        logger.info('Skipping $id: $package is not installed.');
      }
      if (targets.isEmpty) {
        logger.err('No connected device has $package installed.');
        _hintInstall(releaseVersion);
        return ExitCode.unavailable.code;
      }
    } else {
      for (final id in deviceIds) {
        if (!connected.contains(id)) {
          logger.err(
            'Device $id is not connected. Connected: '
            '${connected.isEmpty ? 'none' : connected.join(', ')}',
          );
          return ExitCode.unavailable.code;
        }
        if (!await adb.isInstalled(package: package, deviceId: id)) {
          logger.err('$package is not installed on $id.');
          _hintInstall(releaseVersion, deviceId: id);
          return ExitCode.unavailable.code;
        }
      }
      targets = deviceIds;
    }

    final port = shorebirdEnv.localPushPort;
    final PatchPushServer server;
    try {
      server = await PatchPushServer.start(port: port, offer: offer);
    } on SocketException catch (error) {
      logger.err('Could not listen on 127.0.0.1:$port: ${error.message}');
      return ExitCode.unavailable.code;
    }

    logger.info(
      'Pushing patch $patchNumber (release $releaseVersion) to '
      '${targets.length} device${targets.length == 1 ? '' : 's'}.',
    );
    final failed = <String>[];
    try {
      for (final deviceId in targets) {
        final ok = await _pushToAndroidDevice(
          server: server,
          deviceId: deviceId,
          package: package,
          port: port,
        );
        if (!ok) failed.add(deviceId);
      }
    } finally {
      await server.close();
    }

    if (failed.isNotEmpty) {
      logger.err('Push failed on: ${failed.join(', ')}');
      return ExitCode.software.code;
    }
    logger.success(
      '✅ Patch $patchNumber is running on ${targets.join(', ')}.',
    );
    return ExitCode.success.code;
  }

  void _hintInstall(String releaseVersion, {String? deviceId}) {
    logger.info(
      'Install the release first with '
      '''${lightCyan.wrap('shorebird preview --release-version=$releaseVersion --platform=android${deviceId == null ? '' : ' -d $deviceId'}')}.''',
    );
  }

  Future<bool> _pushToAndroidDevice({
    required PatchPushServer server,
    required String deviceId,
    required String package,
    required int port,
  }) async {
    final number = server.offer.number;
    final progress = logger.progress('[$deviceId] Connecting');
    // Collected before relaunching so nothing the app sends is missed.
    final signals = <DeviceSignal>[];
    final newSignal = StreamController<void>.broadcast();
    final subscription = server.signals.listen((signal) {
      signals.add(signal);
      newSignal.add(null);
    });

    Future<DeviceSignal?> waitFor(bool Function(DeviceSignal) test) async {
      final deadline = DateTime.now().add(checkInTimeout);
      var seen = 0;
      while (true) {
        for (; seen < signals.length; seen++) {
          if (test(signals[seen])) return signals[seen];
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining.isNegative) return null;
        await newSignal.stream.first
            .timeout(remaining, onTimeout: () {})
            .catchError((_) {});
      }
    }

    Future<void> relaunch() async {
      signals.clear();
      await adb.forceStop(package: package, deviceId: deviceId);
      await adb.startApp(package: package, deviceId: deviceId);
    }

    bool isFailure(DeviceSignal s) =>
        s is PatchEventSignal && s.isFailure && s.patchNumber == number;
    bool isRunning(DeviceSignal s) =>
        (s is PatchCheckSignal && s.currentPatchNumber == number) ||
        (s is PatchEventSignal &&
            s.type == '__patch_install__' &&
            s.patchNumber == number);

    try {
      await adb.reverse(deviceId: deviceId, port: port);

      progress.update('[$deviceId] Launching app to download patch $number');
      await relaunch();
      final downloaded = await waitFor(
        (s) =>
            isFailure(s) ||
            isRunning(s) ||
            (s is PatchCheckSignal && !s.offered) ||
            (s is PatchEventSignal &&
                s.type == '__patch_download__' &&
                s.patchNumber == number),
      );
      if (downloaded == null) {
        progress.fail('[$deviceId] The app never checked for a patch.');
        logger.info(
          'Make sure the release was built with base_url: '
          'http://127.0.0.1:$port in shorebird.yaml and auto_update is on.',
        );
        return false;
      }
      if (downloaded is PatchCheckSignal && !downloaded.offered) {
        progress.fail(
          '[$deviceId] The app is not on this release, or patch $number has '
          'no ${downloaded.arch} build.',
        );
        return false;
      }
      if (isFailure(downloaded)) {
        progress.fail(
          '[$deviceId] Patch rejected: '
          '${(downloaded as PatchEventSignal).message ?? downloaded.type}',
        );
        return false;
      }
      if (!isRunning(downloaded)) {
        progress.update('[$deviceId] Restarting app to apply patch $number');
        await relaunch();
        final booted = await waitFor((s) => isFailure(s) || isRunning(s));
        if (booted == null || isFailure(booted)) {
          progress.fail(
            '[$deviceId] Patch $number downloaded but did not boot.',
          );
          return false;
        }
      }
      progress.complete('[$deviceId] Running patch $number');
      return true;
    } on Exception catch (error) {
      progress.fail('[$deviceId] $error');
      return false;
    } finally {
      await subscription.cancel();
      await newSignal.close();
      await adb.removeReverse(deviceId: deviceId, port: port);
    }
  }
}
