import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// How a patch is presented to the user. Chosen per patch with
/// `shorebird patch --update-ui <value>`.
enum UpdateUi {
  /// No UI. The patch downloads in the background and applies next launch.
  silent('silent'),

  /// A banner offering to update now: download, then restart.
  bannerNow('banner-now'),

  /// A banner saying the update applies the next time the app opens.
  bannerNextLaunch('banner-next-launch'),

  /// A blocking screen until the patch is installed.
  wall('wall');

  const UpdateUi(this.wireName);

  /// The name used by the CLI and the policy endpoint.
  final String wireName;

  /// Parses [wireName], or returns null if it isn't one.
  static UpdateUi? tryParse(String? wireName) {
    for (final ui in values) {
      if (ui.wireName == wireName) return ui;
    }
    return null;
  }
}

/// What the server says about the newest patch for this release.
@immutable
class UpdatePolicy {
  /// Creates an [UpdatePolicy].
  const UpdatePolicy({
    this.latestPatchNumber,
    this.updateUi,
    this.wallPatchNumber,
  });

  /// Parses the policy endpoint's JSON.
  factory UpdatePolicy.fromJson(Map<String, dynamic> json) => UpdatePolicy(
    latestPatchNumber: json['latest_patch_number'] as int?,
    updateUi: UpdateUi.tryParse(json['update_ui'] as String?),
    wallPatchNumber: json['wall_patch_number'] as int?,
  );

  /// The newest patch available for this release.
  final int? latestPatchNumber;

  /// How to present [latestPatchNumber].
  final UpdateUi? updateUi;

  /// The newest patch pushed with `--update-ui wall`. A device behind it must
  /// update before using the app, even if [updateUi] is gentler.
  final int? wallPatchNumber;
}

/// Loads an [UpdatePolicy].
typedef UpdatePolicyFetcher = Future<UpdatePolicy?> Function();

/// Reads the policy from `GET <base_url>/api/v1/patches/policy`, the same
/// host the updater uses (`base_url` in shorebird.yaml).
///
/// Returns null when it can't be reached. With local-mode pushes that is the
/// normal state outside of a push, and the gate falls back to its default.
Future<UpdatePolicy?> fetchUpdatePolicy({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final yaml = await rootBundle.loadString('shorebird.yaml');
    String? field(String key) =>
        RegExp('^$key:\\s*(\\S+)', multiLine: true).firstMatch(yaml)?.group(1);
    final baseUrl = field('base_url');
    final appId = field('app_id');
    if (baseUrl == null || appId == null) return null;

    final info = await PackageInfo.fromPlatform();
    final uri = Uri.parse('$baseUrl/api/v1/patches/policy').replace(
      queryParameters: {
        'app_id': appId,
        'release_version': '${info.version}+${info.buildNumber}',
        'platform': Platform.operatingSystem,
      },
    );
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await utf8.decodeStream(response);
    return UpdatePolicy.fromJson(json.decode(body) as Map<String, dynamic>);
  } on Exception catch (error) {
    debugPrint('[shorebird_update_ui] policy unavailable: $error');
    return null;
  } finally {
    client.close(force: true);
  }
}
