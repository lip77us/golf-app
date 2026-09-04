/// survivor_rail.dart
///
/// The Survivor rail (R5) — the primary artefact of the Survivor design
/// (docs/design-review/handoff-survivor-zombie-v2/README.md).
///
/// Two stacked parts over one shared hole ruler:
///
///   * **the winner bar** — one bar per Survivor, spanning exactly the holes
///     it covered. Its LENGTH answers how long the Survivor ran; its LABEL
///     answers who took it.
///   * **survival lanes** — one row per golfer, one cell per hole. They answer
///     how long each golfer lasted.
///
/// Earlier drafts spent a row per golfer and never drew the game itself, or
/// drew the game and flattened the golfers into initials. Four rows carry both
/// readings, which is why this shape won.
///
/// Lives in `widgets/` because the rail appears on the leaderboard AND the
/// play screen; building it into either would guarantee two of them.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';

/// Solid plum marks **whoever is in the seat now**, not whoever opened it.
///
/// The packet flags this as a live tension and offers both readings. Following
/// the current occupant is the one chosen, for two reasons: it makes every
/// handover visible (the opener-only reading draws nothing when the seat
/// changes hands), and it is what the lock-screen track already does — so plum
/// means one thing on every surface, which is the packet's own rule 5.
class SurvivorRail extends StatelessWidget {
  const SurvivorRail({
    super.key,
    required this.holesInPlay,
    required this.players,
    required this.holes,
    required this.survivors,
    required this.zombieOn,
  });

  /// Hole numbers, in play order.
  final List<int> holesInPlay;

  /// `[{player_id, name, short_name}]`, in scorecard order.
  final List<Map<String, dynamic>> players;

  /// `summary['holes']` — carries eliminated / resurrected / winner per hole.
  final List<Map<String, dynamic>> holes;

  /// `summary['survivors']` — start_hole, end_hole, winner_short, payout.
  final List<Map<String, dynamic>> survivors;

  final bool zombieOn;

  /// The same rail, from the typed summary the play screen already holds.
  ///
  /// Two constructors rather than one shape, because the two callers genuinely
  /// differ: the leaderboard reads a raw `games['survivor'].by_group[n].summary`
  /// map, the play screen holds a decoded `SurvivorSummary`. Converting either
  /// way at the call site would put the mapping in two places, which is how the
  /// rail becomes two rails.
  factory SurvivorRail.fromSummary({
    Key? key,
    required SurvivorSummary summary,
    required List<int> holesInPlay,
  }) =>
      SurvivorRail(
        key: key,
        holesInPlay: holesInPlay,
        zombieOn: summary.zombieOption,
        players: [
          for (final p in summary.players)
            {'player_id': p.playerId,
             'name': p.name,
             'short_name': p.shortName},
        ],
        holes: [
          for (final h in summary.holes)
            {'hole': h.hole,
             'survivor': h.survivor,
             'eliminated_id': h.eliminatedId,
             'resurrected_id': h.resurrectedId,
             'winner_id': h.winnerId,
             'entries': [
               for (final e in h.entries)
                 {'player_id': e.playerId, 'gross': e.gross},
             ]},
        ],
        survivors: [
          for (final sv in summary.survivors)
            {'holes': sv.holes,
             'start_hole': sv.startHole,
             'end_hole': sv.endHole,
             'winner_id': sv.winnerId,
             'winner_short': sv.winnerShort,
             'outcome': sv.outcome,
             'payout': sv.payout},
        ],
      );

  static const double _labelW = 34;
  static const double _gap    = 2;

  Map<int, Map<String, dynamic>> get _byHole =>
      {for (final h in holes) (h['hole'] as int? ?? -1): h};

