import 'package:flutter/material.dart';

import '../model/profile.dart';
import '../model/session.dart';
import '../model/workspace.dart';
import '../rust/api/types.dart';
import '../theme.dart';
import 'channel_list.dart';
import 'member_list.dart';
import 'message_view.dart';
import 'settings/app_settings_dialog.dart';
import 'settings/channel_settings_dialog.dart';
import 'settings/profile_editor_dialog.dart';
import 'settings/server_settings_dialog.dart';

/// Below this width the side panels become drawers.
const _wideLayout = 900.0;
const _channelPanelWidth = 210.0;
const _memberPanelWidth = 190.0;

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session});

  final SessionModel session;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scaffold = GlobalKey<ScaffoldState>();
  String? _error;

  SessionModel get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_onChanged);
  }

  @override
  void dispose() {
    session.removeListener(_onChanged);
    _composer.dispose();
    _composerFocus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    final error = await session.submit(text);
    if (!mounted) return;
    setState(() => _error = error);
    // Keep the caret where the user is typing — losing focus after a command
    // means reaching for the mouse to say the next thing.
    _composerFocus.requestFocus();
  }

  void _select(String name) {
    session.select(name);
    if (MediaQuery.of(context).size.width < _wideLayout) {
      Navigator.of(context).maybePop();
    }
  }

  void _disconnect() {
    // The workspace owns the connection's lifetime; there is no route to pop,
    // because other networks may still be up behind this one.
    WorkspaceScope.of(context).disconnect(session.profileId);
  }

  void _openChannelSettings([Conversation? conversation]) {
    final target = conversation ?? session.active;
    if (target == null) return;
    ChannelSettingsDialog.show(context, session: session, conversation: target);
  }

  void _openServerSettings() =>
      ServerSettingsDialog.show(context, session: session);

  void _openAppSettings() => AppSettingsDialog.show(context);

  void _openNetworkEditor() {
    final profile = ProfileScope.of(context).byId(session.profileId);
    if (profile == null) return;
    ProfileEditorDialog.show(context, profile: profile);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= _wideLayout;
    final active = session.active;

    final channels = ChannelList(
      session: session,
      networkName:
          ProfileScope.of(context).byId(session.profileId)?.name ?? 'ddIRC',
      onSelect: _select,
      onDisconnect: _disconnect,
      onChannelSettings: _openChannelSettings,
      onAppSettings: _openAppSettings,
    );
    final members = active == null
        ? const SizedBox.shrink()
        : MemberList(
            members: active.members,
            onClose: wide ? null : () => Navigator.of(context).maybePop(),
          );

    return Scaffold(
      key: _scaffold,
      drawer: wide
          ? null
          : Drawer(width: 260, child: SafeArea(child: channels)),
      endDrawer: wide || active == null || !active.isChannel
          ? null
          : Drawer(width: 240, child: SafeArea(child: members)),
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              SizedBox(
                width: _channelPanelWidth,
                child: Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      right: BorderSide(
                        color: Tokens.rule,
                        width: Tokens.hairline,
                      ),
                    ),
                  ),
                  child: channels,
                ),
              ),
            Expanded(child: _conversationPane(wide, active)),
            if (wide && active != null && active.isChannel)
              SizedBox(
                width: _memberPanelWidth,
                child: Container(
                  decoration: const BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: Tokens.rule,
                        width: Tokens.hairline,
                      ),
                    ),
                  ),
                  child: members,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _conversationPane(bool wide, Conversation? active) {
    return Column(
      children: [
        _Header(
          session: session,
          conversation: active,
          wide: wide,
          onOpenChannels: () => _scaffold.currentState?.openDrawer(),
          onOpenMembers: () => _scaffold.currentState?.openEndDrawer(),
          onChannelSettings: _openChannelSettings,
          onServerSettings: _openServerSettings,
          onNetworkEditor: _openNetworkEditor,
          onAppSettings: _openAppSettings,
        ),
        if (active?.topic != null) _TopicBar(topic: active!.topic!),
        Expanded(
          child: active == null
              ? const Center(
                  child: Text(
                    'Not in a channel yet.\nUse /join #channel below.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Tokens.faint,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                )
              : MessageView(
                  // Rebuild the scroll state when switching conversations.
                  key: ValueKey(active.name),
                  conversation: active,
                ),
        ),
        if (_error != null) _ErrorBar(text: _error!),
        _composerBar(active),
      ],
    );
  }

  Widget _composerBar(Conversation? active) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      decoration: const BoxDecoration(
        color: Tokens.surface,
        border: Border(
          top: BorderSide(color: Tokens.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _composer,
              focusNode: _composerFocus,
              onSubmitted: (_) => _submit(),
              textInputAction: TextInputAction.send,
              maxLines: 4,
              minLines: 1,
              autocorrect: false,
              style: const TextStyle(color: Tokens.text, fontSize: 14),
              decoration: InputDecoration(
                // The hint always explains the state, so a composer that
                // cannot send never looks simply broken.
                hintText: active == null
                    ? 'Join a channel to talk — try /join #channel'
                    : 'Message ${active.name}',
                hintStyle: const TextStyle(color: Tokens.faint, fontSize: 14),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                enabledBorder: _border(Tokens.rule, Tokens.hairline),
                focusedBorder: _border(Tokens.accent, 1),
              ),
            ),
          ),
          IconButton(
            onPressed: _submit,
            icon: const Icon(Icons.arrow_upward, size: 19),
            color: Tokens.accent,
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: color, width: width),
      );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.session,
    required this.conversation,
    required this.wide,
    required this.onOpenChannels,
    required this.onOpenMembers,
    required this.onChannelSettings,
    required this.onServerSettings,
    required this.onNetworkEditor,
    required this.onAppSettings,
  });

  final SessionModel session;
  final Conversation? conversation;
  final bool wide;
  final VoidCallback onOpenChannels;
  final VoidCallback onOpenMembers;
  final VoidCallback onChannelSettings;
  final VoidCallback onServerSettings;
  final VoidCallback onNetworkEditor;
  final VoidCallback onAppSettings;

  @override
  Widget build(BuildContext context) {
    final unread = session.totalUnread;

    return Container(
      padding: EdgeInsets.fromLTRB(wide ? 20 : 4, 8, 8, 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Tokens.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        children: [
          if (!wide)
            Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  onPressed: onOpenChannels,
                  icon: const Icon(Icons.menu, size: 20),
                  color: Tokens.muted,
                  tooltip: 'Channels',
                ),
                if (unread > 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 8, right: 8),
                    child: _Dot(color: Tokens.accent, size: 6),
                  ),
              ],
            ),
          _StatusDot(status: session.status),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              conversation?.name ?? session.nick,
              style: const TextStyle(
                color: Tokens.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (conversation != null && conversation!.isChannel)
            if (wide)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  '${conversation!.members.length}',
                  style: const TextStyle(color: Tokens.muted, fontSize: 13),
                ),
              )
            else
              TextButton.icon(
                onPressed: onOpenMembers,
                icon: const Icon(Icons.people_outline, size: 17),
                label: Text('${conversation!.members.length}'),
                style: TextButton.styleFrom(
                  foregroundColor: Tokens.muted,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          _SettingsMenu(
            hasChannel: conversation != null,
            channelName: conversation?.name,
            onChannelSettings: onChannelSettings,
            onServerSettings: onServerSettings,
            onNetworkEditor: onNetworkEditor,
            onAppSettings: onAppSettings,
          ),
        ],
      ),
    );
  }
}

