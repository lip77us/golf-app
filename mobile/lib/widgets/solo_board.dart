/// widgets/solo_board.dart
///
/// The solo card: the status chips, the hole result line and the scorecard
/// with its Won row. `handoff-solo-games`.
///
/// Solo plays through the universal score-entry screen — one golfer with no
/// per-hole decision to make is exactly what that screen already does, and a
/// dedicated screen would be six hundred lines of duplicated entry machinery
/// (pending scores, the offline overlay, withdrawal, the combo-tee chip) for
/// three read-outs. These are those three read-outs.
///
/// **Red is a SIDE here, not a loss.** `docs/color-standard.md` reserves
/// green/red for meaning and gives teams blue/orange, and this is a
/// deliberate deviation from it: par is the OPPONENT in a solo round, the
/// handoff names its colour, and the Won row's two chips are both the letter
/// P — Paul and Par — told apart by colour alone. Quota Nassau already draws
/// its two sides blue and red, so the pairing is not new to the app.
library;

import 'package:flutter/material.dart';

import '../game_catalog.dart';
import 'hole_grid_scorecard.dart';

/// The golfer. The handoff's `#1976D2`, which is also `GameColors.team1`.
const Color soloGolfer = Color(0xFF1976D2);

/// Par. See the note above about why this is red.
const Color soloPar = Color(0xFFD32F2F);

/// Which solo variant a round's active games imply, or null for a round that
/// is not solo at all.
String? soloVariantOf(List<String> activeGames) {
  if (activeGames.contains(GameIds.soloNassau)) return 'nassau';
  if (activeGames.contains(GameIds.soloMatch)) return 'match';
  if (activeGames.contains(GameIds.soloStroke)) return 'stroke';
  return null;
}

/// What each variant is CALLED.
///
/// One map, because three places need it — the setup screen's title, the
/// hub's Edit button and the leaderboard tab's label (which the server sends
/// from `SoloGame.get_variant_display`, and these have to agree with it).
/// They deliberately match the multi-player games: a golfer on his own is
/// still playing Stroke Play.
const Map<String, String> soloGameNames = {
  'stroke': 'Stroke Play',
  'nassau': 'Nassau',
  'match': 'Match Play',
};

String soloGameName(String? variant) => soloGameNames[variant] ?? 'Solo';

/// `1 UP` / `1 DN` / `AS`, from the golfer's side — par never has a side to
/// read it from, so there is no perspective question here as there is on a
/// two-sided card.
String soloUpLabel(int up) {
  if (up == 0) return 'AS';
  return '${up.abs()} ${up > 0 ? 'UP' : 'DN'}';
}

// ── the hole result line ────────────────────────────────────────────────────

/// What just happened on this hole, in the handoff's words.
///
/// Stroke Play gets the score against par (`Par on a par 3.`); the two match
/// games get the score AND what it did to the match (`Par. Hole halved.`),
/// because in those two the second sentence is the game and the first is
/// just how it was arrived at.
String? soloHoleLine(Map<String, dynamic>? hole, String variant) {
  if (hole == null) return null;
  final par = hole['par'] as int?;
  final toPar = hole['to_par'] as int?;
  if (par == null || toPar == null) return null;

  final name = switch (toPar) {
    <= -3 => 'Albatross',
    -2 => 'Eagle',
    -1 => 'Birdie',
    0 => 'Par',
    1 => 'Bogey',
    2 => 'Double bogey',
    _ => '$toPar over',
  };
  if (variant == 'stroke') return '$name on a par $par.';
  final did = switch (hole['result'] as String?) {
    'won' => 'Hole won.',
    'lost' => 'Hole lost.',
    _ => 'Hole halved.',
  };
  return '$name. $did';
}

/// The line under the hole card. Net, so it says so once rather than on every
/// hole: the number it is reading is the golfer's net.
class SoloHoleLine extends StatelessWidget {
  final Map<String, dynamic>? hole;
  final String variant;
  const SoloHoleLine({super.key, required this.hole, required this.variant});

