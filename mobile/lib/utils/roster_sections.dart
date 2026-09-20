/// roster_sections.dart
///
/// How the player picker's list is cut and labelled once a filter is on.
///
/// Kept out of the screen because the rules are worth pinning down on their
/// own: favorites are PINNED under All rather than moved, filtering never
/// touches the selection, and search composes with the filter rather than
/// replacing it.  The screen supplies the roster already in display order and
/// this preserves it, so ordering stays the screen's business and sectioning
/// stays here.
///
/// Design reference: handoff-select-players §§1–2, 5.
library;

import '../api/models.dart';
import '../widgets/roster_filter.dart';

/// One labelled block of the picker's list: "FAVORITES 9", "ALL GOLFERS A – Z".
/// [trailing] is whatever belongs on the header's right edge — a count under
/// most filters, the A–Z reminder under All, the hint to tap a flag under
/// Favorites.
class RosterSection {
  const RosterSection(this.label, this.trailing, this.players);

  final String label;
  final String trailing;
  final List<PlayerProfile> players;
}

/// Split [roster] into the sections the picker draws under [filter].
///
/// [roster] arrives in display order and comes out in it.  [shortlist] is the
/// set of golfer ids drawn with a planted flag — which is not quite the set of
/// favorites, because one being unset inside its Undo window is still held on
/// screen.  [query] narrows every filter alike: typing inside Favorites
/// searches favorites only.
List<RosterSection> rosterSections({
  required RosterFilter filter,
  required List<PlayerProfile> roster,
  required Set<int> shortlist,
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  final visible = q.isEmpty
      ? roster
      : roster.where((p) => p.name.toLowerCase().contains(q)).toList();

  switch (filter) {
    case RosterFilter.all:
      // Favorites appear TWICE while BROWSING — once pinned, once in their
      // alphabetical place.  Deliberate: somebody scrolling to M for Dave
      // Moran should find him under M, not discover he has been moved.  The
      // pinned section is a shortcut, not a relocation.
      //
      // While SEARCHING it does not appear at all.  That argument is about
      // scrolling a roster of a couple of hundred names, and a query has
      // already done the scrolling — in a list of four the shortcut buys
      // nothing and costs the same golfer printed twice, which just reads as
      // a bug.
      final favorites = q.isEmpty
          ? visible.where((p) => shortlist.contains(p.id)).toList()
          : const <PlayerProfile>[];
      return [
        if (favorites.isNotEmpty)
          RosterSection('Favorites', '${favorites.length}', favorites),
        RosterSection('All golfers', 'A – Z', visible.toList()),
      ];

    case RosterFilter.favorites:
      return [
        RosterSection(
          'Your favorites',
          'tap a flag to remove',
          visible.where((p) => shortlist.contains(p.id)).toList(),
        ),
      ];

    case RosterFilter.onHalved:
      final onHalved = visible.where((p) => p.isOnApp).toList();
      return [RosterSection('On Halved', '${onHalved.length}', onHalved)];
  }
}
