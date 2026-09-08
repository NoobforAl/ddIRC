import 'package:flutter/material.dart';

import 'menu.dart';

/// The three ways a network can start being added.
///
/// Distinct from browsing, which stays a button of its own: that path is for
/// somebody who does not yet know which network they want, where these three
/// are for somebody who already has an address, a `.irc` file or a QR code in
/// hand and wants the shortest way to it.
enum AddNetworkChoice {
  byHand,
  scan,
  import;

  IconData get icon => switch (this) {
    AddNetworkChoice.byHand => Icons.edit_outlined,
    AddNetworkChoice.scan => Icons.qr_code_scanner,
    AddNetworkChoice.import => Icons.file_open_outlined,
  };

  String get label => switch (this) {
    AddNetworkChoice.byHand => 'Add one by hand',
    AddNetworkChoice.scan => 'Scan a QR code',
    AddNetworkChoice.import => 'Import a .irc file',
  };
}

/// Offer the three at one point on screen, and return which was picked.
///
/// One menu rather than three buttons standing side by side: they used to be
/// exactly that — a rail crowded to five icons deep, an empty screen with a
/// button for each — and the choice among them is made once, on the way to
/// adding a network, not something worth permanent space next to Browse.
Future<AddNetworkChoice?> showAddNetworkMenu(BuildContext context, Offset at) {
  return showPointerMenu<AddNetworkChoice>(
    context,
    at: at,
    items: [
      for (final choice in AddNetworkChoice.values)
        PopupMenuItem(
          value: choice,
          child: MenuRow(icon: choice.icon, label: choice.label),
        ),
    ],
  );
}
