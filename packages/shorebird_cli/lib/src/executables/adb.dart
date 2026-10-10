import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:shorebird_cli/src/android_sdk.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';

/// A reference to a [Adb] instance.
final adbRef = create(Adb.new);

/// The [Adb] instance available in the current zone.
Adb get adb => read(adbRef);

/// A wrapper around the `adb` command.
class Adb {
  Future<ShorebirdProcessResult> _exec(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.run(adbPath, command.split(' '));
  }

  Future<Process> _stream(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.start(adbPath, command.split(' '));
  }

  /// Clears the app data for the given [package] name.
  Future<void> clearAppData({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'pm',
      'clear',
      package,
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to clear app data: ${result.stderr}');
    }
  }

  /// Starts the app with the given [package] name.
  Future<void> startApp({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'monkey',
      // Adjust percentage of "system" key events to 0.
      // This is needed to support Android systems with no hardware keys.
      '--pct-syskeys 0',
      '-p $package',
      '1',
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to start app: ${result.stderr}');
    }
  }

  /// The serials of all devices adb can talk to (emulators, USB and wireless).
  Future<List<String>> devices() async {
    final result = await _exec('devices');
    if (result.exitCode != 0) {
      throw Exception('Unable to list devices: ${result.stderr}');
    }
    return LineSplitter.split('${result.stdout}')
        .map((line) => line.split('\t'))
        .where((parts) => parts.length == 2 && parts[1].trim() == 'device')
        .map((parts) => parts[0].trim())
        .toList();
  }

  /// Whether [package] is installed on [deviceId].
  Future<bool> isInstalled({
    required String package,
    required String deviceId,
  }) async {
    final result = await _exec('-s $deviceId shell pm path $package');
    return result.exitCode == 0 && '${result.stdout}'.contains('package:');
  }

  /// Stops [package] on [deviceId].
  Future<void> forceStop({
    required String package,
    required String deviceId,
  }) async {
    final result = await _exec('-s $deviceId shell am force-stop $package');
    if (result.exitCode != 0) {
      throw Exception('Unable to stop app: ${result.stderr}');
    }
  }

  /// Makes `127.0.0.1:[devicePort]` on [deviceId] reach
  /// `127.0.0.1:[hostPort]` on this machine.
  Future<void> reverse({
    required String deviceId,
    required int devicePort,
    required int hostPort,
  }) async {
    final result = await _exec(
      '-s $deviceId reverse tcp:$devicePort tcp:$hostPort',
    );
    if (result.exitCode != 0) {
      throw Exception('Unable to forward port $devicePort: ${result.stderr}');
    }
  }

  /// Undoes [reverse].
  Future<void> removeReverse({
    required String deviceId,
    required int port,
  }) async {
    await _exec('-s $deviceId reverse --remove tcp:$port');
  }

  /// Runs `adb logcat`.
  Future<Process> logcat({String? filter, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'logcat',
      // This arg prevents old logs from being displayed.
      ...['-T', '1'],
      if (filter != null) ...['-s', filter],
    ];
    return _stream(args.join(' '));
  }
}
