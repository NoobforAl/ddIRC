import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'settings/settings_chrome.dart';
import 'motion.dart';

/// Open a link someone sent — after showing where it actually goes.
///
/// A link in a chat line is a stranger's text. With markdown a link can wear
/// a label, `[anything at all](https://…)`, and the label can say one site
/// while the address is another. Even a bare address is cut off in a bubble
/// when it is long, and what is past the cut is exactly where a lookalike
/// domain hides. So the whole of it is shown before anything opens, taken
/// apart — the site, whether the connection is encrypted, the path — with a
/// warning for each trick a link can play. Opening a browser is leaving the
/// app, and it should be a step the user takes on purpose.
///
/// [label] is what the link was drawn as, when it was written with one.
///
/// Only `http` and `https`. Anything else — `file:`, `javascript:`, an app's
/// private scheme — is refused rather than handed to the platform.
Future<void> openLink(
  BuildContext context,
  String address, {
  String? label,
}) async {
  final uri = Uri.tryParse(address);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;

  final go = await showSoftDialog<bool>(
    context: context,
    builder: (context) => _OpenLinkDialog(uri: uri, label: label),
  );
  if (go != true) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Could not open the link ($error)')),
    );
  }
}

/// What is worth warning about in a link, in the order it matters. Kept
/// short: a warning nobody reads protects nobody. Plain http is not here —
/// the dialog's Security row already says so, in the same colour.
///
/// Public so the reasoning can be tested without a dialog.
List<String> linkWarnings(Uri uri, {String? label}) {
  final out = <String>[];
  final host = uri.host.toLowerCase();

  final said = label == null ? null : _domainIn(label);
  if (said != null && !_sameSite(said, host)) {
    out.add('Says $said, goes to $host.');
  }
  if (uri.userInfo.isNotEmpty) {
    out.add('The real site is $host, not "${uri.userInfo}".');
  }
  if (host.split('.').any((p) => p.startsWith('xn--')) ||
      host.runes.any((r) => r > 0x7F)) {
    out.add('The name uses look-alike characters.');
  }
  if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host) || host.contains(':')) {
    out.add('Goes to a bare IP address.');
  }
  return out;
}

/// The first thing in [text] that looks like a domain name, if any.
String? _domainIn(String text) {
  final m = RegExp(
    r'(?:https?://)?((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,})',
    caseSensitive: false,
  ).firstMatch(text);
  return m?[1]?.toLowerCase();
}

/// Whether two host names are the same site, give or take a `www.` or a
/// subdomain of one under the other.
bool _sameSite(String a, String b) {
  String bare(String h) => h.startsWith('www.') ? h.substring(4) : h;
  final x = bare(a);
  final y = bare(b);
  return x == y || x.endsWith('.$y') || y.endsWith('.$x');
}

class _OpenLinkDialog extends StatelessWidget {
  const _OpenLinkDialog({required this.uri, this.label});

  final Uri uri;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final secure = uri.isScheme('https');
    final warnings = linkWarnings(uri, label: label);
    final address = uri.toString();
    final shownAs = label != null && label!.trim() != address
        ? label!.trim()
        : null;
    final mono = TextStyle(
      color: t.text,
      fontSize: 12.5,
      height: 1.4,
      fontFamily: Fonts.mono,
      fontFamilyFallback: Fonts.monoFallback,
    );
    final caption = TextStyle(color: t.muted, fontSize: 11.5);

    Widget row(String name, Widget value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 64, child: Text(name, style: caption)),
          Expanded(child: value),
        ],
      ),
    );

    return SettingsDialog(
      title: 'Open this link?',
      width: 440,
      children: [
        // The site, big, because it is the one thing to check.
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
          child: Row(
            children: [
              Icon(
                secure ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 18,
                color: secure ? t.ok : t.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  uri.hasPort ? '${uri.host}:${uri.port}' : uri.host,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (shownAs != null)
                row(
                  'Shown as',
                  SelectableText(
                    shownAs,
                    style: TextStyle(color: t.text, fontSize: 13),
                  ),
                ),
              row(
                'Security',
                Text(
                  secure ? 'https' : 'http — not encrypted',
                  style: TextStyle(
                    color: secure ? t.text : t.warn,
                    fontSize: 13,
                  ),
                ),
              ),
              if (uri.hasQuery)
                row(
                  'Query',
                  SelectableText(
                    [
                      for (final e in uri.queryParametersAll.entries)
                        for (final v in e.value) '${e.key} = $v',
                    ].join('\n'),
                    style: mono,
                  ),
                ),
              if (uri.hasFragment)
                row('Anchor', SelectableText(uri.fragment, style: mono)),
            ],
          ),
        ),
        // The whole thing, in case any of the above was too tidy.
        Container(
          margin: const EdgeInsets.fromLTRB(18, 2, 18, 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: t.surfaceHover,
            borderRadius: BorderRadius.circular(Tokens.radiusXS),
          ),
          child: SelectableText(address, style: mono),
        ),
        for (final warning in warnings)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    size: 15,
                    color: t.warn,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    warning,
                    style: TextStyle(color: t.warn, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        const SettingsNote(
          text: 'Opens in your browser, outside ddIRC\'s proxy.',
        ),
        SettingsActions(
          children: [
            SettingsTertiaryButton(
              label: 'Copy link',
              onPressed: () {
                // Taken before the pop, which takes the context with it.
                final messenger = ScaffoldMessenger.maybeOf(context);
                Clipboard.setData(ClipboardData(text: address));
                Navigator.of(context).pop(false);
                messenger?.showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
            ),
            SettingsSecondaryButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(false),
            ),
            SettingsPrimaryButton(
              label: 'Open',
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ],
    );
  }
}
