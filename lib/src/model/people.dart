import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../rust/api/store.dart' as store;
import 'history.dart';

/// What the user has written down about one person: a name to show instead
/// of their nick, a note, a colour, a picture.
///
/// The user's annotation, never anything the person sent. Immutable; edit
/// with [copyWith] and hand the result to [People.set].
@immutable
class PersonCard {
  const PersonCard({
    this.alias,
    this.note,
    this.color,
    this.avatar,
    this.pixelSeed,
  });

  /// Shown in place of the nick wherever the nick would be shown.
  final String? alias;
  final String? note;

  /// Overrides the colour the nick hashes to.
  final Color? color;

  /// A small PNG, downscaled before it got here. Wins over [pixelSeed].
  final Uint8List? avatar;

  /// Seed for a generated pixel picture, when no photo was chosen.
  final int? pixelSeed;

  bool get isBlank =>
      alias == null &&
      note == null &&
      color == null &&
      avatar == null &&
      pixelSeed == null;

  /// Whether there is a picture of any kind to draw.
  bool get hasPicture => avatar != null || pixelSeed != null;

  /// Sentinel for "clear this field" in [copyWith], since null means "keep".
  static const clear = Object();

  PersonCard copyWith({
    Object? alias = clear,
    Object? note = clear,
    Object? color = clear,
    Object? avatar = clear,
    Object? pixelSeed = clear,
  }) => PersonCard(
    alias: identical(alias, clear) ? this.alias : alias as String?,
    note: identical(note, clear) ? this.note : note as String?,
    color: identical(color, clear) ? this.color : color as Color?,
    avatar: identical(avatar, clear) ? this.avatar : avatar as Uint8List?,
    pixelSeed: identical(pixelSeed, clear) ? this.pixelSeed : pixelSeed as int?,
  );

  store.Person toRow(String profileId, String nick) => store.Person(
    profileId: profileId,
    nick: nick,
    alias: alias,
    note: note,
    color: color?.toARGB32(),
    avatar: avatar,
    pixelSeed: pixelSeed,
  );

  static PersonCard fromRow(store.Person row) => PersonCard(
    alias: row.alias,
    note: row.note,
    color: row.color == null ? null : Color(row.color!),
    avatar: row.avatar,
    pixelSeed: row.pixelSeed,
  );

  @override
  bool operator ==(Object other) =>
      other is PersonCard &&
      other.alias == alias &&
      other.note == note &&
      other.color == color &&
      other.pixelSeed == pixelSeed &&
      listEquals(other.avatar, avatar);

  @override
  int get hashCode =>
      Object.hash(alias, note, color, pixelSeed, avatar?.length);
}

/// Everyone the user has annotated, on every network.
///
/// Always in memory, so the annotations work whether or not anything is
/// being written to disk. Written through to the history database only while
/// that is on — the same switch, because a list of who you talk to and what
/// you think of them is a record of the same kind as what they said. With it
/// off, closing the app forgets them, which is what "off" promised.
///
/// Keyed by network and nick, the nick folded to lower case: IRC treats
/// `Alice` and `alice` as one person, and so does a note about her.
class People extends ChangeNotifier {
  People._();

  static final instance = People._();

  final Map<String, PersonCard> _cards = {};

  static String _key(String profileId, String nick) =>
      '$profileId/${nick.toLowerCase()}';

  PersonCard? of(String profileId, String nick) =>
      _cards[_key(profileId, nick)];

  /// The name to show for [nick]: their alias if one is set, else the nick.
  String displayName(String profileId, String nick) =>
      of(profileId, nick)?.alias ?? nick;

  /// Record [card] for [nick], or forget them if it is blank.
  Future<void> set(String profileId, String nick, PersonCard card) async {
    final key = _key(profileId, nick);
    if (card.isBlank) {
      _cards.remove(key);
    } else {
      _cards[key] = card;
    }
    notifyListeners();
    if (!MessageHistory.instance.enabled) return;
    try {
      await store.storeSetPerson(
        person: card.toRow(profileId, nick.toLowerCase()),
      );
    } catch (error) {
      debugPrint('ddIRC: could not save a person ($error)');
    }
  }

  /// Forget everyone on one network, in memory and on disk.
  Future<void> forgetProfile(String profileId) async {
    _cards.removeWhere((key, _) => key.startsWith('$profileId/'));
    notifyListeners();
    if (!MessageHistory.instance.enabled) return;
    try {
      await store.storeForgetPeople(profileId: profileId);
    } catch (error) {
      debugPrint('ddIRC: could not forget a network\'s people ($error)');
    }
  }

  /// Bring memory and disk into step, once the database has been opened.
  ///
  /// Disk fills in what memory does not have; what memory has and disk does
  /// not is written, so a note made before the switch was turned on is not
  /// lost by turning it on. Where both have a person, memory wins — it is
  /// the more recent of the two by construction.
  Future<void> sync() async {
    if (!MessageHistory.instance.enabled) return;
    List<store.Person> rows;
    try {
      rows = await store.storePeople();
    } catch (error) {
      debugPrint('ddIRC: could not load people ($error)');
      return;
    }
    final onDisk = <String>{};
    for (final row in rows) {
      final key = _key(row.profileId, row.nick);
      onDisk.add(key);
      _cards.putIfAbsent(key, () => PersonCard.fromRow(row));
    }
    for (final entry in _cards.entries) {
      if (onDisk.contains(entry.key)) continue;
      final slash = entry.key.indexOf('/');
      try {
        await store.storeSetPerson(
          person: entry.value.toRow(
            entry.key.substring(0, slash),
            entry.key.substring(slash + 1),
          ),
        );
      } catch (error) {
        debugPrint('ddIRC: could not save a person ($error)');
      }
    }
    notifyListeners();
  }

  /// Drop everything held in memory. For tests.
  @visibleForTesting
  void resetForTest() {
    _cards.clear();
  }
}
