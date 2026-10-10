/// Customizable Flutter widgets for code push updates.
///
/// Each patch says how it wants to be shown (`--update-ui` on the CLI):
/// silently, as a banner that updates now, as a banner that updates next
/// launch, or as a wall that blocks the app until it updates.
library;

export 'src/default_widgets.dart';
export 'src/update_controller.dart';
export 'src/update_gate.dart';
export 'src/update_policy.dart';
