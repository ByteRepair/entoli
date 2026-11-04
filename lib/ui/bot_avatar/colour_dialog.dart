import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "../../domain/bot_avatar/spec.dart";

/// Any colour for a Bot Avatar's body: hue, saturation and brightness on
/// sliders, or a hex code typed in. The palette's own swatches sit beside
/// this on the editor; this is the custom one, as the reference's colour
/// input is. Null where the dialog was dismissed.
Future<int?> showBotColourDialog(BuildContext context, int initial) =>
    showDialog<int>(context: context, builder: (_) => _ColourDialog(initial));

class _ColourDialog extends StatefulWidget {
  const _ColourDialog(this.initial);
  final int initial;

  @override
  State<_ColourDialog> createState() => _ColourDialogState();
}

class _ColourDialogState extends State<_ColourDialog> {
  late HSVColor _hsv = HSVColor.fromColor(Color(0xff000000 | widget.initial));
  late final _hex = TextEditingController(text: hexColour(widget.initial));

  int get _rgb => _hsv.toColor().toARGB32() & 0xffffff;

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(HSVColor hsv) => setState(() {
    _hsv = hsv;
    _hex.text = hexColour(_rgb);
  });

  Widget _slider(
    String label,
    double value,
    double max,
    List<Color> track,
    ValueChanged<double> onChanged,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Container(
          height: 28,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: LinearGradient(colors: track),
          ),
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 0,
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: Colors.white,
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(
              value: value,
              max: max,
              label: label,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hue = [
      for (var h = 0; h <= 360; h += 60)
        HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
    ];
    return AlertDialog(
      title: const Text("Custom colour"),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            Container(
              height: 48,
              decoration: BoxDecoration(
                color: _hsv.toColor(),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            _slider("Hue", _hsv.hue, 360, hue, (v) => _set(_hsv.withHue(v))),
            _slider("Saturation", _hsv.saturation, 1, [
              _hsv.withSaturation(0).toColor(),
              _hsv.withSaturation(1).toColor(),
            ], (v) => _set(_hsv.withSaturation(v))),
            _slider("Brightness", _hsv.value, 1, [
              Colors.black,
              _hsv.withValue(1).toColor(),
            ], (v) => _set(_hsv.withValue(v))),
            TextField(
              controller: _hex,
              decoration: const InputDecoration(
                labelText: "Hex",
                hintText: "#rrggbb",
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r"[#0-9a-fA-F]")),
                LengthLimitingTextInputFormatter(7),
              ],
              onChanged: (text) {
                final rgb = parseHexColour(text);
                if (rgb != null) {
                  setState(
                    () => _hsv = HSVColor.fromColor(Color(0xff000000 | rgb)),
                  );
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_rgb),
          child: const Text("Use"),
        ),
      ],
    );
  }
}
