/// widgets/swat_entry.dart
/// -----------------------
/// Oakmont SWAT score entry (docs/design-review/handoff-oakmont-swat, shots
/// 05–09): the phantom card between the hole card and the golfers, and the dark
/// tray — best ball, the hole against the field, money to date.
///
/// Everything here renders the server's `swat_hole` card. The phantom is only
/// ever a SCORE: no name, no order, and not even that until the team's own
/// golfers have entered the hole.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import 'tray_frame.dart';

class SwatHoleCard {
  final Map<String, dynamic> raw;
  SwatHoleCard(this.raw);

  factory SwatHoleCard.fromJson(Map<String, dynamic> j) => SwatHoleCard(j);

  Map<String, dynamic> get _team => (raw['team'] as Map).cast();
  bool get three => _team['three'] == true;
  String get teamName => '${_team['name']}';
  int get size => _team['size'] as int? ?? 4;
  Map<String, dynamic>? get phantom =>
      raw['phantom'] == null ? null : (raw['phantom'] as Map).cast();
  bool get complete => raw['complete'] == true;
  bool get waiting => raw['waiting'] == true;
  int? get best => raw['best'] as int?;
  String? get waitingNote => raw['waiting_note'] as String?;
  List<Map> get balls =>
      [for (final b in (raw['balls'] as List? ?? const [])) b as Map];
  Map<String, dynamic> get versus => (raw['versus'] as Map).cast();
  Map<String, dynamic> get money => (raw['money'] as Map).cast();
  String get ordinal => '${raw['ordinal']}';
}

String _usd(num v, {bool sign = true}) {
  final a = v.abs();
  final s = a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
  if (!sign || v == 0) return '\$$s';
  return v > 0 ? '+\$$s' : '−\$$s';
}

/// The card between the hole card and the golfers — threesomes only.
class SwatPhantomCard extends StatelessWidget {
  final SwatHoleCard card;
  const SwatPhantomCard({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final p = card.phantom;
    if (p == null) return const SizedBox.shrink();
    final state = p['state'];
    final score = p['score'];
    final String right = state == 'open'
        ? '$score'
        : state == 'later'
            ? 'Later'
            : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Halved.cardBorder, style: BorderStyle.solid),
      ),
      child: Row(children: [
        Icon(state == 'locked' ? Icons.lock_outline : Icons.visibility_outlined,
            size: 18, color: Halved.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Phantom',
                style: TextStyle(fontWeight: FontWeight.w700)),
            Text(
              state == 'locked'
                  ? 'A bottom golfer from another team, drawn for this hole. '
                      'It shows once your three have entered the hole.'
                  : state == 'later'
                      ? 'The drawn golfer has not played this hole yet. It '
                          'settles itself when the score arrives.'
                      : 'A bottom golfer from another team, drawn for this hole.',
              style: Halved.body(color: Halved.muted).copyWith(fontSize: 12),
            ),
          ]),
        ),
        if (right.isNotEmpty)
          Text(right,
              style: const TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 20)),
      ]),
    );
  }
}

/// The dark tray, on the shared frame.
class SwatHoleTray extends StatelessWidget {
  final SwatHoleCard card;
  final int hole;
  final bool picking;
  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final String nextLabel;
  final VoidCallback? onLeaderboard;

  const SwatHoleTray({
    super.key,
    required this.card,
    required this.hole,
    required this.onEdit,
    required this.nextLabel,
    this.picking = false,
    this.onPrev,
    this.onNext,
    this.onLeaderboard,
  });

  static const Color _muted = Color(0xFFB9CCC3);

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t.toUpperCase(),
            style: Halved.label(color: _muted, weight: FontWeight.w700)
                .copyWith(fontSize: 10.5, letterSpacing: 0.4)),
      );

  @override
  Widget build(BuildContext context) {
    final v = card.versus;
    final m = card.money;
    final waiting = card.waiting;
    final ov = (m['overall'] as Map).cast<String, dynamic>();
    final stillTo = (v['to_play'] as List? ?? const []).cast<String>();
    return TrayFrame(
      label: 'Hole $hole · SWAT',
      picking: picking,
      onEdit: onEdit,
      onPrev: onPrev,
      onNext: onNext,
      nextLabel: nextLabel,
      blocks: [
        // 1 · Best ball
        TrayBlock(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _head('Best ball · ${card.teamName}'),
            if (card.balls.isEmpty)
              const Text('Waiting for the scores',
                  style: TextStyle(color: Colors.white70))
            else
              for (final b in card.balls)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(
                        child: Text('${b['label']}',
                            style: TextStyle(
                                color: b['counts'] == true
                                    ? Colors.white
                                    : Colors.white70,
                                fontWeight: b['counts'] == true
                                    ? FontWeight.w700
                                    : FontWeight.w400))),
                    if (b['counts'] == true)
                      Text(b['tied'] == true ? 'Counts · tied ' : 'Counts ',
                          style: const TextStyle(
                              color: Halved.brightMint, fontSize: 12)),
                    Text('${b['gross']}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 16)),
                  ]),
                ),
            if (waiting) ...[
              const SizedBox(height: 4),
              Text(
                  card.best == null && card.waitingNote != null
                      ? card.waitingNote!
                      : 'Best ball 4? — waiting on the phantom. '
                          '${card.waitingNote ?? ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ]),
        ),
        // 2 · The Nth against N teams
        TrayBlock(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _head('The ${card.ordinal} against ${v['teams']} teams'),
            Row(children: [
              for (final e in [
                ('Won', waiting ? '–' : '${v['won']}'),
                ('Lost', waiting ? '–' : '${v['lost']}'),
                ('Halved', waiting ? '–' : '${v['halved']}'),
                ('To play', '${v['still_to_play']}'),
              ])
                Expanded(
                  child: Column(children: [
                    Text(e.$2,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 20)),
                    Text(e.$1,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 11)),
                  ]),
                ),
            ]),
            if (waiting)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Waiting on the phantom',
                    style: TextStyle(color: Colors.white70, fontSize: 12)),
              )
            else if (stillTo.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Still to play it: ${stillTo.join(', ')}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ),
          ]),
        ),
        // 3 · Money to date
        TrayBlock(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _head('Money to date · settled bets'),
            Row(children: [
              Text(_usd(m['team'] as num),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 22)),
              const SizedBox(width: 8),
              Text('team', style: Halved.body(color: _muted)),
              const Spacer(),
              Text(_usd(m['each'] as num),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 22)),
              const SizedBox(width: 6),
              Text('each', style: Halved.body(color: _muted)),
            ]),
            Text('${m['split']}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
                'Bets won ${m['won']}, lost ${m['lost']}, pushed ${m['pushed']}'
                ' · ${m['open']} still open',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            Text(
                'Overall: up on ${ov['up']} teams, level with ${ov['level']}, '
                'down to ${ov['down']}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            if (onLeaderboard != null)
              GestureDetector(
                onTap: onLeaderboard,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      'All ${(v['teams'] as int) * ((v['teams'] as int) + 1) ~/ 2}'
                      ' matches on the leaderboard ›',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                          decorationColor: Colors.white)),
                ),
              ),
          ]),
        ),
      ],
    );
  }
}
