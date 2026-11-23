import "package:entoli_core/view/code_scanner.dart";
import "package:flutter/widgets.dart";
import "package:mobile_scanner/mobile_scanner.dart";

/// `mobile_scanner`'s camera view.
class PluginCodeScanner implements CodeScanner {
  const PluginCodeScanner();

  @override
  Widget view({
    required bool Function(String code) onCode,
    required WidgetBuilder refused,
    required Widget Function(BuildContext context, String reason) failed,
  }) => _ScannerView(onCode: onCode, refused: refused, failed: failed);
}

class _ScannerView extends StatefulWidget {
  const _ScannerView({
    required this.onCode,
    required this.refused,
    required this.failed,
  });

  final bool Function(String code) onCode;
  final WidgetBuilder refused;
  final Widget Function(BuildContext context, String reason) failed;

  @override
  State<_ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends State<_ScannerView> {
  final _controller = MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: _controller,
    errorBuilder: (context, error) =>
        error.errorCode == MobileScannerErrorCode.permissionDenied
        ? widget.refused(context)
        : widget.failed(
            context,
            error.errorDetails?.message ?? error.errorCode.message,
          ),
    onDetect: (capture) {
      if (_done) return;
      for (final barcode in capture.barcodes) {
        final value = barcode.displayValue ?? barcode.rawValue;
        if (value != null && value.isNotEmpty && widget.onCode(value)) {
          _done = true;
          _controller.stop();
          return;
        }
      }
    },
  );
}
