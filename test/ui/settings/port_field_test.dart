// A port is up to five digits, and the box for it has to show all five.
//
// It was a flex-1 sliver beside a flex-3 address, about 60 pixels of text
// area: `6697` fitted, `52675` showed as "5267" and a sliver of the next digit,
// so what had been typed could not be read back. Ports above 9999 are common —
// one of this app's own test networks is on 52675 — and a field that clips the
// number it exists to show is a field that gets the number wrong without
// anyone seeing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/proxy_form.dart';

void main() {
  for (final port in ['6697', '52675', '65535']) {
    testWidgets('the proxy form\'s port box shows $port whole', (tester) async {
      final form = ProxyFormController(hasStoredPassword: false);
      addTearDown(form.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          // The width of the narrowest dialog the form appears in.
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 380,
                child: ProxyFields(controller: form, shakeTick: 0),
              ),
            ),
          ),
        ),
      );

      // The port is the second text field: address, port, username, password.
      final portBox = find.byType(EditableText).at(1);
      await tester.enterText(portBox, port);
      await tester.pump();

      // How much room the field gives its text, against what a number of this
      // length needs. The need is an estimate — 0.62em a digit, which the
      // widest digits of ordinary sans fonts stay under — because the test
      // harness draws every glyph a full em wide, and measuring the number
      // there would call a box too small that is plenty for real text.
      final style = tester.widget<EditableText>(portBox).style;
      final room = tester
          .state<EditableTextState>(portBox)
          .renderEditable
          .size
          .width;
      final needed = port.length * 0.62 * style.fontSize!;

      expect(
        room,
        greaterThanOrEqualTo(needed),
        reason: '$port needs about ${needed}px and the box has ${room}px',
      );
    });
  }
}