  /// One lane cell per golfer per hole.
  ///
  /// `gone` covers both an ordinary eliminated golfer and a Zombie's holes
  /// between entering the seat and returning: the `zomb` cell marks where he
  /// went in and `zback` where he came out, so the span between is already
  /// legible from its ends. (The lock-screen track draws that span explicitly;
  /// it has the width to spare and the leaderboard has the grid below it.)
  String _cell(int pid, int hole) {
    final h = _byHole[hole];
    if (h == null) return 'np';
    // The summary emits a row for EVERY hole in play, scored or not, so an
    // unplayed hole arrives with entries whose gross is null. Testing for the
    // row's existence marked all eighteen as played and hid the hatch.
    final entries = (h['entries'] as List? ?? const []);
    if (entries.isEmpty ||
        entries.any((e) => (e as Map)['gross'] == null)) {
      return 'np';
    }

    if (h['resurrected_id'] == pid) return 'zback';
    if (h['eliminated_id'] == pid) return zombieOn ? 'zomb' : 'knock';

    // Did a Survivor end on this hole, and did he take it?
    for (final sv in survivors) {
      if (sv['end_hole'] == hole && sv['winner_id'] == pid) return 'won';
    }

    // Is he out of this Survivor as of this hole?
    //
    // Walk EVERY earlier hole and let the last event win. Returning on the
    // first elimination made the resurrection check below it unreachable, so a
    // golfer who went to Zombieville and came back was drawn `gone` for the
    // rest of the Survivor — while the lock screen counted him among the
    // living. Two surfaces disagreeing about who is still in it.
    final svIdx = h['survivor'];
    var out = false;
    for (final e in holes) {
      if (e['survivor'] != svIdx) continue;
      final eh = e['hole'] as int? ?? 0;
      if (eh >= hole) break;
      if (e['eliminated_id'] == pid) out = true;
      if (e['resurrected_id'] == pid) out = false;
    }
    return out ? 'gone' : 'alive';
  }

  BoxDecoration _laneStyle(String cell) {
    switch (cell) {
      case 'won':
        return BoxDecoration(
          color: const Color(0xFFDFF0E2),
          border: Border.all(color: const Color(0xFF7CC48A)),
          borderRadius: BorderRadius.circular(3));
      case 'knock':
        return BoxDecoration(
          color: const Color(0xFFFADBDB),
          border: Border.all(color: const Color(0xFFE39494)),
          borderRadius: BorderRadius.circular(3));
      case 'zomb':
        return BoxDecoration(
          color: Color.alphaBlend(
              Halved.zombie.withValues(alpha: 0.20), Colors.white),
          border: Border.all(color: Halved.zombie),
          borderRadius: BorderRadius.circular(3));
      case 'zback':
        return BoxDecoration(
          color: Color.alphaBlend(
              Halved.zombie.withValues(alpha: 0.09), Colors.white),
          border: Border.all(
              color: Color.alphaBlend(
                  Halved.zombie.withValues(alpha: 0.45), Colors.white)),
          borderRadius: BorderRadius.circular(3));
      case 'np':
        // Handled by _HatchCell — a flat tint sits a shade off `alive` and at
        // 15px the two read as one cell, losing "not played yet" entirely.
        return const BoxDecoration();
      case 'gone':
        return BoxDecoration(borderRadius: BorderRadius.circular(3));
      default:
        return BoxDecoration(
          color: const Color(0xFFE4EDE6),
          borderRadius: BorderRadius.circular(3));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (holesInPlay.isEmpty || players.isEmpty) {
      return const SizedBox.shrink();
    }
    final muted = theme.colorScheme.onSurfaceVariant;

    // Who is in the seat now — his row label wears the plum.
    int? seatPid;
    for (final h in holes) {
      if (h['eliminated_id'] != null && zombieOn) seatPid = h['eliminated_id'];
      if (h['resurrected_id'] != null && h['resurrected_id'] == seatPid) {
        seatPid = null;
      }
    }

    final covered = survivors.fold<int>(
        0, (a, sv) => a + ((sv['holes'] as int? ?? 0)));
    final unplayed = (holesInPlay.length - covered).clamp(0, 18);

    Widget cellRow(List<Widget> cells) => Row(children: [
          SizedBox(width: _labelW),
          for (final c in cells) Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _gap / 2),
                  child: c)),
        ]);

    return LayoutBuilder(builder: (context, box) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Ruler ─────────────────────────────────────────────────────────
        // Above the bars, so one set of hole numbers serves both parts — which
        // is what makes the bar's length readable as a span of holes.
        cellRow([
          for (final h in holesInPlay)
            Text('$h',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9.5, fontWeight: FontWeight.w600, color: muted)),
        ]),
        const SizedBox(height: 3),

        // ── Winner bars ───────────────────────────────────────────────────
        // Spanning exactly the holes each Survivor covered, so the bar's
        // length is the answer to "how long did that one run".
        Row(children: [
          const SizedBox(width: _labelW),
          for (final sv in survivors)
            if ((sv['holes'] as int? ?? 0) > 0)
              Expanded(
                flex: (sv['holes'] as int),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _gap / 2),
                  child: _WinnerBar(sv: sv),
                ),
              ),
          // Holes no Survivor has reached yet. Without this the bars divide the
          // full width between themselves, so a Survivor covering two holes of
          // eighteen drew a bar spanning the card — and the bar's LENGTH is the
          // whole point of this row.
          if (unplayed > 0) Spacer(flex: unplayed),
        ]),
        const SizedBox(height: 4),

        // ── Survival lanes ────────────────────────────────────────────────
        for (final p in players) ...[
          Row(children: [
            SizedBox(
              width: _labelW,
              child: Text(
                  (p['short_name'] ?? p['name'] ?? '').toString(),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      // The man in the seat is named in plum.
                      color: p['player_id'] == seatPid
                          ? Halved.zombie
                          : theme.colorScheme.onSurface)),
            ),
            for (final h in holesInPlay)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _gap / 2),
                  child: Builder(builder: (_) {
                    final cell = _cell(p['player_id'] as int, h);
                    if (cell == 'np') return const _HatchCell();
                    return Container(
                        height: 15, decoration: _laneStyle(cell));
                  }),
                ),
              ),
          ]),
          const SizedBox(height: 2),
        ],

        const SizedBox(height: 6),
        _Legend(zombieOn: zombieOn),
      ]);
    });
  }
}

