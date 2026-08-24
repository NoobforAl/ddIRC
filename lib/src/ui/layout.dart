import 'package:flutter/material.dart';

/// How much room the app has, as three named sizes.
///
/// The third token set, beside [Tokens] for colour and [Motion] for time. Read
/// it as `context.layout` and ask it questions — `layout.channelsPinned` —
/// rather than comparing widths at the call site. A pixel comparison buried in
/// a widget is a breakpoint nobody else can find, and the panes only look like
/// one app if they all change their mind at the same width.
///
/// Three sizes rather than two because there are two independent decisions to
/// make and they do not happen at the same width: the channel list is 210
/// wide and earns its place early, the member list is another 190 on the far
/// side and only earns it once the conversation between them is still wide
/// enough to read.
enum Layout {
  /// A phone, or a desktop window dragged narrow. The conversation owns the
  /// screen; everything else is a drawer away.
  compact,

  /// A tablet, a split-screen half, a small laptop window. Channels are
  /// pinned, members are on demand.
  medium,

  /// A desktop window. Everything on screen at once, nothing to open.
  expanded;

  /// Channels (210) plus the rail (56) leaves 454 for the conversation.
  static const mediumAt = 720.0;

  /// Both side panels plus the rail come to 456 of chrome, so this is the
  /// width at which the conversation still gets more room than they do.
  static const expandedAt = 1080.0;

  static Layout forWidth(double width) => width >= expandedAt
      ? expanded
      : width >= mediumAt
      ? medium
      : compact;

  bool get isCompact => this == compact;

  /// Whether the network rail and the channel list sit beside the
  /// conversation. When false they share a drawer: both answer "where am I",
  /// so on a narrow screen they are one question and one button.
  bool get channelsPinned => this != compact;

  /// Whether the member list sits beside the conversation.
  bool get membersPinned => this == expanded;

  /// Horizontal padding for anything spanning the conversation pane —
  /// messages, the topic, the connection bar. They share it so their text all
  /// starts on one vertical line.
  ///
  /// Narrower on a phone, where 20 on both sides is most of a word.
  double get gutter => isCompact ? 12 : 20;

  /// How wide a conversation tab may grow. Long channel names are ellipsised
  /// either way; this is about how many tabs stay reachable without scrolling.
  double get tabMaxWidth => isCompact ? 140 : 190;

  /// The width of a drawer, given the screen it has to fit inside.
  ///
  /// Never the full width: the strip of conversation left showing is what says
  /// the drawer is covering something rather than being a new screen.
  static double drawerWidth(double screenWidth, {required double preferred}) {
    final room = screenWidth - 48;
    return room < preferred ? room : preferred;
  }

  /// Falls back to the ambient [MediaQuery] where there is no [LayoutScope] —
  /// dialogs, which are routes of their own and sit above the one the app
  /// installs.
  static Layout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutScope>()?.layout ??
      forWidth(MediaQuery.sizeOf(context).width);
}

/// Publishes one [Layout] to the whole tree below it.
///
/// Measured once, at the top, from the space the app actually has rather than
/// from the size of the window: on desktop the window frame takes a strip off
/// the top, and on mobile a keyboard can take half the height. Everything below
/// then agrees, instead of each pane measuring its own slice and drawing a
/// different conclusion.
class LayoutScope extends InheritedWidget {
  const LayoutScope({super.key, required this.layout, required super.child});

  final Layout layout;

  @override
  bool updateShouldNotify(LayoutScope old) => old.layout != layout;
}

/// `context.layout` — the only way UI code should ask about size.
extension LayoutOf on BuildContext {
  Layout get layout => Layout.of(this);
}
