import "dart:typed_data";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../domain/models.dart";
import "../../providers.dart";
import "image_viewer.dart";

/// One attached file. An image shows itself, anything else its name and an
/// icon. The composer already holds the bytes it just read; a sent message
/// names the resource they were saved as and they are read back.
class AttachmentChip extends ConsumerWidget {
  /// Not sent yet, and removable.
  AttachmentChip.pending(Attachment attachment, {super.key, this.onRemove})
      : filename = attachment.filename,
        mimeType = attachment.mimeType,
        bytes = attachment.bytes,
        source = null,
        size = _size;

  /// Part of a message that has already gone out.
  /// [size] is larger for an image the model made: it is the reply itself.
  AttachmentChip.sent(FilePart part,
      {super.key, required String chatId, this.size = _size})
      : filename = part.filename,
        mimeType = part.mimeType,
        bytes = null,
        source = (chatId: chatId, resource: part.resource),
        onRemove = null;

  static const _size = 64.0;

  final String filename;
  final String mimeType;
  final Uint8List? bytes;
  final ({String chatId, String resource})? source;
  final VoidCallback? onRemove;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final source = this.source;
    // Only an image shows its bytes, so only an image is worth reading back.
    final isImage = mimeType.startsWith("image/");
    final data = bytes ??
        (source == null || !isImage ? null : ref.watch(attachmentBytesProvider(source)).value);

    return Tooltip(
      message: filename,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: isImage && data != null
                ? InkWell(
                    onTap: () => showImageViewer(context, data, label: filename),
                    child: Image.memory(
                      data,
                      // Without a decode target a phone photo becomes tens of
                      // MB of bitmap to fill 64 logical pixels, and two of
                      // them evict the whole image cache.
                      cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                      fit: BoxFit.cover,
                    ),
                  )
                : _name(theme),
          ),
          if (onRemove != null)
            Positioned(
              top: -6,
              right: -6,
              child: Material(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: CircleBorder(side: BorderSide(color: theme.colorScheme.outlineVariant)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onRemove,
                  child: const Padding(padding: EdgeInsets.all(2), child: Icon(Icons.close, size: 14)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _name(ThemeData theme) => Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.description_outlined, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              filename,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      );
}

/// The line attachments sit on, above the composer and inside a bubble. Wraps
/// once there are more than fit, and leaves room for the chips' remove buttons
/// to hang over the edge.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 10, runSpacing: 10, children: children),
        ),
      );
}
