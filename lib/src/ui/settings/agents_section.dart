import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../model/mcp.dart';
import '../../theme.dart';
import 'settings_chrome.dart';

/// The agent server, as shown in App settings — beta.
///
/// One switch, then everything needed to point an agent at it: the address,
/// the token, and a ready-made command for Claude Code. Below that, what has
/// been asked of it lately, so it is never a black box.
class AgentsSection extends StatefulWidget {
  const AgentsSection({super.key});

  @override
  State<AgentsSection> createState() => _AgentsSectionState();
}

class _AgentsSectionState extends State<AgentsSection> {
  bool _busy = false;
  bool _showToken = false;

  Future<void> _set(McpService mcp, bool on) async {
    setState(() => _busy = true);
    await mcp.setEnabled(on);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('$what copied'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mcp = McpScope.of(context);
    final t = context.tokens;
    final endpoint = mcp.endpoint;
    final token = mcp.token;
    final command = mcp.claudeCodeCommand;

    return SettingsSection(
      label: 'Agents (MCP)',
      beta: true,
      help:
          'A Model Context Protocol server, so an AI agent — Claude Code, '
          'Claude Desktop, or any MCP client — can read your conversations '
          'and draft messages.\n\n'
          'An agent can list networks and conversations, read and search '
          'messages, and ask to send one. Every send is shown to you first, '
          'in full, and goes nowhere unless you approve it. It cannot join, '
          'leave or run commands.\n\n'
          'Only this machine can reach it, and only with the token. '
          'Regenerating the token cuts off every agent that has the old one. '
          'While the app is locked, it answers nothing.',
      children: [
        SettingsSwitch(
          label: 'Let agents connect',
          description:
              'Runs a local MCP server. Agents can read what is in your open '
              'conversations; nothing is sent without your approval.',
          value: mcp.enabled,
          onChanged: _busy ? (_) {} : (v) => _set(mcp, v),
        ),
        if (mcp.enabled) ...[
          SettingsReadout(
            label: 'Status',
            value: mcp.running ? 'Running' : 'Not running',
            valueColor: mcp.running ? t.ok : t.muted,
          ),
          if (endpoint != null)
            SettingsReadout(label: 'Address', value: endpoint, monospace: true),
          if (token != null)
            SettingsReadout(
              label: 'Token',
              value: _showToken ? token : '•' * 16,
              monospace: true,
            ),
          if (mcp.failure != null)
            SettingsNote(text: mcp.failure!, isError: true),
          SettingsActions(
            children: [
              if (token != null)
                SettingsTertiaryButton(
                  label: _showToken ? 'Hide token' : 'Show token',
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
              if (token != null)
                SettingsSecondaryButton(
                  label: 'Copy token',
                  onPressed: () => _copy(token, 'Token'),
                ),
              if (command != null)
                SettingsSecondaryButton(
                  label: 'Copy Claude Code command',
                  onPressed: () => _copy(command, 'Command'),
                ),
            ],
          ),
          SettingsActions(
            children: [
              if (mcp.allowedCount > 0)
                SettingsTertiaryButton(
                  label:
                      'Ask again everywhere (${mcp.allowedCount} always '
                      'allowed)',
                  onPressed: mcp.forgetAllowed,
                ),
              SettingsTertiaryButton(
                label: 'New token',
                onPressed: mcp.regenerateToken,
              ),
            ],
          ),
          if (mcp.activity.isNotEmpty) ...[
            const SettingsRule(),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
              child: Text(
                'Recent activity',
                style: TextStyle(
                  color: t.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final entry in mcp.activity.take(8))
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 2, 18, 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      entry.ok ? Icons.check_rounded : Icons.block_rounded,
                      size: 14,
                      color: entry.ok ? t.muted : t.bad,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${entry.tool} — ${entry.summary}',
                        style: TextStyle(color: t.muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}
