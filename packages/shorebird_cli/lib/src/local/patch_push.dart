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

/// When a pushed patch takes effect.
enum ApplyMode {
  /// Relaunch the app twice so it is running the patch when the push ends.
  now('now'),

  /// Leave the app alone. The patch downloads the next time someone opens the
  /// app and takes effect on the launch after that.
  nextLaunch('next-launch');

  const ApplyMode(this.cliName);

  /// The value of `--apply` that selects this mode.
  final String cliName;

  /// Parses a `--apply` value.
  static ApplyMode parse(String value) =>
      values.firstWhere((m) => m.cliName == value);
}

/// How an app should present a patch to its user. Stored per patch and served
/// to apps from the policy endpoint; `package:shorebird_update_ui` acts on it.
enum UpdateUi {
  /// No UI. The patch downloads in the background and applies next launch.
  silent('silent'),

  /// A banner offering to update now (download, then restart).
  bannerNow('banner-now'),

  /// A banner saying the update applies the next time the app opens.
  bannerNextLaunch('banner-next-launch'),

  /// A blocking screen until the patch is installed.
  wall('wall');

  const UpdateUi(this.cliName);

  /// The value of `--update-ui` (and the policy endpoint) for this style.
  final String cliName;

  /// Parses a `--update-ui` value.
  static UpdateUi parse(String value) =>
      values.firstWhere((u) => u.cliName == value);
}

/// Something a device told the [PatchPushServer].
sealed class DeviceSignal {
  const DeviceSignal(this.clientId, this.via);

  /// The updater's per-install id.
  final String clientId;

  /// Which listener the device came in through: an Android device's serial
  /// (each gets its own tunnel), or [PatchPushServer.wifi] for iPhones.
  final String via;
}

