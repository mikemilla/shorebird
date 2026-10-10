import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shorebird_cli/src/executables/devicectl/apple_device.dart';
import 'package:shorebird_cli/src/executables/executables.dart';
import 'package:shorebird_cli/src/local/local_store.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
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

/// A short-lived HTTP endpoint speaking the updater's protocol. It exists for
/// the duration of a push and answers only for the [offer] being pushed.
class PatchPushServer {
  PatchPushServer._(this._servers, this.offer) {
    for (final server in _servers) {
      server.listen(_handle);
    }
  }

  /// Starts listening on [port] at each of [addresses] (loopback by default).
  static Future<PatchPushServer> start({
    required int port,
    required PatchOffer offer,
    List<InternetAddress>? addresses,
  }) async {
    final servers = <HttpServer>[];
    try {
      for (final address in addresses ?? [InternetAddress.loopbackIPv4]) {
        servers.add(await HttpServer.bind(address, port));
      }
    } on SocketException {
      for (final server in servers) {
        await server.close(force: true);
      }
      rethrow;
    }
    return PatchPushServer._(servers, offer);
  }

  final List<HttpServer> _servers;

  /// The patch being pushed.
  final PatchOffer offer;

  final _signals = StreamController<DeviceSignal>.broadcast();

  /// Patch checks and events as devices send them.
  Stream<DeviceSignal> get signals => _signals.stream;

