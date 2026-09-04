import 'package:flutter/material.dart';

import '../../model/proxy.dart';
import 'settings_chrome.dart';

/// The four things a SOCKS5 proxy needs.
enum ProxyField { host, port, username, password }

/// The state behind [ProxyFields], owned by whichever dialog is showing them.
///
/// A controller rather than a self-contained widget because both places that
/// show these fields already validate on save and need the typed values at that
/// moment. A widget that only reported changes outward would mean each dialog
/// keeping a shadow copy of what the user typed, which is the arrangement that
/// lets a form and its data disagree.
class ProxyFormController {
  /// [defaultPort] is what an unconfigured form starts on. Passed in rather
  /// than looked up, so this class stays plain form state that a test can
  /// build without the native library loaded.
  ProxyFormController({
    ProxyEndpoint? endpoint,
    required this.hasStoredPassword,
    int defaultPort = 9050,
  }) : _fields = {
         ProxyField.host: TextEditingController(text: endpoint?.host ?? ''),
         ProxyField.port: TextEditingController(
           text: '${endpoint?.port ?? defaultPort}',
         ),
         ProxyField.username: TextEditingController(
           text: endpoint?.username ?? '',
         ),
         ProxyField.password: TextEditingController(),
       };

  /// Whether the keychain already holds a password for this proxy, so a blank
  /// field can mean "keep it" rather than "clear it".
  final bool hasStoredPassword;

  final Map<ProxyField, TextEditingController> _fields;
  final Map<ProxyField, String> errors = {};

  bool _passwordTouched = false;
  bool get passwordTouched => _passwordTouched;

  TextEditingController controller(ProxyField field) => _fields[field]!;

  String text(ProxyField field) => _fields[field]!.text.trim();

  /// Clear one field's error as it is retyped, and notice the password being
  /// touched. Called by the owning dialog's own listener wiring.
  void onEdited(ProxyField field) {
    errors.remove(field);
    if (field == ProxyField.password) _passwordTouched = true;
  }

  void addListener(VoidCallback listener) {
    for (final entry in _fields.entries) {
      entry.value.addListener(() {
        onEdited(entry.key);
        listener();
      });
    }
  }

  /// True when nothing has been typed at all, so an untouched form can be
  /// treated as "no proxy" rather than as four validation errors.
  bool get isEmpty =>
      text(ProxyField.host).isEmpty &&
      text(ProxyField.username).isEmpty &&
      _fields[ProxyField.password]!.text.isEmpty;

  Map<ProxyField, String> validate() {
    final found = <ProxyField, String>{};

    if (text(ProxyField.host).isEmpty) {
      found[ProxyField.host] = 'Enter the proxy address.';
    }

    final port = int.tryParse(text(ProxyField.port));
    if (text(ProxyField.port).isEmpty) {
      found[ProxyField.port] = 'Required.';
    } else if (port == null || port < 1 || port > 65535) {
      found[ProxyField.port] = 'Must be 1-65535.';
    }

    // Both or neither: SOCKS5 sends them as a pair, and the transport answers
    // a lone username with a message about byte lengths that explains nothing.
    final username = text(ProxyField.username);
    final password = _fields[ProxyField.password]!.text;
    if (username.isNotEmpty && password.isEmpty && !hasStoredPassword) {
      found[ProxyField.password] = 'Required with a username.';
    }
    if (username.isEmpty && password.isNotEmpty) {
      found[ProxyField.username] = 'Required with a password.';
    }
    // One length byte each on the wire, so this is a hard ceiling rather than
    // a limit the proxy might be lenient about.
    if (username.length > 255) {
      found[ProxyField.username] = 'At most 255 characters.';
    }
    if (password.length > 255) {
      found[ProxyField.password] = 'At most 255 characters.';
    }

    return found;
  }

  /// The endpoint as typed. Only meaningful once [validate] has passed.
  ProxyEndpoint build() => ProxyEndpoint(
    host: text(ProxyField.host),
    port: int.parse(text(ProxyField.port)),
    username: text(ProxyField.username).isEmpty
        ? null
        : text(ProxyField.username),
  );

  /// What to write to the keychain: null to leave the stored password alone.
  ///
  /// An untouched field on a proxy that already has one means "keep it", which
  /// is why editing the port does not wipe the credential.
  String? passwordToSave() =>
      _passwordTouched ? _fields[ProxyField.password]!.text : null;

  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
  }
}

/// Address, port and optional credentials for a SOCKS5 proxy.
class ProxyFields extends StatelessWidget {
  const ProxyFields({
    super.key,
    required this.controller,
    required this.shakeTick,
    this.onSubmitted,
  });

  final ProxyFormController controller;
  final int shakeTick;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: _field(
                ProxyField.host,
                'Address',
                hint: '127.0.0.1',
                // The paragraph that used to sit under all four fields, split
                // so each half is beside the field it is actually about. A
                // note under a form is read by nobody; a note under the field
                // it describes is read by the person filling that field in.
                help:
                    'SOCKS5 only. The proxy carries the connection but never '
                    'sees inside it: TLS is still negotiated with the IRC '
                    'server itself, and the server name is resolved at the '
                    'proxy rather than here.',
              ),
            ),
            Expanded(child: _field(ProxyField.port, 'Port')),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(ProxyField.username, 'Username', hint: 'Optional'),
            ),
            Expanded(
              child: _field(
                ProxyField.password,
                'Password',
                obscure: true,
                hint: controller.hasStoredPassword
                    ? 'Stored — leave blank to keep it'
                    : 'Optional',
                help:
                    'Sent to the proxy in the clear, if the proxy asks for '
                    'one. It proves who you are to the proxy and protects '
                    'nothing else.',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _field(
    ProxyField field,
    String label, {
    String? hint,
    String? help,
    bool obscure = false,
  }) => SettingsLabelledField(
    label: label,
    controller: controller.controller(field),
    hint: hint,
    help: help,
    obscure: obscure,
    error: controller.errors[field],
    shakeTick: shakeTick,
    onSubmitted: (_) => onSubmitted?.call(),
  );
}
