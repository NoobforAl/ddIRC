/// What this build calls itself, and how far along it is.
///
/// Duplicated from `pubspec.yaml` rather than read out of it. The manifest is
/// not on disk beside a shipped app, and the alternatives are a plugin or a
/// codegen step for one string. `test/version_test.dart` fails if the two
/// drift apart, which is the part that actually matters.
library;

const appVersion = '0.2.0';

/// How the app names itself where there is room for one line.
///
/// The beta half is not decoration. Nothing here has been through a security
/// review, the Android build has never started on a phone, and the README says
/// both — but the person who most needs to know is the one who never read it.
/// So the app says it too, on the first screen and in its settings.
const appVersionLabel = 'ddIRC $appVersion — beta';
