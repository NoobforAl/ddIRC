/// What this build calls itself, and how far along it is.
///
/// Duplicated from `pubspec.yaml` rather than read out of it. The manifest is
/// not on disk beside a shipped app, and the alternatives are a plugin or a
/// codegen step for one string. `test/version_test.dart` fails if the two
/// drift apart, which is the part that actually matters.
library;

const appVersion = '0.4.1';

/// How the app names itself where there is room for one line.
///
/// The beta half is not decoration. Nothing here has been through a security
/// review, most of the platforms it is configured for have still never built
/// it, and the README says both — but the person who most needs to know is the
/// one who never read it. So the app says it too, on the first screen and in
/// its settings.
///
/// One clause of this used to read "the Android build has never started on a
/// phone". That stopped being true in 0.3.0, and it is worth saying what
/// replaced it rather than quietly deleting it: Android has now been built,
/// installed and driven on hardware, including being killed and swiped away to
/// see what survives. iOS, macOS and Linux have not.
const appVersionLabel = 'ddIRC $appVersion — beta';
