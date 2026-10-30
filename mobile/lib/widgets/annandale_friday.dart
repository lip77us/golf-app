/// widgets/annandale_friday.dart
/// -----------------------------
/// Annandale Friday's pieces that more than one screen draws: the team
/// colours, the team header over a team's golfers in score entry, and the
/// dark tray that rises once a hole's last score is in.
///
/// One place for the colours because the setup screen, score entry and the
/// board all colour a golfer by his TEAM, and a team that is pine in setup
/// and clay on the board is two teams to the man reading it.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';

/// Team colours, in team order. With five, the three is team 2 — so every
/// opponent of the pair wears clay, which is what the packet draws.
const List<Color> kAnnandaleTeamColours = [
  Halved.teamPine, Halved.teamClay, Halved.teamSlate,
];

Color annandaleTeamColour(int? team) => team == null
    ? Halved.muted
    : kAnnandaleTeamColours[team % kAnnandaleTeamColours.length];

/// The same team on the dark tray, where the team colours themselves have
/// too little contrast against deep pine to read.
Color annandaleTeamTint(int? team) =>
    team == null ? Colors.white70 : Halved.golferTint(team);

/// "BILL & TOM" over a team's first golfer, in the team's colour.
class AnnandaleTeamHeader extends StatelessWidget {
  const AnnandaleTeamHeader(
      {super.key, required this.summary, required this.playerId});

  final AnnandaleFridaySummary summary;
  final int playerId;

  @override
  Widget build(BuildContext context) {
    final t = summary.teamOf(playerId);
    if (t == null) return const SizedBox.shrink();
    final names = summary.teams[t].map((p) => p.label).join(' & ');
    final colour = annandaleTeamColour(t);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
      child: Row(children: [
        Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
              color: colour, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(names.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800,
                  letterSpacing: 0.5, color: colour)),
        ),
      ]),
    );
  }
}

/// The dark tray: every Nassau's result on this hole and the bets after it,
/// any press starting on the next hole, and the skin.
///
/// Everything in it is READ from the summaries — who won the hole, by which
/// ball, the margins, the presses. The tray decides only what to show, so it
/// cannot disagree with the board the group will check it against.
class AnnandaleHoleTray extends StatelessWidget {
  const AnnandaleHoleTray({
    super.key,
    required this.summary,
    required this.hole,
    required this.nextHole,
    required this.playerCount,
    required this.onEdit,
    required this.onPress,
    this.skins,
  });

  final AnnandaleFridaySummary summary;
  final int hole;
  final int? nextHole;
  final int playerCount;
  final SkinsSummary? skins;
  final VoidCallback onEdit;
  final void Function(AnnandaleFridayMatch match, int startHole) onPress;