/// The one place every settings dialog can be reached from.
enum _SettingsTarget { channel, server, network, app }

class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({
    required this.hasChannel,
    required this.channelName,
    required this.onChannelSettings,
    required this.onServerSettings,
    required this.onNetworkEditor,
    required this.onAppSettings,
  });

  final bool hasChannel;
  final String? channelName;
  final VoidCallback onChannelSettings;
  final VoidCallback onServerSettings;
  final VoidCallback onNetworkEditor;
  final VoidCallback onAppSettings;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_SettingsTarget>(
      icon: const Icon(Icons.tune, size: 18),
      color: Tokens.surface,
      elevation: 0,
      tooltip: 'Settings',
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Tokens.rule, width: Tokens.hairline),
      ),
      onSelected: (target) => switch (target) {
        _SettingsTarget.channel => onChannelSettings(),
        _SettingsTarget.server => onServerSettings(),
        _SettingsTarget.network => onNetworkEditor(),
        _SettingsTarget.app => onAppSettings(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _SettingsTarget.channel,
          // Disabled rather than hidden, so the menu never changes shape and
          // the reason is legible: there is no channel to configure.
          enabled: hasChannel,
          child: _MenuRow(
            icon: Icons.tag,
            label: channelName == null
                ? 'Channel settings'
                : 'Channel settings — $channelName',
            enabled: hasChannel,
          ),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.server,
          child: _MenuRow(icon: Icons.dns_outlined, label: 'Server settings'),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.network,
          child: _MenuRow(
            icon: Icons.edit_outlined,
            label: 'Edit this network…',
          ),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.app,
          child: _MenuRow(icon: Icons.settings_outlined, label: 'App settings'),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Tokens.text : Tokens.faint;
    return Row(
      children: [
        Icon(icon, size: 15, color: enabled ? Tokens.muted : Tokens.faint),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      ConnectionStatus_Connected() => (Tokens.ok, 'Connected'),
      ConnectionStatus_Connecting() => (Tokens.warn, 'Connecting'),
      ConnectionStatus_Registering() => (Tokens.warn, 'Registering'),
      ConnectionStatus_Reconnecting(:final retryInSecs) => (
        Tokens.warn,
        'Reconnecting in ${retryInSecs}s',
      ),
      ConnectionStatus_Disconnected() => (Tokens.bad, 'Disconnected'),
    };
    return Tooltip(
      message: label,
      child: _Dot(color: color, size: 8),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _TopicBar extends StatelessWidget {
  const _TopicBar({required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 7, 20, 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Tokens.rule, width: Tokens.hairline),
        ),
      ),
      child: Tooltip(
        message: topic,
        child: Text(
          topic,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Tokens.muted,
            fontSize: 12,
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

/// Command errors show inline above the composer — never as a dialog.
class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      color: Tokens.bad.withValues(alpha: 0.10),
      child: Text(
        text,
        style: const TextStyle(color: Tokens.bad, fontSize: 12),
      ),
    );
  }
}
