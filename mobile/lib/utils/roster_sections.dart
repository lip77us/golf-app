/// roster_sections.dart
///
/// How the player picker's list is cut and labelled once a filter is on.
///
/// Kept out of the screen because the rules are worth pinning down on their
/// own: filtering never touches the selection, and search composes with the
/// filter rather than replacing it. The screen supplies the roster already in
/// display order and this preserves it, so ordering stays the screen's
/// business and sectioning stays here.
///
/// (Favorites used to be pinned here. They were removed on 14 Nov 2026 — see
/// `widgets/roster_filter.dart`.)
library;

import '../api/models.dart';
import '../widgets/roster_filter.dart';

/// One labelled block of the picker's list: "ON HALVED 4", "ALL GOLFERS A – Z".
/// [trailing] is whatever belongs on the header's right edge — a count under a
/// filter, the A–Z reminder under All.
class RosterSection {
  const RosterSection(this.label, this.trailing, this.players);

  final String label;
  final String trailing;
  final List<PlayerProfile> players;
}

/// Split [roster] into the sections the picker draws under [filter].
///
/// [roster] arrives in display order and comes out in it. [query] narrows every
/// filter alike.
List<RosterSection> rosterSections({
  required RosterFilter filter,
  required List<PlayerProfile> roster,
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  final visible = q.isEmpty
      ? roster
      : roster.where((p) => p.name.toLowerCase().contains(q)).toList();

  switch (filter) {
    case RosterFilter.all:
      return [RosterSection('All golfers', 'A – Z', visible.toList())];

    case RosterFilter.onHalved:
      final onHalved = visible.where((p) => p.isOnApp).toList();
      return [RosterSection('On Halved', '${onHalved.length}', onHalved)];
  }
}
