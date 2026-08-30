import 'package:flutter/material.dart';

import '../../model/app_lock.dart';
import '../../model/biometrics.dart';
import 'settings_chrome.dart';

/// Whether opening ddIRC asks for a fingerprint, face or the device passcode.
///
/// Turning it on asks for that confirmation first, so the switch cannot land
/// in the "on" position on a device with nothing enrolled and nothing able to
/// unlock it again. Turning it off needs no confirmation — locking someone
/// out is the failure worth guarding, not the reverse.
class AppLockSection extends StatefulWidget {
  const AppLockSection({super.key});

  @override
  State<AppLockSection> createState() => _AppLockSectionState();
}

class _AppLockSectionState extends State<AppLockSection> {
  final _bio = Biometrics();
  bool _busy = false;
  String? _error;

  Future<void> _set(AppLockSettings lock, bool on) async {
    if (!on) {
      await lock.setEnabled(false);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await _bio.authenticate('Confirm to turn on app lock');
    if (ok) await lock.setEnabled(true);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _error =
            'Could not confirm — biometrics may not be set up on this '
            'device.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lock = AppLockScope.of(context);
    return SettingsSection(
      label: 'App lock',
      children: [
        SettingsSwitch(
          label: 'Require biometrics to open ddIRC',
          description:
              'Uses your device\'s fingerprint, face or PIN. Asked for when '
              'ddIRC starts and every time you return to it. Off by default. '
              'Connections already open are not affected — this only gates '
              'what is on screen.',
          value: lock.enabled,
          onChanged: _busy ? (_) {} : (v) => _set(lock, v),
        ),
        if (_error != null) SettingsNote(text: _error!, isError: true),
      ],
    );
  }
}