  /// Stops listening.
  Future<void> close() async {
    for (final server in _servers) {
      await server.close(force: true);
    }
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

/// One device a patch is being pushed to.
abstract class _PushTarget {
  _PushTarget(this.id, this.label);

  /// The id the user passed (adb serial or iOS UDID).
  final String id;

  /// How the device is shown in progress output.
  final String label;

  /// Makes the device able to reach the push server.
  Future<void> connect() async {}

  /// Kills and restarts the app so the updater checks in.
  Future<void> relaunch();

  /// Undoes [connect].
  Future<void> disconnect() async {}
}

class _AndroidTarget extends _PushTarget {
  _AndroidTarget(String serial, this.package, this.port)
    : super(serial, serial);

  final String package;
  final int port;

  @override
  Future<void> connect() => adb.reverse(deviceId: id, port: port);

  @override
  Future<void> relaunch() async {
    await adb.forceStop(package: package, deviceId: id);
    await adb.startApp(package: package, deviceId: id);
  }

  @override
  Future<void> disconnect() => adb.removeReverse(deviceId: id, port: port);
}

class _IosTarget extends _PushTarget {
  _IosTarget(super.id, super.label, this.bundleId);

  final String bundleId;

  @override
  Future<void> relaunch() =>
      devicectl.relaunchApp(deviceId: id, bundleId: bundleId);
}

/// Pushes a locally stored patch straight to devices: no hosted server, no
/// account. It opens a short-lived endpoint, relaunches the app on each target
/// so the updater pulls the patch, then relaunches again and waits until the
/// app reports it booted the patch.
///
/// Android devices reach the endpoint through `adb reverse` on loopback, so
/// nothing is exposed on the network. iPhones reach it over Wi-Fi at the
/// `base_url` baked into iOS builds, so for iOS the endpoint binds this
/// machine's Wi-Fi addresses (only, and only while the push runs).
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
    if (platform != ReleasePlatform.android &&
        platform != ReleasePlatform.ios) {
      logger.err(
        'Pushing to devices supports Android and iOS '
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

    final port = shorebirdEnv.localPushPort;
    final List<_PushTarget>? targets;
    final List<InternetAddress> addresses;
    try {
      if (platform == ReleasePlatform.android) {
        targets = await _androidTargets(
          release: release,
          releaseVersion: releaseVersion,
          deviceIds: deviceIds,
          allDevices: allDevices,
          port: port,
        );
        addresses = [InternetAddress.loopbackIPv4];
      } else {
        targets = await _iosTargets(
          release: release,
          releaseVersion: releaseVersion,
          deviceIds: deviceIds,
          allDevices: allDevices,
        );
        addresses = await _wifiAddresses();
      }
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }
    if (targets == null) return ExitCode.unavailable.code;

    final PatchPushServer server;
    try {
      server = await PatchPushServer.start(
        port: port,
        offer: offer,
        addresses: addresses,
      );
    } on SocketException catch (error) {
      logger.err('Could not listen on port $port: ${error.message}');
      return ExitCode.unavailable.code;
    }
    logger.detail(
      '[push] listening on ${addresses.map((a) => a.address).join(', ')}',
    );

    logger.info(
      'Pushing patch $patchNumber (release $releaseVersion) to '
      '${targets.length} device${targets.length == 1 ? '' : 's'}.',
    );
    final failed = <String>[];
    try {
      for (final target in targets) {
        if (!await _pushTo(server, target)) failed.add(target.label);
      }
    } finally {
      await server.close();
    }

    if (failed.isNotEmpty) {
      logger.err('Push failed on: ${failed.join(', ')}');
      return ExitCode.software.code;
    }
    logger.success(
      '✅ Patch $patchNumber is running on '
      '${targets.map((t) => t.label).join(', ')}.',
    );
    return ExitCode.success.code;
  }

  Map<String, dynamic>? _releaseArtifact(
    Map<String, dynamic> release,
    ReleasePlatform platform,
    String arch,
  ) => store.find(
    'release_artifacts',
    (a) =>
        a['release_id'] == release['id'] &&
        a['platform'] == platform.name &&
        a['arch'] == arch,
  );

  Future<List<_PushTarget>?> _androidTargets({
    required Map<String, dynamic> release,
    required String releaseVersion,
    required List<String> deviceIds,
    required bool allDevices,
    required int port,
  }) async {
    final aab = _releaseArtifact(release, ReleasePlatform.android, 'aab');
    if (aab == null) {
      throw Exception('Release $releaseVersion has no Android app bundle.');
    }
    final package = await bundletool.getPackageName(aab['path'] as String);
    final connected = await adb.devices();
    final ids = allDevices ? connected : deviceIds;
    final targets = <_PushTarget>[];
    for (final id in ids) {
      if (!connected.contains(id)) {
        logger.err(
          'Android device $id is not connected. Connected: '
          '${connected.isEmpty ? 'none' : connected.join(', ')}',
        );
        return null;
      }
      if (!await adb.isInstalled(package: package, deviceId: id)) {
        if (allDevices) {
          logger.info('Skipping $id: $package is not installed.');
          continue;
        }
        logger.err('$package is not installed on $id.');
        _hintInstall(releaseVersion, ReleasePlatform.android, deviceId: id);
        return null;
      }
      targets.add(_AndroidTarget(id, package, port));
    }
    if (targets.isEmpty) {
      logger.err('No connected Android device has $package installed.');
      _hintInstall(releaseVersion, ReleasePlatform.android);
      return null;
    }
    return targets;
  }

  Future<List<_PushTarget>?> _iosTargets({
    required Map<String, dynamic> release,
    required String releaseVersion,
    required List<String> deviceIds,
    required bool allDevices,
  }) async {
    final runner = _releaseArtifact(release, ReleasePlatform.ios, 'runner');
    if (runner == null) {
      throw Exception(
        'Release $releaseVersion has no signed Runner.app '
        '(was it built with --no-codesign?).',
      );
    }
    final bundleId = await _bundleIdFromRunnerZip(runner['path'] as String);
    final devices = await devicectl.listAvailableIosDevices();
    final List<AppleDevice> chosen;
    if (allDevices) {
      chosen = devices;
    } else {
      chosen = [];
      for (final id in deviceIds) {
        final device = devices.firstWhereOrNull(
          (d) => d.udid == id || d.name.toLowerCase() == id.toLowerCase(),
        );
        if (device == null) {
          logger
            ..err(
              'iOS device $id is not available. Available: '
              '${devices.isEmpty ? 'none' : devices.join(', ')}',
            )
            ..info(
              'Unlock the device and keep it on the same Wi-Fi as this Mac.',
            );
          return null;
        }
        chosen.add(device);
      }
    }
    final targets = <_PushTarget>[];
    for (final device in chosen) {
      if (!await devicectl.isAppInstalled(
        deviceId: device.udid,
        bundleId: bundleId,
      )) {
        if (allDevices) {
          logger.info('Skipping ${device.name}: $bundleId is not installed.');
          continue;
        }
        logger.err('$bundleId is not installed on ${device.name}.');
        _hintInstall(
          releaseVersion,
          ReleasePlatform.ios,
          deviceId: device.udid,
        );
        return null;
      }
      targets.add(_IosTarget(device.udid, device.name, bundleId));
    }
    if (targets.isEmpty) {
      logger.err('No available iOS device has $bundleId installed.');
      _hintInstall(releaseVersion, ReleasePlatform.ios);
      return null;
    }
    return targets;
  }

  /// Reads `CFBundleIdentifier` from the release's zipped Runner.app.
  static Future<String> _bundleIdFromRunnerZip(String zipPath) async {
    final archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    final plists = archive.files.where(
      (f) => f.isFile && p.basename(f.name) == 'Info.plist',
    );
    final infoPlist = plists.sortedBy<num>((f) => f.name.split('/').length);
    if (infoPlist.isEmpty) throw Exception('Runner.app has no Info.plist.');
    final tempDir = Directory.systemTemp.createTempSync();
    try {
      final plist = File(p.join(tempDir.path, 'Info.plist'))
        ..writeAsBytesSync(infoPlist.first.content);
      final result = await process.run('plutil', [
        '-extract',
        'CFBundleIdentifier',
        'raw',
        plist.path,
      ]);
      if (result.exitCode != 0) {
        throw Exception('Unable to read bundle id: ${result.stderr}');
      }
      return '${result.stdout}'.trim();
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  }

  /// The addresses of the interface carrying the default route (Wi-Fi or
  /// Ethernet), which is how an iPhone on the same network reaches this Mac.
  static Future<List<InternetAddress>> _wifiAddresses() async {
    final route = await process.run('route', ['-n', 'get', 'default']);
    final name = RegExp(
      r'interface:\s*(\S+)',
    ).firstMatch('${route.stdout}')?.group(1);
    if (name == null) throw Exception('This Mac is not on a network.');
    final interfaces = await NetworkInterface.list();
    final addresses = [
      for (final interface in interfaces.where((i) => i.name == name))
        ...interface.addresses.where((a) => !a.isLinkLocal),
    ];
    if (addresses.isEmpty) throw Exception('$name has no usable address.');
    return addresses;
  }

  void _hintInstall(
    String releaseVersion,
    ReleasePlatform platform, {
    String? deviceId,
  }) {
    final command =
        'shorebird preview --release-version=$releaseVersion '
        '--platform=${platform.name}'
        '${deviceId == null ? '' : ' -d $deviceId'}';
    logger.info('Install the release first with ${lightCyan.wrap(command)}.');
  }

  Future<bool> _pushTo(PatchPushServer server, _PushTarget target) async {
    final number = server.offer.number;
    final name = target.label;
    final progress = logger.progress('[$name] Connecting');
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
      await target.relaunch();
    }

    bool isFailure(DeviceSignal s) =>
        s is PatchEventSignal && s.isFailure && s.patchNumber == number;
    bool isRunning(DeviceSignal s) =>
        (s is PatchCheckSignal && s.currentPatchNumber == number) ||
        (s is PatchEventSignal &&
            s.type == '__patch_install__' &&
            s.patchNumber == number);

    try {
      await target.connect();

      progress.update('[$name] Launching app to download patch $number');
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
        progress.fail('[$name] The app never checked for a patch.');
        logger.info(
          target is _IosTarget
              ? 'Make sure the iPhone is on the same Wi-Fi as this Mac and '
                    'the app was allowed Local Network access (Settings > '
                    'Privacy & Security > Local Network).'
              : 'Make sure the release was built in local mode '
                    '(base_url in shorebird.yaml) and auto_update is on.',
        );
        return false;
      }
      if (downloaded is PatchCheckSignal && !downloaded.offered) {
        progress.fail(
          '[$name] The app is not on this release, or patch $number has '
          'no ${downloaded.arch} build.',
        );
        return false;
      }
      if (isFailure(downloaded)) {
        progress.fail(
          '[$name] Patch rejected: '
          '${(downloaded as PatchEventSignal).message ?? downloaded.type}',
        );
        return false;
      }
      if (!isRunning(downloaded)) {
        progress.update('[$name] Restarting app to apply patch $number');
        await relaunch();
        final booted = await waitFor((s) => isFailure(s) || isRunning(s));
        if (booted == null || isFailure(booted)) {
          progress.fail('[$name] Patch $number downloaded but did not boot.');
          return false;
        }
      }
      progress.complete('[$name] Running patch $number');
      return true;
    } on Exception catch (error) {
      progress.fail('[$name] $error');
      return false;
    } finally {
      await subscription.cancel();
      await newSignal.close();
      await target.disconnect();
    }
  }
}