class _WinnerBar extends StatelessWidget {
  const _WinnerBar({required this.sv});
  final Map<String, dynamic> sv;

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final live   = (sv['outcome']?.toString() ?? 'live') == 'live';
    final winner = sv['winner_short']?.toString();
    final payout = (sv['payout'] as num?)?.toDouble() ?? 0;

    if (live) {
      // The Survivor still running is drawn, not omitted — it is the one that
      // can still cost somebody money.
      return Container(
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F1),
          border: Border.all(
              color: const Color(0xFFC3D0C6), style: BorderStyle.solid),
          borderRadius: BorderRadius.circular(6),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('IN PLAY',
              maxLines: 1,
              style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurfaceVariant)),
        ),
      );
    }
    return Container(
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFDFF0E2),
        border: Border.all(color: const Color(0xFF7CC48A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center,
                 mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text(winner ?? '—',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1B5E20))),
        ),
        if (payout > 0) ...[
          const SizedBox(width: 4),
          Text('\$${payout.toStringAsFixed(payout == payout.roundToDouble() ? 0 : 2)}',
              style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF388E3C).withValues(alpha: 0.85))),
        ],
      ]),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.zombieOn});
  final bool zombieOn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
        fontSize: 9.5, color: theme.colorScheme.onSurfaceVariant);
    return Wrap(spacing: 10, runSpacing: 2, children: [
      _swatch(const Color(0xFFDFF0E2), const Color(0xFF7CC48A), 'took it', style),
      if (!zombieOn)
        _swatch(const Color(0xFFFADBDB), const Color(0xFFE39494), 'out', style),
      if (zombieOn) ...[
        _swatch(Color.alphaBlend(Halved.zombie.withValues(alpha: 0.20),
                Colors.white), Halved.zombie, 'in Zombieville', style),
        _swatch(Color.alphaBlend(Halved.zombie.withValues(alpha: 0.09),
                Colors.white),
            Color.alphaBlend(Halved.zombie.withValues(alpha: 0.45),
                Colors.white), 'back in', style),
      ],
    ]);
  }

  Widget _swatch(Color fill, Color border, String label, TextStyle? style) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 10, height: 10,
            decoration: BoxDecoration(
                color: fill,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: style),
      ]);
}


/// A hole nobody has reached — drawn as diagonal hatching rather than a tint,
/// because the tint that reads as "not played" is a shade away from the one
/// that reads as "survived it", and at 15px tall they become the same cell.
class _HatchCell extends StatelessWidget {
  const _HatchCell();

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: CustomPaint(
          size: const Size(double.infinity, 15),
          painter: _HatchPainter(),
          child: const SizedBox(height: 15, width: double.infinity),
        ),
      );
}

class _HatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFFF4F7F4));
    final stripe = Paint()
      ..color = const Color(0xFFEAEFEB)
      ..strokeWidth = 3;
    for (double x = -size.height; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0),
          stripe);
    }
  }

  @override
  bool shouldRepaint(covariant _HatchPainter old) => false;
}
