import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shorebird_update_ui/src/default_widgets.dart';
import 'package:shorebird_update_ui/src/update_controller.dart';
import 'package:shorebird_update_ui/src/update_policy.dart';

/// Builds update UI from an [UpdateController].
typedef UpdateWidgetBuilder =
    Widget Function(BuildContext context, UpdateController controller);

/// Shows code push updates the way each patch asks to be shown (see
/// [UpdateUi]): nothing, a banner above [child], or a wall in place of it.
///
/// Put it in `MaterialApp.builder` so it covers every route:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => UpdateGate(child: child!),
/// )
/// ```
///
/// Swap the visuals with [bannerBuilder] and [wallBuilder]; both receive the
/// [UpdateController] with the state and actions (`updateNow`, `restart`,
/// `dismiss`, ...).
class UpdateGate extends StatefulWidget {
  /// Creates an [UpdateGate].
  const UpdateGate({
    required this.child,
    this.controller,
    this.bannerBuilder,
    this.wallBuilder,
    this.fallbackUi = UpdateUi.silent,
    this.checkOnStart = true,
    super.key,
  });

  /// The app.
  final Widget child;

  /// Drives the UI. One is created if omitted.
  final UpdateController? controller;

  /// Builds the banner. Defaults to [DefaultUpdateBanner].
  final UpdateWidgetBuilder? bannerBuilder;

  /// Builds the wall. Defaults to [DefaultUpdateWall].
  final UpdateWidgetBuilder? wallBuilder;

  /// Used when the policy can't be read. Ignored if [controller] is given.
  final UpdateUi fallbackUi;

  /// Whether to check for an update when the gate first builds.
  final bool checkOnStart;

  @override
  State<UpdateGate> createState() => _UpdateGateState();
}

class _UpdateGateState extends State<UpdateGate> {
  late final UpdateController _controller =
      widget.controller ?? UpdateController(fallbackUi: widget.fallbackUi);

  @override
  void initState() {
    super.initState();
    // Never hold up startup on the network.
    if (widget.checkOnStart) unawaited(_controller.check());
  }

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        if (_controller.showsWall) {
          return (widget.wallBuilder ?? _defaultWall)(context, _controller);
        }
        if (!_controller.showsBanner) return widget.child;
        return Column(
          children: [
            (widget.bannerBuilder ?? _defaultBanner)(context, _controller),
            Expanded(
              // The banner already sits below the status bar.
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: widget.child,
              ),
            ),
          ],
        );
      },
    );
  }

  static Widget _defaultBanner(BuildContext _, UpdateController controller) =>
      DefaultUpdateBanner(controller: controller);

  static Widget _defaultWall(BuildContext _, UpdateController controller) =>
      DefaultUpdateWall(controller: controller);
}
