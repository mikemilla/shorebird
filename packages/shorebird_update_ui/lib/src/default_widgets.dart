import 'package:flutter/material.dart';
import 'package:shorebird_update_ui/src/update_controller.dart';
import 'package:shorebird_update_ui/src/update_policy.dart';

/// The text used by [DefaultUpdateBanner] and [DefaultUpdateWall]. Override
/// any of it to match your app's voice or language.
@immutable
class UpdateStrings {
  /// Creates [UpdateStrings].
  const UpdateStrings({
    this.available = 'A new version is available.',
    this.updateNow = 'Update now',
    this.later = 'Later',
    this.updating = 'Updating…',
    this.restart = 'Restart',
    this.ok = 'OK',
    this.retry = 'Try again',
    this.readyRestart = 'Update downloaded. Restart to use it.',
    this.readyReopen =
        'Update downloaded. Close and reopen the app to finish updating.',
    this.nextLaunch =
        'An update will be installed the next time you open the app.',
    this.failed = "The update couldn't be downloaded.",
    this.wallTitle = 'Update required',
    this.wallDownloading = 'Downloading the latest version…',
    this.wallReadyRestart = 'The update is ready. Restart to continue.',
    this.wallReadyReopen =
        'The update is ready. Close the app (swipe it away) and open it again '
        'to continue.',
    this.wallFailed =
        "The update couldn't be downloaded. Check your connection and try "
        'again.',
  });

  /// Shown by the update-now banner before downloading.
  final String available;

  /// The update-now button.
  final String updateNow;

  /// The dismiss button.
  final String later;

  /// Shown while downloading.
  final String updating;

  /// The restart button.
  final String restart;

  /// The acknowledge button on the next-launch banner.
  final String ok;

  /// The retry button.
  final String retry;

  /// Downloaded, and the app can restart itself (Android).
  final String readyRestart;

  /// Downloaded, and the user must reopen the app (iOS).
  final String readyReopen;

  /// The next-launch banner.
  final String nextLaunch;

  /// The download failed.
  final String failed;

  /// The wall's title.
  final String wallTitle;

  /// The wall while downloading.
  final String wallDownloading;

  /// The wall once downloaded, when the app can restart itself.
  final String wallReadyRestart;

  /// The wall once downloaded, when the user must reopen the app.
  final String wallReadyReopen;

  /// The wall when the download failed.
  final String wallFailed;
}

/// The default banner: "update now" or "applies next launch", depending on
/// the controller's [UpdateUi].
class DefaultUpdateBanner extends StatelessWidget {
  /// Creates a [DefaultUpdateBanner].
  const DefaultUpdateBanner({
    required this.controller,
    this.strings = const UpdateStrings(),
    super.key,
  });

  /// The update state and actions.
  final UpdateController controller;

  /// The text to show.
  final UpdateStrings strings;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = strings;
    final (String message, List<Widget> actions) = switch ((c.ui, c.phase)) {
      (_, UpdatePhase.failed) => (
        s.failed,
        [
          TextButton(onPressed: c.dismiss, child: Text(s.later)),
          FilledButton(onPressed: c.updateNow, child: Text(s.retry)),
        ],
      ),
      (UpdateUi.bannerNextLaunch, _) => (
        s.nextLaunch,
        [TextButton(onPressed: c.dismiss, child: Text(s.ok))],
      ),
      (_, UpdatePhase.downloading) => (s.updating, <Widget>[]),
      (_, UpdatePhase.ready) when c.canRestart => (
        s.readyRestart,
        [
          TextButton(onPressed: c.dismiss, child: Text(s.later)),
          FilledButton(onPressed: c.restart, child: Text(s.restart)),
        ],
      ),
      (_, UpdatePhase.ready) => (
        s.readyReopen,
        [TextButton(onPressed: c.dismiss, child: Text(s.ok))],
      ),
      _ => (
        s.available,
        [
          TextButton(onPressed: c.dismiss, child: Text(s.later)),
          FilledButton(onPressed: c.updateNow, child: Text(s.updateNow)),
        ],
      ),
    };

    return Material(
      elevation: 2,
      child: SafeArea(
        bottom: false,
        child: MaterialBanner(
          elevation: 0,
          content: Text(message),
          leading: c.phase == UpdatePhase.downloading
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update),
          actions: actions.isEmpty ? const [SizedBox.shrink()] : actions,
        ),
      ),
    );
  }
}

/// The default wall: blocks the app until the update is installed.
class DefaultUpdateWall extends StatelessWidget {
  /// Creates a [DefaultUpdateWall].
  const DefaultUpdateWall({
    required this.controller,
    this.strings = const UpdateStrings(),
    super.key,
  });

  /// The update state and actions.
  final UpdateController controller;

  /// The text to show.
  final UpdateStrings strings;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = strings;
    final theme = Theme.of(context);
    final message = switch (c.phase) {
      UpdatePhase.ready when c.canRestart => s.wallReadyRestart,
      UpdatePhase.ready => s.wallReadyReopen,
      UpdatePhase.failed => s.wallFailed,
      _ => s.wallDownloading,
    };
    return Material(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.system_update, size: 64),
              const SizedBox(height: 24),
              Text(
                s.wallTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              if (c.phase == UpdatePhase.downloading ||
                  c.phase == UpdatePhase.available)
                const Center(child: CircularProgressIndicator()),
              if (c.phase == UpdatePhase.ready && c.canRestart)
                FilledButton(onPressed: c.restart, child: Text(s.restart)),
              if (c.phase == UpdatePhase.failed)
                FilledButton(onPressed: c.download, child: Text(s.retry)),
            ],
          ),
        ),
      ),
    );
  }
}
