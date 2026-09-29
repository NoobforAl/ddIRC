// Tests for the user's identities: a private label, and a throwaway nick per
// network that stays theirs across a session.
//
// Two promises, as with People: the identity works in memory whether or not
// anything is written to disk, and — the point of the feature — the nick a
// persona wears on a network is settled once and does not drift. History is
// off here, so the store is never touched; the disk half is tested in Rust.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/history.dart';
import 'package:ddirc/src/model/personas.dart';
import 'package:ddirc/src/model/profile.dart';

void main() {
  setUp(() => Personas.instance.resetForTest());

  group('Personas', () {
    test('creates, renames, and forgets identities', () async {
      final id = await Personas.instance.create('Work');
      expect(Personas.instance.all.single.label, 'Work');
      expect(Personas.instance.byId(id)?.label, 'Work');

      await Personas.instance.rename(id, 'Day job');
      expect(Personas.instance.byId(id)?.label, 'Day job');

      await Personas.instance.forget(id);
      expect(Personas.instance.isEmpty, isTrue);
    });

    test('orders identities by label', () async {
      await Personas.instance.create('Zephyr');
      await Personas.instance.create('anchor');
      expect(Personas.instance.all.map((p) => p.label), [
        'anchor',
        'Zephyr',
      ], reason: 'case-insensitive, so the list reads alphabetically');
    });

    test('a nick is minted once per network and then held', () async {
      expect(MessageHistory.instance.enabled, isFalse, reason: 'memory only');
      final id = await Personas.instance.create('Work');

      final first = await Personas.instance.nickFor(id, 'netA');
      final again = await Personas.instance.nickFor(id, 'netA');
      expect(again, first, reason: 'the same handle on the same network');

      final elsewhere = await Personas.instance.nickFor(id, 'netB');
      expect(
        elsewhere,
        isNot(first),
        reason: 'a different, unlinkable handle on another network',
      );

      expect(Personas.instance.assignedNick(id, 'netA'), first);
      expect(Personas.instance.assignedNick(id, 'netC'), isNull);
      expect(Personas.instance.nicksOf(id), {'netA': first, 'netB': elsewhere});
    });

    test('regenerate replaces the nick on a network', () async {
      final id = await Personas.instance.create('Work');
      final before = await Personas.instance.nickFor(id, 'netA');
      await Personas.instance.regenerate(id, 'netA');
      // With history off, regenerate only clears; the next ask mints anew.
      final after = await Personas.instance.nickFor(id, 'netA');
      expect(after, isNot(before));
    });

    test(
      'forgetting a network takes its nicks but keeps the identities',
      () async {
        final id = await Personas.instance.create('Work');
        await Personas.instance.nickFor(id, 'netA');
        await Personas.instance.nickFor(id, 'netB');

        await Personas.instance.forgetNetwork('netA');
        expect(Personas.instance.assignedNick(id, 'netA'), isNull);
        expect(Personas.instance.assignedNick(id, 'netB'), isNotNull);
        expect(
          Personas.instance.byId(id),
          isNotNull,
          reason: 'the identity lives',
        );
      },
    );

    test('notifies on every change', () async {
      var ticks = 0;
      void tick() => ticks++;
      Personas.instance.addListener(tick);
      addTearDown(() => Personas.instance.removeListener(tick));

      final id = await Personas.instance.create('Work');
      await Personas.instance.nickFor(id, 'netA');
      await Personas.instance.forget(id);
      expect(ticks, greaterThanOrEqualTo(3));
    });
  });

  group('generated nicks', () {
    test('are valid IRC nicks', () {
      final leading = RegExp(r'^[a-z]');
      final body = RegExp(r'^[a-z][a-z0-9]*$');
      for (var i = 0; i < 200; i++) {
        final nick = Personas.newNick();
        expect(nick.length, 8);
        expect(
          leading.hasMatch(nick),
          isTrue,
          reason: 'no leading digit: $nick',
        );
        expect(body.hasMatch(nick), isTrue, reason: 'alnum only: $nick');
      }
    });

    test('are not all the same', () {
      final seen = {for (var i = 0; i < 50; i++) Personas.newNick()};
      expect(seen.length, greaterThan(40), reason: 'random, not constant');
    });
  });

  group('Profile carries an identity', () {
    Profile base() => const Profile(
      id: 'p1',
      name: 'Net',
      host: 'irc.example.org',
      port: 6697,
      nickname: 'realname',
    );

    test('personaId round-trips through JSON, absent reads as null', () {
      final withPersona = base().copyWith(personaId: 'id1');
      final back = Profile.fromJson(withPersona.toJson())!;
      expect(back.personaId, 'id1');
      expect(back.usesPersona, isTrue);

      // A network saved before identities existed has no key at all.
      final legacy = base().toJson()..remove('personaId');
      expect(Profile.fromJson(legacy)!.personaId, isNull);
    });

    test('copyWith can set and clear the identity', () {
      final on = base().copyWith(personaId: 'id1');
      expect(on.personaId, 'id1');
      // The sentinel keeps it when unmentioned…
      expect(on.copyWith(name: 'Renamed').personaId, 'id1');
      // …and an explicit null clears it, back to the fixed nick.
      expect(on.copyWith(personaId: null).personaId, isNull);
    });

    test(
      'an identity nick overrides the typed one, with its own fallbacks',
      () {
        final config = base().toConfig(nicknameOverride: 'q7f3kx');
        expect(config.nickname, 'q7f3kx');
        expect(config.altNicks, [
          'q7f3kx_',
          'q7f3kx1',
        ], reason: 'fallbacks derive from the random nick, not the real one');

        final plain = base().toConfig();
        expect(plain.nickname, 'realname');
      },
    );
  });
}
