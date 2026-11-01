import "package:flutter/rendering.dart";

/// Every [T] at or under [root], in the order they are painted.
Iterable<T> descendantsOf<T extends RenderObject>(RenderObject? root) sync* {
  if (root == null) return;
  final stack = [root];
  while (stack.isNotEmpty) {
    final node = stack.removeLast();
    if (node is T) yield node;
    final children = <RenderObject>[];
    node.visitChildren(children.add);
    stack.addAll(children.reversed);
  }
}