/// A device asked whether a patch is available.
class PatchCheckSignal extends DeviceSignal {
  /// Creates a [PatchCheckSignal].
  const PatchCheckSignal(
    super.clientId,
    super.via, {
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
    super.clientId,
    super.via, {
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

/// An app read the update policy (how to present the patch).
class PolicySignal extends DeviceSignal {
  /// Creates a [PolicySignal].
  const PolicySignal(String via) : super('', via);
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
    this.updateUi = UpdateUi.silent,
    this.wallPatchNumber,
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

  /// How apps should present this patch.
  final UpdateUi updateUi;

  /// The newest patch, up to [number], pushed with `--update-ui wall`. Apps
  /// behind it should block until they update, whatever [updateUi] says.
  final int? wallPatchNumber;
}

/// A short-lived HTTP endpoint speaking the updater's protocol, plus a small
/// policy endpoint apps can read. It exists for the duration of a push and
/// answers only for the [offer] being pushed.
class PatchPushServer {
  /// Creates a server for [offer]; it listens once a listen method is called.
  PatchPushServer(this.offer);

  /// The [DeviceSignal.via] of devices that reached a Wi-Fi listener.
  static const wifi = 'wifi';

  /// The patch being pushed.
  final PatchOffer offer;

  final _servers = <HttpServer>[];
  final _signals = StreamController<DeviceSignal>.broadcast();

  /// Patch checks and events as devices send them.
  Stream<DeviceSignal> get signals => _signals.stream;

  /// Listens on `127.0.0.1` at a free port for the Android device [serial],
  /// and returns the port to `adb reverse` to.
  Future<int> listenForAndroid(String serial) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _listen(server, serial);
    return server.port;
  }

  /// Listens on [port] at each of [addresses] (this Mac's Wi-Fi addresses)
  /// for iPhones.
  Future<void> listenForWifi(List<InternetAddress> addresses, int port) async {
    for (final address in addresses) {
      _listen(await HttpServer.bind(address, port), wifi);
    }
  }

  void _listen(HttpServer server, String via) {
    _servers.add(server);
    server.listen((request) => _handle(request, via));
  }

  /// Stops listening.
  Future<void> close() async {
    for (final server in _servers) {
      await server.close(force: true);
    }
    await _signals.close();
  }

  Future<void> _handle(HttpRequest request, String via) async {
    final response = request.response;
    try {
      final path = request.uri.path;
      if (request.method == 'POST' && path == '/api/v1/patches/check') {
        await _check(request, via);
      } else if (request.method == 'POST' && path == '/api/v1/patches/events') {
        await _event(request, via);
      } else if (request.method == 'GET' && path == '/api/v1/patches/policy') {
        _policy(request, via);
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

  bool _isOfferFor(Object? appId, Object? releaseVersion, Object? platform) =>
      appId == offer.appId &&
      releaseVersion == offer.releaseVersion &&
      platform == offer.platform.name;

  Future<void> _check(HttpRequest request, String via) async {
    final body = await _readJson(request);
    logger.detail('[push] patch check via $via: $body');
    final arch = body['arch'] as String;
    final artifact = offer.artifactsByArch[arch];
    final matches =
        _isOfferFor(
          body['app_id'],
          body['release_version'],
          body['platform'],
        ) &&
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
        via,
        arch: arch,
        currentPatchNumber: body['current_patch_number'] as int?,
        offered: matches,
      ),
    );
  }

  Future<void> _event(HttpRequest request, String via) async {
    final body = await _readJson(request);
    logger.detail('[push] event via $via: $body');
    final event = body['event'] as Map<String, dynamic>;
    request.response.statusCode = HttpStatus.created;
    _signals.add(
      PatchEventSignal(
        event['client_id'] as String? ?? '',
        via,
        type: event['type'] as String,
        patchNumber: event['patch_number'] as int,
        message: event['message'] as String?,
      ),
    );
  }

  /// `GET /api/v1/patches/policy?app_id=&release_version=&platform=`
  ///
  /// Not part of the updater protocol: the updater never reads it. Apps call
  /// it themselves to learn how to present the patch (see [UpdateUi]).
  void _policy(HttpRequest request, String via) {
    final q = request.uri.queryParameters;
    logger.detail('[push] policy via $via: $q');
    final matches = _isOfferFor(
      q['app_id'],
      q['release_version'],
      q['platform'],
    );
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      json.encode({
        'latest_patch_number': matches ? offer.number : null,
        'update_ui': matches ? offer.updateUi.cliName : null,
        'wall_patch_number': matches ? offer.wallPatchNumber : null,
      }),
    );
    _signals.add(PolicySignal(via));
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

  /// Whether [signal] came from this device.
  bool owns(DeviceSignal signal);

  /// Makes the device able to reach [server].
  Future<void> connect(PatchPushServer server) async {}

  /// Kills and restarts the app so the updater checks in.
  Future<void> relaunch();

  /// Undoes [connect].
  Future<void> disconnect() async {}
}

/// An Android device. It gets its own loopback listener, and `adb reverse`
/// maps the port baked into the app to it, so its signals are unambiguous.
class _AndroidTarget extends _PushTarget {
  _AndroidTarget(String serial, this.package, this.devicePort)
    : super(serial, serial);

  final String package;
  final int devicePort;
  bool _connected = false;

  @override
  bool owns(DeviceSignal signal) => signal.via == id;

  @override
  Future<void> connect(PatchPushServer server) async {
    final hostPort = await server.listenForAndroid(id);
    await adb.reverse(deviceId: id, devicePort: devicePort, hostPort: hostPort);
    _connected = true;
  }

  @override
  Future<void> relaunch() async {
    await adb.forceStop(package: package, deviceId: id);
    await adb.startApp(package: package, deviceId: id);
  }

  @override
  Future<void> disconnect() async {
    if (_connected) await adb.removeReverse(deviceId: id, port: devicePort);
  }
}

/// An iPhone. iPhones share the Wi-Fi listener, so a signal can't be tied to
/// one of several iPhones; pushes to them are told apart by client id.
class _IosTarget extends _PushTarget {
  _IosTarget(super.id, super.label, this.bundleId);

  final String bundleId;

  @override
  bool owns(DeviceSignal signal) => signal.via == PatchPushServer.wifi;

  @override
  Future<void> relaunch() =>
      devicectl.relaunchApp(deviceId: id, bundleId: bundleId);
}

/// Pushes a locally stored patch straight to devices: no hosted server, no
/// account.
///
/// Android devices reach the push listener through `adb reverse` on
/// loopback, so nothing is exposed on the network. iPhones reach it over
/// Wi-Fi at the `base_url` baked into iOS builds, so for iOS it also binds
/// this Mac's Wi-Fi addresses (only, and only while the push runs).
class LocalPatchPusher {
  /// Creates a pusher reading from [store].
  LocalPatchPusher(this.store);

  /// The store holding the release and patch.
  final LocalStore store;

  /// How long `--apply now` waits for the app after each relaunch.
  static const checkInTimeout = Duration(seconds: 90);

  /// How long `--apply next-launch` waits for someone to open the app.
  static const nextLaunchTimeout = Duration(minutes: 10);

  /// How long `--apply next-launch` stays open after a device downloads the
  /// patch, so the app can still read the update policy. The updater often
  /// finishes downloading before the app gets around to asking.
  static const policyGrace = Duration(seconds: 20);

  /// Sets how apps present patch [patchNumber] of [releaseVersion].
  void setUpdateUi({
    required String appId,
    required String releaseVersion,
    required int patchNumber,
    required UpdateUi updateUi,
  }) {
    final release = store.find(
      'releases',
      (r) => r['app_id'] == appId && r['version'] == releaseVersion,
    );
    final patch = release == null
        ? null
        : store.find(
            'patches',
            (p) =>
                p['release_id'] == release['id'] && p['number'] == patchNumber,
          );
    if (patch == null) return;
    patch['update_ui'] = updateUi.cliName;
    store.save();
  }

  /// Pushes patch [patchNumber] of [releaseVersion] to [deviceIds], or to
  /// every reachable device when [allDevices] is set. Returns an exit code.
  Future<int> push({
    required String appId,
    required String releaseVersion,
    required int patchNumber,
    required ReleasePlatform platform,
    required List<String> deviceIds,
    required bool allDevices,
    ApplyMode apply = ApplyMode.now,
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

    bool hasBuild(Map<String, dynamic> p) =>
        store.find(
          'patch_artifacts',
          (a) =>
              a['patch_id'] == p['id'] &&
              a['platform'] == platform.name &&
              a['uploaded'] == true,
        ) !=
        null;
    final wallNumbers = store
        .where(
          'patches',
          (p) =>
              p['release_id'] == release['id'] &&
              p['update_ui'] == UpdateUi.wall.cliName &&
              p['is_rolled_back'] != true &&
              (p['number'] as int) <= patchNumber &&
              hasBuild(p),
        )
        .map((p) => p['number'] as int);

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
      updateUi: UpdateUi.parse(
        patch['update_ui'] as String? ?? UpdateUi.silent.cliName,
      ),
      wallPatchNumber: wallNumbers.isEmpty ? null : wallNumbers.max,
    );

    final port = shorebirdEnv.localPushPort;
    final List<_PushTarget>? targets;
    try {
      targets = platform == ReleasePlatform.android
          ? await _androidTargets(
              release: release,
              releaseVersion: releaseVersion,
              deviceIds: deviceIds,
              allDevices: allDevices,
              port: port,
            )
          : await _iosTargets(
              release: release,
              releaseVersion: releaseVersion,
              deviceIds: deviceIds,
              allDevices: allDevices,
            );
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }
    if (targets == null) return ExitCode.unavailable.code;

    final server = PatchPushServer(offer);
    if (platform == ReleasePlatform.ios) {
      try {
        final addresses = await _wifiAddresses();
        await server.listenForWifi(addresses, port);
        logger.detail(
          '[push] listening on ${addresses.map((a) => a.address).join(', ')}',
        );
      } on Exception catch (error) {
        await server.close();
        logger.err('Could not listen for iPhones on port $port: $error');
        return ExitCode.unavailable.code;
      }
    }

    logger.info(
      'Pushing patch $patchNumber (${offer.updateUi.cliName}) '
      'of release $releaseVersion to ${targets.length} '
      'device${targets.length == 1 ? '' : 's'}.',
    );
    final List<String> failed;
    try {
      failed = switch (apply) {
        ApplyMode.now => [
          for (final target in targets)
            if (!await _pushNow(server, target)) target.label,
        ],
        ApplyMode.nextLaunch => await _pushNextLaunch(server, targets),
      };
    } finally {
      for (final target in targets) {
        await target.disconnect();
      }
      await server.close();
    }

    if (failed.isNotEmpty) {
      logger.err('Push failed on: ${failed.join(', ')}');
      return ExitCode.software.code;
    }
    final labels = targets.map((t) => t.label).join(', ');
    logger.success(
      apply == ApplyMode.now
          ? '✅ Patch $patchNumber is running on $labels.'
          : '✅ Patch $patchNumber is downloaded on $labels and takes effect '
                'the next time the app starts.',
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

  /// Collects the signals that pass [owns], so a wait never misses one that
  /// arrived before it started.
  _SignalLog _log(PatchPushServer server, bool Function(DeviceSignal) owns) =>
      _SignalLog(server.signals.where(owns));

  bool _isFailure(DeviceSignal s, int number) =>
      s is PatchEventSignal && s.isFailure && s.patchNumber == number;

  bool _isRunning(DeviceSignal s, int number) =>
      (s is PatchCheckSignal && s.currentPatchNumber == number) ||
      (s is PatchEventSignal &&
          s.type == '__patch_install__' &&
          s.patchNumber == number);

  bool _isDownloaded(DeviceSignal s, int number) =>
      s is PatchEventSignal &&
      s.type == '__patch_download__' &&
      s.patchNumber == number;

  /// Reports a signal that ends a wait without the patch landing. Returns
  /// false if [signal] is not one of those.
  bool _reportProblem(Progress progress, String name, DeviceSignal signal) {
    if (signal is PatchCheckSignal && !signal.offered) {
      progress.fail(
        '[$name] The app is not on this release, or the patch has no '
        '${signal.arch} build.',
      );
      return true;
    }
    if (signal is PatchEventSignal && signal.isFailure) {
      progress.fail('[$name] Patch rejected: ${signal.message ?? signal.type}');
      return true;
    }
    return false;
  }

  void _hintNoCheckIn(_PushTarget target) {
    logger.info(
      target is _IosTarget
          ? 'Make sure the iPhone is unlocked, on the same Wi-Fi as this Mac, '
                'and the app has Local Network access (Settings > Privacy & '
                'Security > Local Network).'
          : 'Make sure the release was built in local mode (base_url in '
                'shorebird.yaml) and auto_update is on.',
    );
  }

  /// `--apply now`: relaunch so the app downloads the patch, relaunch again
  /// so it boots it, and confirm it did.
  Future<bool> _pushNow(PatchPushServer server, _PushTarget target) async {
    final number = server.offer.number;
    final name = target.label;
    final progress = logger.progress('[$name] Connecting');
    final log = _log(server, target.owns);
    try {
      await target.connect(server);

      progress.update('[$name] Launching app to download patch $number');
      log.clear();
      await target.relaunch();
      final downloaded = await log.waitFor(
        (s) =>
            _isFailure(s, number) ||
            _isRunning(s, number) ||
            _isDownloaded(s, number) ||
            (s is PatchCheckSignal && !s.offered),
        checkInTimeout,
      );
      if (downloaded == null) {
        progress.fail('[$name] The app never checked for a patch.');
        _hintNoCheckIn(target);
        return false;
      }
      if (_reportProblem(progress, name, downloaded)) return false;

      if (!_isRunning(downloaded, number)) {
        progress.update('[$name] Restarting app to apply patch $number');
        log.clear();
        await target.relaunch();
        final booted = await log.waitFor(
          (s) => _isFailure(s, number) || _isRunning(s, number),
          checkInTimeout,
        );
        if (booted == null) {
          progress.fail('[$name] Patch $number downloaded but did not boot.');
          return false;
        }
        if (_reportProblem(progress, name, booted)) return false;
      }
      progress.complete('[$name] Running patch $number');
      return true;
    } on Exception catch (error) {
      progress.fail('[$name] $error');
      return false;
    } finally {
      await log.close();
    }
  }

  /// `--apply next-launch`: open the way for every target, then wait for
  /// people to open the app. Each device downloads the patch in the
  /// background and runs it from its next launch. Returns the labels of
  /// targets that did not get it.
  Future<List<String>> _pushNextLaunch(
    PatchPushServer server,
    List<_PushTarget> targets,
  ) async {
    final number = server.offer.number;
    for (final target in targets) {
      await target.connect(server);
    }
    logger.info(
      'Waiting up to ${nextLaunchTimeout.inMinutes} minutes for the app to be '
      'opened on ${targets.map((t) => t.label).join(', ')} '
      '(it is not relaunched for you).',
    );

    bool done(DeviceSignal s) =>
        _isDownloaded(s, number) ||
        _isRunning(s, number) ||
        _isFailure(s, number) ||
        (s is PatchCheckSignal && !s.offered);

    final android = targets.whereType<_AndroidTarget>().toList();
    final iphones = targets.whereType<_IosTarget>().toList();
    final failed = <String>[];

    Future<void> waitForAndroid(_AndroidTarget target) async {
      final progress = logger.progress('[${target.label}] Waiting');
      final log = _log(server, target.owns);
      try {
        final signal = await log.waitFor(done, nextLaunchTimeout);
        if (signal == null) {
          progress.fail('[${target.label}] The app was not opened in time.');
          failed.add(target.label);
        } else if (_reportProblem(progress, target.label, signal)) {
          failed.add(target.label);
        } else {
          progress.complete(
            _isRunning(signal, number)
                ? '[${target.label}] Already running patch $number'
                : '[${target.label}] Downloaded patch $number',
          );
          await log.waitFor((s) => s is PolicySignal, policyGrace);
        }
      } finally {
        await log.close();
      }
    }

    // iPhones share one listener, so count distinct installs rather than
    // naming which phone each one is.
    Future<void> waitForIphones() async {
      if (iphones.isEmpty) return;
      final label = iphones.length == 1
          ? iphones.single.label
          : '${iphones.length} iPhones';
      final progress = logger.progress('[$label] Waiting');
      final log = _log(server, (s) => s.via == PatchPushServer.wifi);
      final finished = <String>{};
      try {
        while (finished.length < iphones.length) {
          final signal = await log.waitFor(
            (s) => done(s) && !finished.contains(s.clientId),
            nextLaunchTimeout,
          );
          if (signal == null) {
            progress.fail(
              '[$label] ${iphones.length - finished.length} did not open the '
              'app in time.',
            );
            failed.addAll(iphones.skip(finished.length).map((t) => t.label));
            _hintNoCheckIn(iphones.first);
            return;
          }
          if (_reportProblem(progress, label, signal)) {
            failed.add(label);
            return;
          }
          finished.add(signal.clientId);
          progress.update(
            '[$label] ${finished.length}/${iphones.length} downloaded',
          );
        }
        progress.complete('[$label] Downloaded patch $number');
        var policyReads = 0;
        await log.waitFor(
          (s) => s is PolicySignal && ++policyReads >= iphones.length,
          policyGrace,
        );
      } finally {
        await log.close();
      }
    }

    await Future.wait([...android.map(waitForAndroid), waitForIphones()]);
    return failed;
  }
}

/// Buffers a stream of signals so callers can wait for one that matches,
/// including ones that arrived before they started waiting.
class _SignalLog {
  _SignalLog(Stream<DeviceSignal> signals) {
    _subscription = signals.listen((signal) {
      _signals.add(signal);
      _arrived.add(null);
    });
  }

  late final StreamSubscription<DeviceSignal> _subscription;
  final _signals = <DeviceSignal>[];
  final _arrived = StreamController<void>.broadcast();

  /// Forgets everything received so far.
  void clear() => _signals.clear();

  /// The first signal matching [test], or null after [timeout].
  Future<DeviceSignal?> waitFor(
    bool Function(DeviceSignal) test,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    var seen = 0;
    while (true) {
      for (; seen < _signals.length; seen++) {
        if (test(_signals[seen])) return _signals[seen];
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining.isNegative) return null;
      await _arrived.stream.first
          .timeout(remaining, onTimeout: () {})
          .catchError((_) {});
    }
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _arrived.close();
  }
}
