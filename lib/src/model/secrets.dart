import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one keychain handle in the app, configured once.
///
/// Every stored credential — SASL, the server `PASS`, NickServ, a proxy's own
/// password — goes through this. It exists because the defaults are wrong for
/// this app in two specific ways, and because a second `FlutterSecureStorage()`
/// constructed somewhere else would silently get those defaults back: options
/// are per-instance, not global, so "configured correctly" is only true of the
/// instance that was configured. There is one, and it is here.
///
/// ## What the platform gives us
///
/// Nothing here implements encryption. Each platform's own secret store does,
/// and each one is the right answer on its own terms:
///
/// | Platform | Store | Key lives in |
/// | --- | --- | --- |
/// | Android | `EncryptedSharedPreferences`, AES-GCM | Android Keystore, hardware-backed |
/// | iOS, macOS | Keychain Services | Secure Enclave / effaceable storage |
/// | Windows | DPAPI | The user's login credential |
/// | Linux | libsecret | The session keyring |
///
/// ## Why `first_unlock` on Apple platforms
///
/// The package default is [KeychainAccessibility.unlocked], which means an
/// item is readable only while the screen is unlocked. That is the right
/// default for an app that only runs when someone is looking at it, and the
/// wrong one for this app: ddIRC holds an IRC connection open in the
/// background so messages arrive, and a reconnect that happens while the phone
/// is in a pocket has to be able to read the password it authenticates with.
/// With `unlocked`, that read returns nothing, the reconnect registers
/// unauthenticated, and the user finds out when they next look — by which time
/// the failure is several hours old and looks like a server problem.
///
/// `first_unlock` keeps the item unreadable until the device has been unlocked
/// once since boot, which is the standard choice for a credential a background
/// task needs, and is what the platform documents it for.
///
/// [synchronizable] stays false: these are not going to iCloud. An encrypted
/// device backup still carries them, which is deliberate — see below.
///
/// ## Why Android's backup is handled in the manifest instead
///
/// There is no option here that fixes Android, because the problem is not in
/// this package. Android's auto-backup copies the app's shared preferences to
/// the cloud, including the file holding these ciphertexts. The Keystore key
/// that decrypts them is hardware-bound and non-exportable, so it does *not*
/// travel with the backup. Restore onto a new phone and the app finds
/// ciphertext it can never read — and with `resetOnError` on (the package
/// default, kept here) the plugin's answer to that is to delete it.
///
/// The result was every saved password silently disappearing on a phone
/// migration, while every profile survived, because profiles live in plain
/// settings that restore fine. A user would see their networks listed exactly
/// as before and simply fail to authenticate.
///
/// So the two preference files are excluded from backup and device transfer in
/// `android/app/src/main/res/xml/`. The passwords then do not come back on a
/// new device — which is the honest outcome, because they were never going to
/// be readable there — and the failure is one the user can act on: the field
/// is empty and says so, rather than being full of something that does not
/// work.
///
/// Apple's restore is not broken in that way — an encrypted backup carries
/// keychain items with the material needed to read them — so nothing is
/// excluded there. The platforms differ because the platforms differ.
const secrets = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
);
