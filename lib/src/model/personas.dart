import 'dart:math';

import 'package:flutter/foundation.dart';

import '../rust/api/store.dart' as store;
import 'history.dart';

/// One of the user's own identities.
///
/// A label the user keeps for themselves — "Work", "Anonymous" — that a
/// network never sees. What a network sees is a throwaway nick, generated once
/// per network and remembered, so the identity is stable on that one server
/// and unlinkable to the same person anywhere else. See [Personas].
@immutable
class Persona {
  const Persona({required this.id, required this.label});

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is Persona && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// The user's identities, and the nick each one wears on each network.
///
/// Memory-first, like [People]: it works whether or not anything is written to
/// disk, so a persona made with history off still connects. It is written
/// through to the history database only while that is on — the same switch,
/// because a map of which random nicks all belong to one person is a record of
/// exactly the kind history keeps, and the one most worth keeping private.
///
/// With history off the identities are forgotten on exit, so the nick a
/// persona wears on a server is stable only across a single run. That is why
/// the feature is offered from the UI only once history is on — see
/// `PersonaPicker` — but the model does not enforce it, so it stays testable
/// without a database and usable for the length of a session.
class Personas extends ChangeNotifier {
  Personas._();

  static final instance = Personas._();

  /// Identities, keyed by id.
  final Map<String, Persona> _personas = {};

  /// The nick each (persona, network) has been given, keyed `'$id/$networkId'`.
  final Map<String, String> _nicks = {};

  static String _nickKey(String personaId, String networkId) =>
      '$personaId/$networkId';

  /// Every identity, ordered by label so the list reads the way the user
  /// filed it rather than the order they happened to make them in.
  List<Persona> get all {
    final list = _personas.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return List.unmodifiable(list);
  }

  Persona? byId(String? id) => id == null ? null : _personas[id];

  /// Whether any identity exists, for the UI to decide between an empty state
  /// and a list.
  bool get isEmpty => _personas.isEmpty;

  /// Make a new identity with [label], and return its id.
  Future<String> create(String label) async {
    final id = _newId();
    await _write(Persona(id: id, label: label.trim()));
    return id;
  }

  /// Rename an existing identity.
  Future<void> rename(String id, String label) async {
    final persona = _personas[id];
    if (persona == null) return;
    await _write(Persona(id: id, label: label.trim()));
  }

  Future<void> _write(Persona persona) async {
    _personas[persona.id] = persona;
    notifyListeners();
    if (!MessageHistory.instance.enabled) return;
    try {
      await store.storeSetPersona(
        persona: store.Persona(id: persona.id, label: persona.label),
      );
    } catch (error) {
      debugPrint('ddIRC: could not save an identity ($error)');
    }
  }

  /// Forget an identity, and every remembered nick that was hers.
  Future<void> forget(String id) async {
    _personas.remove(id);
    _nicks.removeWhere((key, _) => key.startsWith('$id/'));
    notifyListeners();
    if (!MessageHistory.instance.enabled) return;
    try {
      await store.storeForgetPersona(id: id);
    } catch (error) {
      debugPrint('ddIRC: could not forget an identity ($error)');
    }
  }

  /// The nick [personaId] wears on [networkId], generated and remembered the
  /// first time it is asked for.
  ///
  /// Stable by construction: once a nick has been handed out for a pair it is
  /// returned unchanged, so a reconnect — or another render of the network
  /// editor — sees the same handle rather than minting a new one each time.
  Future<String> nickFor(String personaId, String networkId) async {
    final key = _nickKey(personaId, networkId);
    final existing = _nicks[key];
    if (existing != null) return existing;
    final nick = _generateNick();
    _nicks[key] = nick;
    notifyListeners();
    if (MessageHistory.instance.enabled) {
      try {
        await store.storeSetPersonaNick(
          nick: store.PersonaNick(
            personaId: personaId,
            networkId: networkId,
            nick: nick,
          ),
        );
      } catch (error) {
        debugPrint('ddIRC: could not save an identity\'s nick ($error)');
      }
    }
    return nick;
  }