  static const _dim = Color(0xFFB9CCC3);

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final m in summary.matches)
        if (m.summary.holes.any((h) => h.hole == hole)) m,
    ];
    final first = rows.isEmpty
        ? null
        : rows.first.summary.holes.firstWhere((h) => h.hole == hole);
    final nine = first?.back9Margin != null ? 'back nine' : 'front nine';

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text('All $playerCount scores in',
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                  foregroundColor: Halved.brightMint,
                  minimumSize: const Size(44, 40)),
              child: const Text('Edit scores'),
            ),
          ]),
          Text('HOLE $hole · NASSAU · ${nine.toUpperCase()}',
              style: const TextStyle(
                  color: _dim, fontSize: 11, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5)),
          const SizedBox(height: 4),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Waiting for this hole to sync…',
                  style: TextStyle(color: _dim)),
            )
          else
            for (final m in rows) _matchRow(m),
          if (skins != null) ..._skinLine(),
        ],
      ),
    );
  }

  String _names(List<int> ids) {
    String name(int id) => summary.players
        .where((p) => p.playerId == id).map((p) => p.label).firstOrNull ?? '?';
    return ids.map(name).join(' & ');
  }

  /// "2 UP" in the leader's team tint, "AS" in white.
  Widget _status(String label, int margin, AnnandaleFridayMatch m) {
    final lead = margin > 0 ? m.side1Team : margin < 0 ? m.side2Team : null;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Text.rich(TextSpan(children: [
        TextSpan(text: '$label ',
            style: const TextStyle(color: _dim, fontSize: 12.5)),
        TextSpan(
            text: margin == 0 ? 'AS' : '${margin.abs()} UP',
            style: TextStyle(
                fontWeight: FontWeight.w800, fontSize: 12.5,
                color: margin == 0 ? Colors.white : annandaleTeamTint(lead))),
      ])),
    );
  }

  Widget _matchRow(AnnandaleFridayMatch m) {
    final s = m.summary;
    final h = s.holes.firstWhere((x) => x.hole == hole);
    final won = h.winner == 'team1' || h.winner == 'team2';
    final winnerTeam =
        h.winner == 'team1' ? m.side1Team : h.winner == 'team2' ? m.side2Team : null;
    // Why: the better balls, or the 2nd ball when they were level.
    final why = (h.t1Net != null && h.t1Net == h.t2Net &&
            h.t12ndNet != null && h.t22ndNet != null)
        ? '2nd ball ${h.t12ndNet} v ${h.t22ndNet}'
        : 'net ${h.t1Net ?? '–'} v ${h.t2Net ?? '–'}';
    final front = h.back9Margin == null;
    final nineMargin = front ? (h.front9Margin ?? 0) : (h.back9Margin ?? 0);
    final nineKey = front ? 'front' : 'back';
    final live = [
      for (final p in s.presses)
        if (p.nine == nineKey && p.startHole <= hole) p,
    ];
    final starting = [
      for (final p in s.presses)
        if (nextHole != null && p.startHole == nextHole) p,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: _names(m.side1Ids),
                    style: TextStyle(color: annandaleTeamTint(m.side1Team))),
                const TextSpan(text: '  v  ', style: TextStyle(color: _dim)),
                TextSpan(text: _names(m.side2Ids),
                    style: TextStyle(color: annandaleTeamTint(m.side2Team))),
              ]),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(won ? 'Won' : 'Halved',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: won ? annandaleTeamTint(winnerTeam) : Colors.white)),
            Text(why, style: const TextStyle(color: _dim, fontSize: 11)),
          ]),
        ]),
        const SizedBox(height: 3),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          _status(front ? 'Front' : 'Back', nineMargin, m),
          for (final (i, p) in live.indexed)
            _status('P${i + 1}', p.margin ?? 0, m),
          for (final p in starting)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                  '${p.pressType == 'manual' ? 'Manual press' : 'Press'} '
                  'starts ${p.startHole}',
                  style: const TextStyle(
                      color: Halved.brightMint, fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
            ),
          if (m.canPress && nextHole != null &&
              !starting.any((p) => p.pressType == 'manual'))
            TextButton(
              onPressed: () => onPress(m, nextHole!),
              style: TextButton.styleFrom(
                  foregroundColor: Halved.brightMint,
                  minimumSize: const Size(44, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('Press'),
            ),
        ]),
      ]),
    );
  }

  List<Widget> _skinLine() {
    final h = skins!.holes.where((x) => x.hole == hole).firstOrNull;
    if (h == null) return const [];
    final String text;
    if (h.winnerId != null) {
      final n = h.skinsValue;
      text = '${h.winnerShort ?? 'Skin'} wins $n skin${n == 1 ? '' : 's'}';
    } else if (h.isCarry) {
      text = 'Carried — ${h.skinsValue + 1} skins ride on the next hole';
    } else {
      text = 'No skin';
    }
    return [
      const Divider(color: Color(0x33FFFFFF), height: 14),
      Row(children: [
        const Text('SKINS  ', style: TextStyle(
            color: _dim, fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 0.5)),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w700)),
        ),
      ]),
    ];
  }
}
