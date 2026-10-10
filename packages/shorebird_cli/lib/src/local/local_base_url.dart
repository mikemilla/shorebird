import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/platform.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_cli/src/shorebird_process.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// The host iPhones reach this Mac at over Wi-Fi: its Bonjour name (stable
/// across networks, unlike its IP). Override with `SHOREBIRD_LOCAL_IOS_HOST`.
Future<String> localIosHost() async {
  final override = platform.environment['SHOREBIRD_LOCAL_IOS_HOST'];
  if (override != null) return override;
  final result = await process.run('scutil', ['--get', 'LocalHostName']);
  if (result.exitCode != 0) {
    throw Exception('Unable to read LocalHostName: ${result.stderr}');
  }
  return '${'${result.stdout}'.trim()}.local';
}

/// Runs [build] with shorebird.yaml's `base_url` pointed where
/// [releasePlatform] devices can reach this machine, restoring the file
/// afterwards.
///
/// Android devices use the loopback `base_url` written by `shorebird init`
/// (reached through `adb reverse`), so only iOS builds are rewritten, and only
/// when `base_url` is still that local default.
Future<T> withLocalBaseUrlFor<T>(
  ReleasePlatform releasePlatform,
  Future<T> Function() build,
) async {
  if (!shorebirdEnv.isLocalMode || releasePlatform != ReleasePlatform.ios) {
    return build();
  }
  final projectRoot = shorebirdEnv.getShorebirdProjectRoot();
  if (projectRoot == null) return build();
  if (shorebirdEnv.getShorebirdYaml()?.baseUrl != shorebirdEnv.localBaseUrl) {
    return build();
  }

  final file = shorebirdEnv.getShorebirdYamlFile(cwd: projectRoot);
  final original = file.readAsStringSync();
  final iosBaseUrl =
      'http://${await localIosHost()}:${shorebirdEnv.localPushPort}';
  file.writeAsStringSync(
    (YamlEditor(original)..update(['base_url'], iosBaseUrl)).toString(),
  );
  logger.info('iOS build uses base_url: $iosBaseUrl');
  try {
    return await build();
  } finally {
    file.writeAsStringSync(original);
  }
}