  @override
  Widget build(BuildContext context) {
    final text = soloHoleLine(hole, variant);
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final result = hole?['result'] as String?;
    final colour = variant == 'stroke'
        ? theme.colorScheme.onSurfaceVariant
        : (result == 'won'
            ? soloGolfer
            : result == 'lost'
                ? soloPar
                : theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(text,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: colour, fontWeight: FontWeight.w600)),
    );
  }
}

// ── the status chips ────────────────────────────────────────────────────────

/// Above the pager: the one reading that matches the variant.
///
/// Stroke Play shows the net total against par and how far through the round
/// it is. The two match games show the match, which is the whole game, and
/// how much of it is left — a margin without the holes remaining cannot be
/// read, because 3 up is a win on the 16th and nothing on the 4th.
class SoloStatusBar extends StatelessWidget {
  final Map<String, dynamic> solo;
  const SoloStatusBar({super.key, required this.solo});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final variant = solo['variant'] as String? ?? 'stroke';
    final chips = <Widget>[];

    if (variant == 'stroke') {
      final st = (solo['stroke'] as Map?) ?? const {};
      final toPar = (st['to_par'] as num?)?.toInt() ?? 0;
      chips.add(_chip(
        theme,
        'Net',
        toPar == 0 ? 'E' : (toPar > 0 ? '+$toPar' : '$toPar'),
        toPar == 0
            ? theme.colorScheme.onSurfaceVariant
            : (toPar < 0 ? Colors.green.shade700 : Colors.red.shade700),
      ));
      chips.add(_chip(theme, 'Thru', '${(st['thru'] as num?)?.toInt() ?? 0}',
          theme.colorScheme.onSurfaceVariant));
    } else if (variant == 'nassau') {
      final n = (solo['nassau'] as Map?) ?? const {};
      for (final e in [('F9', 'front'), ('B9', 'back'), ('ALL', 'overall')]) {
        final m = (n[e.$2] as Map?) ?? const {};
        final up = (m['up'] as num?)?.toInt() ?? 0;
        // A nine every hole of which is in is finished, and an outlined chip
        // is how it says so — the number cannot move again.
        final done = ((m['thru'] as num?)?.toInt() ?? 0) >=
            ((m['holes'] as num?)?.toInt() ?? 9);
        chips.add(_chip(theme, e.$1, m['decided'] as String? ?? soloUpLabel(up),
            _upColour(theme, up), outlined: done));
      }
      for (final nine in ['front', 'back']) {
        final presses =
            ((n[nine] as Map?)?['presses'] as List?) ?? const [];
        for (final p in presses) {
          final up = ((p as Map)['up'] as num?)?.toInt() ?? 0;
          chips.add(_chip(
              theme,
              '${nine == 'front' ? 'F9' : 'B9'} Press ${p['index']}',
              p['decided'] as String? ?? soloUpLabel(up),
              _upColour(theme, up)));
        }
      }
    } else {
      final m = (solo['match'] as Map?) ?? const {};
      final up = (m['up'] as num?)?.toInt() ?? 0;
      chips.add(_chip(theme, 'Match',
          m['decided'] as String? ?? soloUpLabel(up), _upColour(theme, up)));
      chips.add(_chip(theme, 'To play',
          '${(m['to_play'] as num?)?.toInt() ?? 0}',
          theme.colorScheme.onSurfaceVariant));
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Wrap(spacing: 6, runSpacing: 6, children: chips),
    );
  }

  Color _upColour(ThemeData theme, int up) => up == 0
      ? theme.colorScheme.onSurfaceVariant
      : (up > 0 ? soloGolfer : soloPar);

  Widget _chip(ThemeData theme, String label, String value, Color colour,
      {bool outlined = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: outlined ? null : colour.withValues(alpha: 0.10),
        border: outlined ? Border.all(color: colour.withValues(alpha: 0.6)) : null,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(width: 5),
        Text(value,
            style: theme.textTheme.labelMedium
                ?.copyWith(fontWeight: FontWeight.w800, color: colour)),
      ]),
    );
  }
}

