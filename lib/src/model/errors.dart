import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

/// Turn a caught object into something worth showing a user.
///
/// Errors crossing the FFI boundary arrive wrapped. `AnyhowException`'s
/// `toString` is `AnyhowException(<message>)` — parentheses, not a colon —
/// so the obvious "strip everything before the colon" tidy-up silently does
/// nothing, and the wrapper is shown to the user along with the message the
/// core went to the trouble of writing.
///
/// Unwrapping by type rather than by pattern, so this cannot quietly stop
/// working the way a regex over a `toString` did.
String describeError(Object? error) {
  if (error == null) return 'Something went wrong.';

  if (error is AnyhowException) return _tidy(error.message);

  // A panic is our bug, not a mistake the user made, and saying so is the
  // difference between them checking their settings for an hour and filing
  // the report that gets it fixed.
  if (error is PanicException) {
    return 'ddIRC hit an internal error. This is a bug — please report it.\n'
        '${_tidy(error.message)}';
  }

  return _tidy('$error');
}

/// Strip a leading `SomethingException:` and surrounding whitespace.
///
/// For the ordinary Dart exceptions, whose `toString` really does use a colon.
String _tidy(String message) {
  final stripped = message
      .replaceFirst(RegExp(r'^\w*(Exception|Error):\s*'), '')
      .trim();
  return stripped.isEmpty ? 'Something went wrong.' : stripped;
}
