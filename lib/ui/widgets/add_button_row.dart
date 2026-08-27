import "package:flutter/widgets.dart";

/// The row an editable list ends on: the padding the rows above carry, and
/// the button that adds one more. The provider list, the environment variable
/// lists and the backup row are the same shape over different buttons.
class AddButtonRow extends StatelessWidget {
  const AddButtonRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), child: child);
}
