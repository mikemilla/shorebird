import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'package:shorebird_update_ui/src/update_policy.dart';

/// Where an update is in its lifecycle.
enum UpdatePhase {
  /// Nothing to do.
  upToDate,

  /// A patch is available but not downloaded.
  available,

  /// The patch is downloading.
  downloading,

  /// The patch is downloaded and takes effect on the next launch.
  ready,

  /// The download failed.
  failed,
}

/// Drives the update UI: finds out whether a patch exists and how to
/// present it, downloads it, and restarts into it.
///
/// [UpdateGate] uses one internally; create your own to build a completely
/// custom UI, or to read the state elsewhere in the app.
class UpdateController extends ChangeNotifier {
  /// Creates an [UpdateController].
  ///
  /// [fallbackUi] is used when the policy can't be read (or doesn't say).
  UpdateController({
    ShorebirdUpdater? updater,
    UpdatePolicyFetcher? fetchPolicy,
    this.fallbackUi = UpdateUi.silent,
    this.downloadTimeout = const Duration(minutes: 2),
    bool? canRestart,
  }) : _updater = updater ?? ShorebirdUpdater(),
       _fetchPolicy = fetchPolicy ?? fetchUpdatePolicy,
       canRestart = canRestart ?? (!kIsWeb && Platform.isAndroid);

  final ShorebirdUpdater _updater;
  final UpdatePolicyFetcher _fetchPolicy;

  /// The UI used when no policy is available.
  final UpdateUi fallbackUi;

  /// How long [download] waits for the patch to land on disk.
  final Duration downloadTimeout;

  /// Whether [restart] can relaunch the app. True on Android. iOS apps can't
  /// relaunch themselves, so there the user has to close and reopen the app.
  final bool canRestart;

  static const _channel = MethodChannel('shorebird_update_ui');

  UpdateUi _ui = UpdateUi.silent;
  UpdatePhase _phase = UpdatePhase.upToDate;
  int? _currentPatch;
  int? _targetPatch;
  bool _dismissed = false;
  Future<void>? _checking;

  /// How the pending update should be presented.
  UpdateUi get ui => _ui;

  /// Where the pending update is.
  UpdatePhase get phase => _phase;

  /// The patch the app is running, or null for the base release.
  int? get currentPatch => _currentPatch;

  /// The patch being installed, when known.
  int? get targetPatch => _targetPatch;

  /// Whether there is anything to show.
  bool get hasUpdate => _phase != UpdatePhase.upToDate;

  /// Whether the user dismissed the banner.
  bool get isDismissed => _dismissed;

  /// Whether a banner should be visible.
  bool get showsBanner =>
      hasUpdate &&
      !_dismissed &&
      (_ui == UpdateUi.bannerNow || _ui == UpdateUi.bannerNextLaunch);

  /// Whether the blocking wall should be visible.
  bool get showsWall => hasUpdate && _ui == UpdateUi.wall;

  /// Checks for a patch and how to present it. Silent, next-launch and wall
  /// updates start downloading right away; [UpdateUi.bannerNow] waits for
  /// [updateNow].
  Future<void> check() =>
      _checking ??= _check().whenComplete(() => _checking = null);

  Future<void> _check() async {
    if (!_updater.isAvailable) return;
    _currentPatch = (await _updater.readCurrentPatch())?.number;
    final current = _currentPatch ?? 0;
    final policy = await _fetchPolicy();
    final status = await _updater.checkForUpdate();
    final next = (await _updater.readNextPatch())?.number;

    var phase = switch (status) {
      UpdateStatus.outdated => UpdatePhase.available,
      UpdateStatus.restartRequired => UpdatePhase.ready,
      _ => UpdatePhase.upToDate,
    };
    final wall = policy?.wallPatchNumber;
    final mustUpdate = wall != null && wall > current;
    if (mustUpdate && phase == UpdatePhase.upToDate) {
      phase = (next ?? 0) >= wall ? UpdatePhase.ready : UpdatePhase.available;
    }

    _ui = mustUpdate ? UpdateUi.wall : policy?.updateUi ?? fallbackUi;
    _targetPatch = policy?.latestPatchNumber ?? (next != current ? next : null);
    _phase = phase;
    _dismissed = false;
    notifyListeners();

    if (_phase == UpdatePhase.available && _ui != UpdateUi.bannerNow) {
      await download();
    }
  }

  /// Downloads the patch. Completes when it is on disk ([UpdatePhase.ready])
  /// or the download failed ([UpdatePhase.failed]).
  Future<void> download() async {
    if (_phase == UpdatePhase.downloading || _phase == UpdatePhase.ready) {
      return;
    }
    _setPhase(UpdatePhase.downloading);
    try {
      await _updater.update();
    } on UpdateException catch (error) {
      debugPrint('[shorebird_update_ui] $error');
    }
    // update() returns straight away if the automatic updater is already
    // downloading, so wait for the patch to land.
    final deadline = DateTime.now().add(downloadTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final next = (await _updater.readNextPatch())?.number ?? 0;
      final target = _targetPatch;
      if (target == null ? next != (_currentPatch ?? 0) : next >= target) {
        _targetPatch = next;
        _setPhase(UpdatePhase.ready);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    _setPhase(UpdatePhase.failed);
  }

  /// Downloads the patch and, where possible, restarts into it.
  Future<void> updateNow() async {
    await download();
    if (_phase == UpdatePhase.ready && canRestart) await restart();
  }

  /// Relaunches the app so a downloaded patch takes effect. Does nothing
  /// where [canRestart] is false.
  Future<void> restart() async {
    if (!canRestart) return;
    await _channel.invokeMethod<void>('restart');
  }

  /// Hides the banner until the next [check]. The wall can't be dismissed.
  void dismiss() {
    if (_ui == UpdateUi.wall) return;
    _dismissed = true;
    notifyListeners();
  }

  void _setPhase(UpdatePhase phase) {
    _phase = phase;
    notifyListeners();
  }
}