// ── the scorecard ───────────────────────────────────────────────────────────

/// The standard card, in solo's colours, with the Won row under it.
///
/// Both chips are the letter P — Paul and Par — so the row is read by colour
/// alone, which is why they are chips on a tint rather than flat text.
/// Stroke Play has no Won row: there are no holes to win in it.
class SoloScorecard extends StatelessWidget {
  final Map<String, dynamic> solo;
  const SoloScorecard({super.key, required this.solo});

  @override
  Widget build(BuildContext context) {
    final rows = ((solo['holes'] as List?) ?? const [])
        .map((h) => Map<String, dynamic>.from(h as Map))
        .toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    final pid = solo['player_id'] as int?;
    if (pid == null) return const SizedBox.shrink();

    final grid = [
      for (final h in rows)
        {
          'hole': h['hole'],
          'par': h['par'],
          'stroke_index': h['stroke_index'],
          'scores': [
            {
              'player_id': pid,
              'gross': h['gross'],
              'strokes': h['strokes'] ?? 0,
            }
          ],
        }
    ];
    final resultOf = {
      for (final h in rows) h['hole'] as int: h['result'] as String?
    };
    final variant = solo['variant'] as String? ?? 'stroke';

    return HoleGridScorecard(
      holes: grid,
      participants: [
        {
          'player_id': pid,
          'name': solo['player_name'],
          'short_name': solo['player_name'],
        }
      ],
      // Nothing in this card is a skin, and the green winner tint never
      // fires: a solo hole's winner is par or the golfer, which the Won row
      // says in words.
      legend: null,
      holesInPlay: [for (final h in rows) h['hole'] as int],
      parColor: soloPar,
      playerColor: soloGolfer,
      footerRows: variant == 'stroke'
          ? const []
          : [
              HoleGridFooterRow(
                label: 'Won',
                text: (h) => switch (resultOf[h]) {
                  'won' => 'P',
                  'lost' => 'P',
                  // A halved hole is blank. "AS" would be a third mark for
                  // the thing that happened on most holes.
                  _ => null,
                },
                colour: (h) =>
                    resultOf[h] == 'won' ? soloGolfer : soloPar,
                fill: (h) => (resultOf[h] == 'won' ? soloGolfer : soloPar)
                    .withValues(alpha: resultOf[h] == 'won' ? 0.15 : 0.13),
              ),
            ],
    );
  }
}

// ── the leaderboard board ───────────────────────────────────────────────────

/// The solo round's leaderboard tab.
///
/// A solo round has no standings — there is one golfer and he is not racing
/// anybody — so the board is the same three pieces the play screen carries,
/// with the golfer named above them. Without it the tab fell through to
/// `_RawJsonView` and printed the API payload, which is the fault
/// `leaderboard_screen.dart`'s own `match_play` case is a note about.
class SoloBoard extends StatelessWidget {
  final Map<String, dynamic> data;
  const SoloBoard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (data['configured'] != true) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('This solo game has not been set up yet.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }
    final ch = (data['course_handicap'] as num?)?.toInt();
    final tee = data['tee_name'] as String? ?? '';
    final pct = (data['net_percent'] as num?)?.toInt() ?? 100;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(data['player_name'] as String? ?? 'You',
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700, color: soloGolfer)),
                  ),
                  Text('vs Par',
                      style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700, color: soloPar)),
                ]),
                const SizedBox(height: 2),
                Text(
                  [
                    if (ch != null) 'CH $ch',
                    if (tee.isNotEmpty) tee,
                    'Net $pct%',
                  ].join(' · '),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                SoloStatusBar(solo: data),
                const SizedBox(height: 8),
                SoloScorecard(solo: data),
                const SizedBox(height: 4),
                // No money line, and nothing to settle: a solo round
                // contributes nothing to `round_settlement`.
                Text('For fun. No stakes.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
