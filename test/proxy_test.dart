// Tests for the proxy setting.
//
// The thing worth pinning here is the *resolution*: which of two settings wins
// for a given network, and whose password goes with it. Every other bug in
// this feature is visible — a proxy that will not connect says so. Getting
// resolution wrong is silent, and silent is the failure mode that matters:
// a connection that quietly goes direct when the user believes it is proxied
// looks exactly like one that worked.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/rust/api/types.dart' as core;
import 'package:ddirc/src/ui/settings/proxy_form.dart';

const _tor = ProxyEndpoint(host: '127.0.0.1', port: 9050);
const _other = ProxyEndpoint(host: 'proxy.example.org', port: 1080);

Profile _profile({
  ProxyMode mode = ProxyMode.followDefault,
  ProxyEndpoint? own,
}) => Profile(
  id: 'p1',
  name: 'Libera',
  host: 'irc.libera.chat',
  port: 6697,
  nickname: 'ddirc',
  proxyMode: mode,
  proxy: own,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the app-wide setting', () {
    test('is off, and stays off until something is saved', () async {
      final settings = await ProxySettings.load();
      expect(settings.enabled, isFalse);
      expect(settings.endpoint, isNull);
      expect(settings.active, isNull);
    });

    test('remembers the address after being switched off', () async {
      final settings = await ProxySettings.load();
      await settings.save(enabled: true, endpoint: _tor);
      expect(settings.active, _tor);

      await settings.save(enabled: false, endpoint: settings.endpoint);
      // Off, but not forgotten: turning it back on must not mean typing the
      // address again, and the form still has something to show.
      expect(settings.active, isNull);
      expect(settings.endpoint, _tor);
    });

    test('cannot be on with nothing behind it', () async {
      // A switch that is on with no address would fail every connection for a
      // reason the settings screen does not display.
      final settings = await ProxySettings.load();
      await settings.save(enabled: true, endpoint: null);
      expect(settings.enabled, isFalse);
      expect(settings.active, isNull);
    });

    test('survives a reload', () async {
      final settings = await ProxySettings.load();
      await settings.save(enabled: true, endpoint: _other);

      final reloaded = await ProxySettings.load();
      expect(reloaded.active, _other);
    });
  });

  group('resolution', () {
    late ProfileStore profiles;

    setUp(() async => profiles = await ProfileStore.load());

    Future<ProxySettings> globalProxy({ProxyEndpoint? endpoint}) async {
      final settings = await ProxySettings.load();
      if (endpoint != null) {
        await settings.save(enabled: true, endpoint: endpoint);
      }
      return settings;
    }

    test('a profile with no opinion takes the app-wide proxy', () async {
      final settings = await globalProxy(endpoint: _tor);
      final resolved = await resolveProxy(_profile(), settings, profiles);
      expect(resolved?.host, '127.0.0.1');
      expect(resolved?.port, 9050);
    });

    test('and gets nothing when the app-wide proxy is off', () async {
      final settings = await globalProxy();
      expect(await resolveProxy(_profile(), settings, profiles), isNull);
    });

    test('Direct refuses the app-wide proxy', () async {
      // The whole reason Direct is a separate choice rather than an empty
      // field: this network must not be swept up when the app proxy goes on.
      final settings = await globalProxy(endpoint: _tor);
      final profile = _profile(mode: ProxyMode.direct);
      expect(await resolveProxy(profile, settings, profiles), isNull);
    });

    test('Custom wins over the app-wide proxy', () async {
      final settings = await globalProxy(endpoint: _tor);
      final profile = _profile(mode: ProxyMode.custom, own: _other);
      final resolved = await resolveProxy(profile, settings, profiles);
      expect(resolved?.host, 'proxy.example.org');
      expect(resolved?.port, 1080);
    });

    test('Custom with nothing set connects directly', () async {
      // Not a fallback to the app-wide proxy: the user said this network has
      // its own, so taking a different one would be answering a question they
      // did not ask.
      final settings = await globalProxy(endpoint: _tor);
      final profile = _profile(mode: ProxyMode.custom);
      expect(await resolveProxy(profile, settings, profiles), isNull);
    });
  });

  group('the built-in Tor route', () {
    late ProfileStore profiles;

    setUp(() async => profiles = await ProfileStore.load());

    // No Tor is running in a test, so `active` is null throughout this group.
    // That is not a limitation — it is the state the tests are here for. "Tor
    // is switched on and is not up" is exactly the window in which a wrong
    // answer connects someone in the clear.
    Future<ProxySettings> onTor() async {
      final settings = await ProxySettings.load();
      await settings.useBuiltIn(true);
      return settings;
    }

    test('is on, and waiting, before Tor has a port', () async {
      final settings = await onTor();
      expect(settings.route, ProxyRoute.builtIn);
      expect(settings.enabled, isTrue);
      expect(settings.active, isNull);
      expect(settings.waiting, isTrue);
    });

    test('refuses to resolve rather than resolving to direct', () async {
      // The single most important assertion in this file. `null` means
      // *direct*; if this returned null the connection would succeed, in the
      // clear, over the route the user had just asked not to use.
      final settings = await onTor();
      await expectLater(
        resolveProxy(_profile(), settings, profiles),
        throwsA(isA<ProxyUnavailable>()),
      );
    });

    test('refuses for a network set to Direct too', () async {
      // Direct means "not the app-wide address". It does not mean "outside
      // Tor": there is no per-network way to want that.
      final settings = await onTor();
      final profile = _profile(mode: ProxyMode.direct);
      await expectLater(
        resolveProxy(profile, settings, profiles),
        throwsA(isA<ProxyUnavailable>()),
      );
    });

    test('refuses for a network with its own proxy too', () async {
      final settings = await onTor();
      final profile = _profile(mode: ProxyMode.custom, own: _other);
      await expectLater(
        resolveProxy(profile, settings, profiles),
        throwsA(isA<ProxyUnavailable>()),
      );
    });

    test('overrides every network, so nothing keeps its own answer', () async {
      final settings = await onTor();
      expect(settings.overridesProfiles, isTrue);

      final off = await ProxySettings.load();
      await off.save(enabled: true, endpoint: _other);
      expect(off.overridesProfiles, isFalse);
    });

    test('gives the manual address back when it is switched off', () async {
      final settings = await ProxySettings.load();
      await settings.save(enabled: true, endpoint: _other);
      await settings.useBuiltIn(true);
      expect(settings.route, ProxyRoute.builtIn);

      await settings.useBuiltIn(false);
      // Not straight to off: turning Tor off should leave the setting where it
      // was before Tor rather than discarding a proxy the user configured.
      expect(settings.route, ProxyRoute.manual);
      expect(settings.active, _other);
    });

    test('goes to off when there was no manual address', () async {
      final settings = await onTor();
      await settings.useBuiltIn(false);
      expect(settings.route, ProxyRoute.off);
      expect(settings.waiting, isFalse);
    });

    test('survives a reload', () async {
      await (await ProxySettings.load()).useBuiltIn(true);
      final reloaded = await ProxySettings.load();
      expect(reloaded.route, ProxyRoute.builtIn);
      expect(reloaded.waiting, isTrue);
    });

    test('reads a setting saved before routes existed', () async {
      // The upgrade path. A proxy that switched itself off on upgrade would
      // send the next connection somewhere the user did not choose.
      SharedPreferences.setMockInitialValues({
        'proxy.enabled': true,
        'proxy.endpoint.v1': '{"host":"proxy.example.org","port":1080}',
      });
      final settings = await ProxySettings.load();
      expect(settings.route, ProxyRoute.manual);
      expect(settings.active, _other);
    });
  });

  group('a saved profile', () {
    test('round-trips its proxy', () {
      final profile = _profile(mode: ProxyMode.custom, own: _other);
      final back = Profile.fromJson(profile.toJson());
      expect(back?.proxyMode, ProxyMode.custom);
      expect(back?.proxy, _other);
    });

    test('from before proxies existed follows the app default', () {
      // The upgrade path. Anything else would change what an existing profile
      // does on the first launch after an update.
      final back = Profile.fromJson({
        'id': 'p1',
        'name': 'Libera',
        'host': 'irc.libera.chat',
        'port': 6697,
        'nickname': 'ddirc',
      });
      expect(back?.proxyMode, ProxyMode.followDefault);
      expect(back?.proxy, isNull);
    });

    test('needs its own keychain entry only when it authenticates its own '
        'proxy', () {
      const withAuth = ProxyEndpoint(
        host: '127.0.0.1',
        port: 9050,
        username: 'me',
      );
      expect(
        _profile(mode: ProxyMode.custom, own: withAuth).usesProxyAuth,
        isTrue,
      );
      // Following the app default means the app's credential, not one of ours.
      expect(_profile(own: withAuth).usesProxyAuth, isFalse);
      expect(
        _profile(mode: ProxyMode.custom, own: _tor).usesProxyAuth,
        isFalse,
      );
    });
  });

  group('the rail tooltip', () {
    test('says how a live connection reached its server', () {
      final line = networkTooltip(
        'OFTC',
        const core.ProxyConfig(host: '127.0.0.1', port: 9050),
      );
      expect(line, 'OFTC\nThrough 127.0.0.1:9050');
    });

    test('says "directly" just as plainly when there is no proxy', () {
      // The half that matters. A label that appears only when a proxy is in
      // use says nothing by its absence, and believing a connection is
      // proxied when it is not is the failure this exists to catch.
      expect(networkTooltip('OFTC', null), 'OFTC\nConnected directly');
    });

    test('reports no route for a network that is not connected', () {
      // Nothing has been reached yet, so there is nothing true to say. What
      // an unconnected profile *would* use is the editor's business.
      expect(networkTooltip('OFTC', null, live: false), 'OFTC');
      expect(
        networkTooltip(
          'OFTC',
          const core.ProxyConfig(host: '127.0.0.1', port: 9050),
          live: false,
        ),
        'OFTC',
      );
    });
  });

  group('the form', () {
    late ProxyFormController form;

    void type({String? host, String? port, String? user, String? password}) {
      if (host != null) form.controller(ProxyField.host).text = host;
      if (port != null) form.controller(ProxyField.port).text = port;
      if (user != null) form.controller(ProxyField.username).text = user;
      if (password != null) {
        form.controller(ProxyField.password).text = password;
      }
    }

    setUp(() => form = ProxyFormController(hasStoredPassword: false));
    tearDown(() => form.dispose());

    test("defaults to Tor's port", () {
      expect(form.text(ProxyField.port), '9050');
    });

    test('wants an address and a usable port', () {
      expect(form.validate().keys, contains(ProxyField.host));

      type(host: '127.0.0.1', port: '70000');
      expect(form.validate().keys, contains(ProxyField.port));

      type(port: '9050');
      expect(form.validate(), isEmpty);
    });

    test('refuses half a credential, in either direction', () {
      // SOCKS5 sends them as a pair. A lone username makes the transport
      // complain about byte lengths, which names the wrong problem.
      type(host: '127.0.0.1', user: 'me');
      expect(form.validate().keys, contains(ProxyField.password));

      type(user: '', password: 'secret');
      expect(form.validate().keys, contains(ProxyField.username));

      type(user: 'me');
      expect(form.validate(), isEmpty);
    });

    test('accepts a blank password when one is already stored', () {
      final stored = ProxyFormController(
        endpoint: const ProxyEndpoint(
          host: '127.0.0.1',
          port: 9050,
          username: 'me',
        ),
        hasStoredPassword: true,
      );
      addTearDown(stored.dispose);
      expect(stored.validate(), isEmpty);
      // And leaves it alone rather than clearing it, so editing the port does
      // not silently drop the credential.
      expect(stored.passwordToSave(), isNull);
    });

    test('holds SOCKS5 to its one length byte', () {
      type(host: '127.0.0.1', user: 'u' * 256, password: 'p');
      expect(form.validate().keys, contains(ProxyField.username));

      type(user: 'u' * 255, password: 'p' * 256);
      expect(form.validate().keys, contains(ProxyField.password));

      type(password: 'p' * 255);
      expect(form.validate(), isEmpty);
    });
  });
}