  /// Forget every identity's nick on one network — for when the network
  /// itself is forgotten. The identities live on; only their handles on that
  /// server go.
  Future<void> forgetNetwork(String networkId) async {
    _nicks.removeWhere((key, _) {
      final slash = key.indexOf('/');
      return slash >= 0 && key.substring(slash + 1) == networkId;
    });
    notifyListeners();
    if (!MessageHistory.instance.enabled) return;
    try {
      await store.storeForgetPersonaNicks(networkId: networkId);
    } catch (error) {
      debugPrint('ddIRC: could not forget a network\'s nicks ($error)');
    }
  }

  /// The nick already assigned for a pair, without minting one. Null when none
  /// has been handed out yet — for the editor to show what a network *will*
  /// use without committing to it before the user saves.
  String? assignedNick(String personaId, String networkId) =>
      _nicks[_nickKey(personaId, networkId)];

  /// Throw away the nick a persona wears on a network, so the next connection
  /// mints a fresh one. For the "regenerate" control in the editor.
  Future<void> regenerate(String personaId, String networkId) async {
    _nicks.remove(_nickKey(personaId, networkId));
    notifyListeners();
    // Nothing to delete on disk necessarily — the row is overwritten next time
    // a nick is minted — but clear it now so a crash before then does not leave
    // the old handle behind.
    if (MessageHistory.instance.enabled) {
      // Re-mint immediately so the row on disk matches what the UI shows.
      await nickFor(personaId, networkId);
    }
  }

  /// Every remembered nick for one identity, for the manager to list which
  /// networks it has been seen on.
  Map<String, String> nicksOf(String personaId) {
    final prefix = '$personaId/';
    return {
      for (final entry in _nicks.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value,
    };
  }

  /// Bring memory and disk into step once the database is open, the way
  /// [People.sync] does: disk fills in what memory lacks, memory that predates
  /// the switch is written out, and nothing already in memory is overwritten.
  Future<void> sync() async {
    if (!MessageHistory.instance.enabled) return;
    try {
      for (final row in await store.storePersonas()) {
        _personas.putIfAbsent(
          row.id,
          () => Persona(id: row.id, label: row.label),
        );
      }
      final onDisk = <String>{};
      for (final row in await store.storePersonaNicks()) {
        final key = _nickKey(row.personaId, row.networkId);
        onDisk.add(key);
        _nicks.putIfAbsent(key, () => row.nick);
      }
      // Write out anything memory has that disk does not, so an identity made
      // before the switch was on is not lost by turning it on.
      for (final persona in _personas.values) {
        await store.storeSetPersona(
          persona: store.Persona(id: persona.id, label: persona.label),
        );
      }
      for (final entry in _nicks.entries) {
        if (onDisk.contains(entry.key)) continue;
        final slash = entry.key.indexOf('/');
        await store.storeSetPersonaNick(
          nick: store.PersonaNick(
            personaId: entry.key.substring(0, slash),
            networkId: entry.key.substring(slash + 1),
            nick: entry.value,
          ),
        );
      }
    } catch (error) {
      debugPrint('ddIRC: could not load identities ($error)');
      return;
    }
    notifyListeners();
  }

  String _generateNick() => newNick();

  /// A random, valid IRC nick with nothing in it that points back at the user.
  ///
  /// A leading letter (a nick may not start with a digit) and then seven more
  /// from a lower-case alphanumeric alphabet — eight characters, well inside
  /// every server's length limit, and enough space that a collision on one
  /// network is vanishingly unlikely.
  ///
  /// Static and side-effect-free, so a connection test can borrow one to dial
  /// with without minting and storing a handle the user has not committed to.
  static String newNick() {
    final random = Random();
    const first = 'abcdefghijklmnopqrstuvwxyz';
    const rest = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final buffer = StringBuffer()..write(first[random.nextInt(first.length)]);
    for (var i = 0; i < 7; i++) {
      buffer.write(rest[random.nextInt(rest.length)]);
    }
    return buffer.toString();
  }

  /// A unique id for a new identity.
  ///
  /// The clock alone is not enough: two identities made in the same microsecond
  /// — a fast hand, or a test — would collide and the second would overwrite
  /// the first. A random tail settles that; the id only has to be unique within
  /// one person's own small list.
  static String _newId() {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final salt = Random().nextInt(1 << 32).toRadixString(36);
    return 'id$micros$salt';
  }

  /// Drop everything held in memory. For tests.
  @visibleForTesting
  void resetForTest() {
    _personas.clear();
    _nicks.clear();
  }
}
