import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../theme.dart';
import 'settings_chrome.dart';

/// Point the camera at a QR code and read back whatever it says.
///
/// Deliberately hands back raw text rather than parsed networks: this dialog
/// knows nothing about the `.irc` format and should not have to — that stays
/// with whoever reads the result, the same way picking a file with
/// `openFile` hands back bytes rather than networks. A scanner that also
/// knew the schema would be two things to change every time the schema did.
///
/// `mobile_scanner` owns the Android/iOS camera permission itself, so unlike
/// the notification and background-service permissions this app asks for
/// over its own method channel, there is nothing to request here beyond
/// showing the camera and letting the plugin's own prompt happen.
class QrScanDialog extends StatefulWidget {
  const QrScanDialog({super.key});

  /// Returns the decoded text, or null if the dialog was closed without a
  /// code being read.
  static Future<String?> show(BuildContext context) {
    return showDialog<String>(
      context: context,
      builder: (_) => const QrScanDialog(),
    );
  }

  @override
  State<QrScanDialog> createState() => _QrScanDialogState();
}

class _QrScanDialogState extends State<QrScanDialog> {
  final _controller = MobileScannerController();

  /// Set the moment a code is read, so a second frame decoded before the
  /// dialog has finished closing cannot pop a result twice.
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SettingsDialog(
      title: 'Scan a QR code',
      subtitle: 'Point the camera at a ddIRC network code',
      actions: [
        ValueListenableBuilder<MobileScannerState>(
          valueListenable: _controller,
          builder: (context, state, _) => IconButton(
            onPressed: state.torchState == TorchState.unavailable
                ? null
                : _controller.toggleTorch,
            icon: Icon(
              state.torchState == TorchState.on
                  ? Icons.flash_on
                  : Icons.flash_off,
              size: 18,
            ),
            color: t.muted,
            visualDensity: VisualDensity.compact,
            tooltip: 'Toggle the flashlight',
          ),
        ),
      ],
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: t.rule, width: Tokens.hairline),
                ),
                child: MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                ),
              ),
            ),
          ),
        ),
        const SettingsProse(
          'Works with a QR code exported from ddIRC on another device, or '
          'made from a `.irc` file by any QR generator. Nothing is added '
          'until the next screen says so.',
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}
