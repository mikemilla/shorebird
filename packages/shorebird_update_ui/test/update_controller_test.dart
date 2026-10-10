import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'package:shorebird_update_ui/shorebird_update_ui.dart';

class _FakeUpdater implements ShorebirdUpdater {
  _FakeUpdater({
    this.current,
    this.available,
    this.status = UpdateStatus.outdated,
  }) : next = current;

  int? current;
  int? next;
  int? available;
  UpdateStatus status;
  int updateCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<Patch?> readCurrentPatch() async =>
      current == null ? null : Patch(number: current!);

  @override
  Future<Patch?> readNextPatch() async =>
      next == null ? null : Patch(number: next!);

  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async => status;

  @override
  Future<void> update({UpdateTrack? track}) async {
    updateCalls++;
    next = available;
  }
}

UpdateController _controller(
  _FakeUpdater updater,
  UpdatePolicy? policy, {
  UpdateUi fallbackUi = UpdateUi.silent,
}) => UpdateController(
  updater: updater,
  fetchPolicy: () async => policy,
  fallbackUi: fallbackUi,
  downloadTimeout: const Duration(seconds: 2),
  canRestart: false,
);

void main() {
  group(UpdateController, () {
    test('silent downloads in the background and shows nothing', () async {
      final updater = _FakeUpdater(available: 1);
      final c = _controller(
        updater,
        const UpdatePolicy(latestPatchNumber: 1, updateUi: UpdateUi.silent),
      );
      await c.check();
      expect(c.phase, UpdatePhase.ready);
      expect(updater.updateCalls, 1);
      expect(c.showsBanner, isFalse);
      expect(c.showsWall, isFalse);
    });

    test('banner-now waits for the user before downloading', () async {
      final updater = _FakeUpdater(available: 2);
      final c = _controller(
        updater,
        const UpdatePolicy(latestPatchNumber: 2, updateUi: UpdateUi.bannerNow),
      );
      await c.check();
      expect(c.phase, UpdatePhase.available);
      expect(c.showsBanner, isTrue);
      expect(updater.updateCalls, 0);

      await c.updateNow();
      expect(c.phase, UpdatePhase.ready);
      expect(c.targetPatch, 2);
    });

    test('banner-next-launch downloads and keeps the banner up', () async {
      final updater = _FakeUpdater(available: 3);
      final c = _controller(
        updater,
        const UpdatePolicy(
          latestPatchNumber: 3,
          updateUi: UpdateUi.bannerNextLaunch,
        ),
      );
      await c.check();
      expect(c.phase, UpdatePhase.ready);
      expect(c.showsBanner, isTrue);

      c.dismiss();
      expect(c.showsBanner, isFalse);
    });

    test('a newer wall patch blocks even when the latest is gentler', () async {
      final updater = _FakeUpdater(current: 1, available: 5);
      final c = _controller(
        updater,
        const UpdatePolicy(
          latestPatchNumber: 5,
          updateUi: UpdateUi.bannerNextLaunch,
          wallPatchNumber: 4,
        ),
      );
      await c.check();
      expect(c.ui, UpdateUi.wall);
      expect(c.showsWall, isTrue);
      expect(c.phase, UpdatePhase.ready);

      c.dismiss();
      expect(c.showsWall, isTrue, reason: 'the wall cannot be dismissed');
    });

    test('a wall patch already installed does not block', () async {
      final updater = _FakeUpdater(current: 4, status: UpdateStatus.upToDate);
      final c = _controller(
        updater,
        const UpdatePolicy(
          latestPatchNumber: 4,
          updateUi: UpdateUi.wall,
          wallPatchNumber: 4,
        ),
      );
      await c.check();
      expect(c.showsWall, isFalse);
      expect(c.hasUpdate, isFalse);
    });

    test('falls back when the policy is unreachable', () async {
      final updater = _FakeUpdater(available: 1);
      final c = _controller(updater, null, fallbackUi: UpdateUi.bannerNow);
      await c.check();
      expect(c.ui, UpdateUi.bannerNow);
      expect(c.showsBanner, isTrue);
    });

    test('a failed download reports failed', () async {
      final updater = _FakeUpdater(available: null);
      final c = _controller(
        updater,
        const UpdatePolicy(
          latestPatchNumber: 1,
          updateUi: UpdateUi.wall,
          wallPatchNumber: 1,
        ),
      );
      await c.check();
      expect(c.phase, UpdatePhase.failed);
    });
  });

  testWidgets('UpdateGate swaps in a custom wall', (tester) async {
    final controller = _controller(
      _FakeUpdater(available: 1),
      const UpdatePolicy(
        latestPatchNumber: 1,
        updateUi: UpdateUi.wall,
        wallPatchNumber: 1,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: UpdateGate(
          controller: controller,
          checkOnStart: false,
          wallBuilder: (context, c) => Text('custom wall ${c.phase.name}'),
          child: const Text('app'),
        ),
      ),
    );
    expect(find.text('app'), findsOneWidget);
    await tester.runAsync(controller.check);
    await tester.pump();
    expect(find.text('custom wall ready'), findsOneWidget);
    expect(find.text('app'), findsNothing);
  });
}
