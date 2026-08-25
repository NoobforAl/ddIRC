import 'package:flutter/material.dart';

import '../../model/proxy.dart';
import '../../rust/api/client.dart' as core;
import 'proxy_form.dart';
import 'settings_chrome.dart';

/// The app-wide proxy, as shown in App settings.
///
/// The only part of that dialog with an explicit save, and the reason is that
/// it is the only part with a half-typed state. Every other setting there is a
/// switch or a choice, where the intermediate value is a value; `127.0.0` is
/// not an address, and applying it the moment it is typed would break every
/// connection on the way to a working one.
///
/// Two buttons rather than a switch beside a form, because a switch that can
/// be on while the form beside it says something else is a lie about what the
/// app is doing. Here the state is a sentence, and the buttons change it.
class GlobalProxySection extends StatefulWidget {
  const GlobalProxySection({super.key});

  @override
  State<GlobalProxySection> createState() => _GlobalProxySectionState();
}

class _GlobalProxySectionState extends State<GlobalProxySection> {
  ProxyFormController? _form;
  int _shake = 0;
  bool _busy = false;

  ProxyFormController _controllerFor(ProxySettings settings) {
    final existing = _form;
    if (existing != null) return existing;
    final form =
        ProxyFormController(
          endpoint: settings.endpoint,
          hasStoredPassword: settings.endpoint?.usesAuth ?? false,
          // Tor's port, because Tor is what most people reaching for this are
          // reaching for; 1080 would be a guess at a proxy nobody named.
          defaultPort: core.torSocksPort(),
        )..addListener(() {
          if (mounted) setState(() {});
        });
    _form = form;
    return form;
  }

  @override
  void dispose() {
    _form?.dispose();
    super.dispose();
  }

  Future<void> _apply(ProxySettings settings) async {
    final form = _controllerFor(settings);
    final errors = form.validate();
    if (errors.isNotEmpty) {
      setState(() {
        form.errors
          ..clear()
          ..addAll(errors);
        _shake++;
      });
      return;
    }

    setState(() => _busy = true);
    await settings.save(
      enabled: true,
      endpoint: form.build(),
      password: form.passwordToSave(),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _stop(ProxySettings settings) async {
    setState(() => _busy = true);
    // The address is kept, only switched off: turning it back on later should
    // not mean typing it again, and the form above still shows what it was.
    await settings.save(enabled: false, endpoint: settings.endpoint);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ProxyScope.of(context);
    final form = _controllerFor(settings);
    final active = settings.active;

    return SettingsSection(
      label: 'Proxy',
      children: [
        SettingsReadout(
          label: 'Status',
          value: active == null
              ? 'Off — connections go direct'
              : 'On — ${active.label}',
        ),
        SettingsReadout(
          label: 'Applies to',
          value: active == null
              ? 'Nothing, until it is switched on'
              : 'Every network set to "App default"',
        ),
        ProxyFields(
          controller: form,
          shakeTick: _shake,
          onSubmitted: _busy ? null : () => _apply(settings),
        ),
        SettingsActions(
          children: [
            if (active != null)
              SettingsDangerButton(
                label: 'Stop using it',
                onPressed: _busy ? null : () => _stop(settings),
              ),
            SettingsPrimaryButton(
              label: active == null ? 'Use this proxy' : 'Save changes',
              onPressed: _busy ? null : () => _apply(settings),
            ),
          ],
        ),
      ],
    );
  }
}
