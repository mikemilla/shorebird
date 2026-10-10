import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/commands/patches/patch_number_argument.dart';
import 'package:shorebird_cli/src/common_arguments.dart';
import 'package:shorebird_cli/src/local/local_store.dart';
import 'package:shorebird_cli/src/local/patch_push.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';
import 'package:shorebird_cli/src/shorebird_env.dart';
import 'package:shorebird_code_push_client/shorebird_code_push_client.dart';

/// {@template push_command}
/// Pushes an existing patch straight to devices connected to this machine,
/// with no code push server involved.
///
/// Sample usage:
/// ```sh
/// shorebird patches push --release-version=1.0.0+1 -d emulator-5554
/// shorebird patches push --release-version=1.0.0+1 --all-devices
/// ```
/// {@endtemplate}
class PushCommand extends ShorebirdCommand with PatchNumberArgument {
  /// {@macro push_command}
  PushCommand() {
    argParser
      ..addOption(
        CommonArguments.releaseVersionArg.name,
        help: CommonArguments.patchReleaseVersionDescription,
        mandatory: true,
      )
      ..addOption(
        'patch-number',
        help: 'The patch number to push. Defaults to the latest patch.',
      )
      ..addOption(
        'platform',
        allowed: [ReleasePlatform.android.name, ReleasePlatform.ios.name],
        defaultsTo: ReleasePlatform.android.name,
        help: 'The platform of the patch.',
      )
      ..addMultiOption(
        'device-id',
        abbr: 'd',
        help:
            'The device to push to: an adb serial, or an iOS UDID or name. '
            'Repeatable.',
      )
      ..addFlag(
        'all-devices',
        negatable: false,
        help: 'Push to every connected device with the release installed.',
      )
      ..addOption(
        'apply',
        allowed: [for (final mode in ApplyMode.values) mode.cliName],
        defaultsTo: ApplyMode.now.cliName,
        allowedHelp: {
          ApplyMode.now.cliName:
              'Relaunch the app so it is running the patch when the push '
              'ends.',
          ApplyMode.nextLaunch.cliName:
              'Wait for the app to be opened; it downloads the patch and runs '
              'it from the following launch.',
        },
        help: 'When a pushed patch takes effect.',
      )
      ..addOption(
        'update-ui',
        allowed: [for (final ui in UpdateUi.values) ui.cliName],
        allowedHelp: {
          UpdateUi.silent.cliName:
              'No UI: downloads in the background, applies next launch.',
          UpdateUi.bannerNow.cliName:
              'Banner offering to update now (download, then restart).',
          UpdateUi.bannerNextLaunch.cliName:
              'Banner saying the update applies next launch.',
          UpdateUi.wall.cliName: 'Block the app until the patch is installed.',
        },
        help:
            'How apps using package:shorebird_update_ui present this patch '
            '(local mode). Defaults to silent.',
      )
      ..addOption(
        CommonArguments.appIdArg.name,
        help: CommonArguments.appIdArg.description,
      )
      ..addOption(
        CommonArguments.flavorArg.name,
        help: 'The product flavor to use (e.g. "prod").',
      );
  }

  @override
  String get name => 'push';

  @override
  String get description =>
      'Push a patch straight to connected devices (local mode).';

  @override
  Future<int> run() async {
    if (!shorebirdEnv.isLocalMode) {
      logger.err('push needs local mode. Unset SHOREBIRD_HOSTED_URL.');
      return ExitCode.usage.code;
    }

    final deviceIds = results['device-id'] as List<String>;
    final allDevices = results['all-devices'] as bool;
    if (deviceIds.isEmpty == !allDevices) {
      usageException('Pass either --device-id (-d) or --all-devices.');
    }

    final (:appId, :errorCode) = await resolveAppId();
    if (errorCode != null) return errorCode;

    final releaseVersion =
        results[CommonArguments.releaseVersionArg.name] as String;
    final store = LocalStore(shorebirdEnv.localDataDirectory);

    final platform = ReleasePlatform.values.byName(
      results['platform'] as String,
    );

    final int patchNumber;
    if (results['patch-number'] != null) {
      final (patchNumber: parsed, errorCode: patchNumberError) =
          resolvePatchNumber();
      if (parsed == null) return patchNumberError!;
      patchNumber = parsed;
    } else {
      final release = store.find(
        'releases',
        (r) => r['app_id'] == appId && r['version'] == releaseVersion,
      );
      final numbers = release == null
          ? const <int>[]
          : store
                .where(
                  'patches',
                  (p) =>
                      p['release_id'] == release['id'] &&
                      p['is_rolled_back'] != true &&
                      store.find(
                            'patch_artifacts',
                            (a) =>
                                a['patch_id'] == p['id'] &&
                                a['platform'] == platform.name,
                          ) !=
                          null,
                )
                .map((p) => p['number'] as int)
                .toList();
      if (numbers.isEmpty) {
        logger.err(
          'Release $releaseVersion has no ${platform.displayName} patches '
          'to push.',
        );
        return ExitCode.usage.code;
      }
      patchNumber = numbers.reduce((a, b) => a > b ? a : b);
    }

    final pusher = LocalPatchPusher(store);
    final updateUiArg = results['update-ui'] as String?;
    if (updateUiArg != null) {
      pusher.setUpdateUi(
        appId: appId,
        releaseVersion: releaseVersion,
        patchNumber: patchNumber,
        updateUi: UpdateUi.parse(updateUiArg),
      );
    }
    return pusher.push(
      appId: appId,
      releaseVersion: releaseVersion,
      patchNumber: patchNumber,
      platform: platform,
      deviceIds: deviceIds,
      allDevices: allDevices,
      apply: ApplyMode.parse(results['apply'] as String),
    );
  }
}
