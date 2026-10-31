/// widgets/sixes_entry.dart
/// ------------------------
/// The Sixes score-entry surfaces (`~/Downloads/handoff-sixes-score-entry`).
///
/// **These are widgets, not a screen.** Sixes plays through the shared
/// `score_entry_screen`, which is where the sync queue, the combo-tee chip,
/// Spots capture, mid-round withdrawal and the landscape scorecard live. A
/// dedicated screen is how a game loses all five — this repo has that lesson
/// written down three times, and the Annandale Friday build settled it:
/// "score entry is the SHARED screen, not a dedicated one".
///
/// So the packet's design is realised as the shared screen's Sixes mode: this
/// file holds the hole header, the side-grouped player card, the dark tray and
/// the band that replaces the keypad when a match has no sides yet.
///
/// Everything drawn here comes off `SixesHoleCard`, which the server builds
/// from the engine — the standing, the hole's winner, the close-out notation
/// and the next pairing are all its answers, not re-derived here. The
/// prototype computes them in the browser because it has no engine; we have
/// one, and two opinions about whether a match is 2 UP is how the tray and
/// the leaderboard come to disagree.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'dashed_border.dart';
import 'forty_balls_keypad.dart';
import 'stroke_dots.dart';

// ── Colour ───────────────────────────────────────────────────────────────────

/// Side A pine, side B clay — the packet's own pair.
///
/// Colour here means WHICH SIDE, and the sides are re-drawn every match, so a
/// golfer changes colour at the turn. That is correct and is the opposite of
/// the skins board, where colour is identity: there the question is "which of
/// these rows is me", and here it is "who am I playing with on this hole".
const Color kSixesSideA = Halved.pine;
const Color kSixesSideB = Color(0xFFB45309);

/// The same two on the dark tray, where the light pair would be mud.
/// Lifted from Annandale Friday's tray rather than re-picked: one dark green
/// and one dark clay across the app, or a reader learns the colour twice.
const Color kSixesSideADark = Color(0xFF3BD89A);
const Color kSixesSideBDark = Color(0xFFF2A86E);

Color sixesSideColour(int? side, {bool dark = false}) => side == 2
    ? (dark ? kSixesSideBDark : kSixesSideB)
    : (dark ? kSixesSideADark : kSixesSideA);

/// Labels and secondary text on the tray: NEUTRAL white, no hue — the note on
/// Annandale's `_dim` explains why a green-grey reads as one team's colour.
const Color _dim = Color(0x8CFFFFFF);

// ── 1 · the hole ─────────────────────────────────────────────────────────────

/// Hole number and par, the yardage, and where the match stands.
class SixesHoleHeader extends StatelessWidget {
  final SixesHoleCard card;

  const SixesHoleHeader({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final m = card.match;
    final leading = m.leadingSide;
    // `Teams?` is a question, not a standing, so it never takes a side's
    // colour — there is no side yet to claim it.
    final chipFill = !m.teamsSet
        ? Halved.surface
        : leading == null
            ? Halved.surface
            : sixesSideColour(leading);
    final chipText = !m.teamsSet || leading == null
        ? Halved.deepPine
        : Colors.white;

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Container(
          width: 64,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Halved.deepPine,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${card.hole}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    height: 1.1,
                    fontWeight: FontWeight.w700)),
            if (card.par != null)
              Text('Par ${card.par}',
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (card.yards != null)
                Text('${card.yards} yds',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Halved.deepPine)),
              Text(
                [
                  if (card.strokeIndex != null) 'SI ${card.strokeIndex}',
                  if (card.nine.isNotEmpty) card.nine,
                ].join(' · '),
                style: const TextStyle(fontSize: 13, color: Halved.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: chipFill,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                !m.teamsSet
                    ? 'Teams?'
                    : leading == null
                        ? 'AS'
                        : '${m.upBefore.abs()} UP',
                style: TextStyle(
                    color: chipText,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              !m.teamsSet
                  ? 'match ${m.number}'
                  : [
                      if (leading != null)
                        (leading == 1 ? m.team1.short : m.team2.short),
                      '${m.toPlay} to play',
                    ].join(' · '),
              style: const TextStyle(fontSize: 12, color: Halved.muted),
            ),
          ],
        ),
      ]),
    );
  }
}

// ── 2 · the golfers ──────────────────────────────────────────────────────────

/// The golfers, grouped by side for the live match.
///
/// Ungrouped — one plain section, no bars, boxes dimmed — while the match has
/// no sides. That is a real state rather than a loading one, so it says so.
class SixesPlayersCard extends StatelessWidget {
  final SixesHoleCard card;

  /// The golfer the keypad is pointed at, highlighted so a scorer can see
  /// whose number he is about to type.
  final int? activePlayerId;
  final ValueChanged<int>? onTapPlayer;

  /// Net Style Entry — passed in rather than read here, because the setting
  /// governs the whole app and this widget should not be a second place that
  /// decides what it means.
  final bool netStyle;

  const SixesPlayersCard({
    super.key,
    required this.card,
    required this.netStyle,
    this.activePlayerId,
    this.onTapPlayer,
  });

  @override
  Widget build(BuildContext context) {
    final grouped = card.match.teamsSet;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (!grouped) ...[
          _sectionHeader('Match ${card.match.number} · sides not set', null),
          for (final p in card.players) _row(p, null),
        ] else
          for (final side in [1, 2]) ...[
            _sectionHeader(
                side == 1 ? card.match.team1.short : card.match.team2.short,
                side),
            for (final p in card.side(side)) _row(p, side),
          ],
      ]),
    );
  }

  Widget _sectionHeader(String label, int? side) => Container(
        width: double.infinity,
        color: const Color(0xFFF6F8F6),
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        child: Row(children: [
          if (side != null) ...[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: sixesSideColour(side),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: Halved.muted)),
        ]),
      );

  Widget _row(SixesHolePlayer p, int? side) {
    final active = p.playerId == activePlayerId;
    return InkWell(
      onTap: onTapPlayer == null ? null : () => onTapPlayer!(p.playerId),
      child: Container(
        color: active ? const Color(0xFFE8F6EF) : null,
        child: IntrinsicHeight(
          child: Row(children: [
            // The 4pt inset bar repeats the side on every row, so a reader
            // scrolling past the section header still knows whose ball it is.
            Container(
              width: 4,
              margin: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: side == null
                    ? Colors.transparent
                    : sixesSideColour(side),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(children: [
                  Flexible(
                    child: Text(p.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Halved.deepPine)),
                  ),
                  const SizedBox(width: 6),
                  Text('CH ${p.courseHandicap}',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Halved.muted)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            _netChip(p),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: _scoreBox(p, side),
            ),
            const SizedBox(width: 12),
          ]),
        ),
      ),
    );
  }

  /// `net 4`, filling once the hole is complete and this is the side's
  /// counting ball — both of them when they tie, because the fill has to
  /// reconcile with the number beside it.
  Widget _netChip(SixesHolePlayer p) {
    final filled = p.isBest;
    return Container(
      width: 74,
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: BoxDecoration(
        color: filled ? Halved.pine : const Color(0xFFEDF1EE),
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: 'net ',
            style: TextStyle(
                fontSize: 13,
                color: filled ? Colors.white70 : Halved.muted),
          ),
          TextSpan(
            text: p.net?.toString() ?? '–',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: filled ? Colors.white : Halved.deepPine),
          ),
        ]),
      ),
    );
  }

  Widget _scoreBox(SixesHolePlayer p, int? side) {
    const w = 52.0, h = 52.0;
    final empty = p.gross == null;
    final body = empty
        ? Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: Halved.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: side == null
                    ? Halved.cardBorder
                    : (p.playerId == activePlayerId
                        ? Halved.deepPine
                        : Halved.cardBorder),
                width: p.playerId == activePlayerId ? 2 : 1.2,
              ),
            ),
          )
        : ScoreNotation(
            score: p.gross!,
            par: card.par ?? 4,
            strokes: netStyle ? p.strokes : 0,
            width: w,
            height: h,
            fontSize: 22,
          );

    return Opacity(
      opacity: side == null ? 0.4 : 1,
      child: SizedBox(
        width: w,
        height: h,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            body,
            StrokeDotCap(strokes: p.strokes),
          ],
        ),
      ),
    );
  }
}

// ── 3 · the tray ─────────────────────────────────────────────────────────────

/// What the hole did, once every score is in.
class SixesHoleTray extends StatelessWidget {
  final SixesHoleCard card;
  final VoidCallback onEdit;

  /// Offered when the NEXT match has no sides: the group chooses here rather
  /// than having the reel appear over this tray by itself.
  final VoidCallback? onSetTeams;

  /// **The tray carries the pager, and COVERS the screen's own.**
  ///
  /// This went the other way first — the tray drew no arrows, on Annandale's
  /// precedent that a tray "does not grow a second pager" — and a phone then
  /// showed two sets at the bottom. Paul, reading the design again (30 Oct
  /// 2026): *"the black match status box overlays the forward back arrows …
  /// the status box should always have those controls."* So the duplication
  /// is fixed from the other end: while this tray is up it IS the bottom
  /// bar, and score entry hides its pager underneath.
  ///
  /// That is what lets the forward button say `Match 3 · hole 11 ›` — the
  /// thing that changes at 11 is who you are playing with, which a generic
  /// pager has no way to know.
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final int? nextHole;

  /// The result is on its way — what we hold for this hole predates the score
  /// just entered, so it is not drawn. Annandale's tray learnt this: showing
  /// a stale result after an edit is worse than showing none.
  final bool gettingResult;

  /// Saved on the phone, not yet at the server.
  final bool notSynced;

  const SixesHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    required this.nextHole,
    this.onPrev,
    this.onNext,
    this.onSetTeams,
    this.gettingResult = false,
    this.notSynced = false,
  });

  @override
  Widget build(BuildContext context) {
    final r = (gettingResult || notSynced) ? null : card.result;
    final stake = card.betUnit;

    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Text('All ${card.players.length} scores in',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: onEdit,
              style: TextButton.styleFrom(
                  foregroundColor: Halved.brightMint,
                  minimumSize: const Size(44, 40)),
              child: const Text('Edit scores'),
            ),
          ]),
          _labelRow(
            'HOLE ${card.hole} · MATCH ${card.match.number}',
            stake == null ? '' : '\$${_money(stake)} A MATCH',
          ),
          const SizedBox(height: 6),
          if (r == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                gettingResult
                    ? 'Getting result…'
                    : 'Saved. The result shows once this hole syncs.',
                style: const TextStyle(color: _dim),
              ),
            )
          else
            _matchCard(r),
          if (r != null && r.closed && card.nextMatch != null) ...[
            const SizedBox(height: 8),
            _labelRow('NEXT', 'PARTNERS CHANGE'),
            const SizedBox(height: 4),
            _nextCard(card.nextMatch!),
          ],
          const SizedBox(height: 12),
          _buttons(r),
        ],
      ),
    );
  }

  static String _money(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Widget _labelRow(String left, String right) => Row(children: [
        Text(left,
            style: const TextStyle(
                color: _dim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
        const Spacer(),
        Text(right,
            style: const TextStyle(
                color: _dim,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      ]);

  Widget _matchCard(SixesHoleOutcome r) {
    final won = r.winningSide;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF14312A),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: card.match.team1.short,
                      style: const TextStyle(
                          color: kSixesSideADark,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  const TextSpan(
                      text: '  v  ',
                      style: TextStyle(color: _dim, fontSize: 13)),
                  TextSpan(
                      text: card.match.team2.short,
                      style: const TextStyle(
                          color: kSixesSideBDark,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                ]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // Flexible, so a long pair and a long chip degrade instead of
            // overflowing: the chip's own nets ellipsise before the words
            // that say what happened do.
            Flexible(child: _resultChip(r, won)),
          ]),
          const SizedBox(height: 6),
          _standingLine(r),
        ],
      ),
    );
  }

  /// "Won hole 10 · net 4 v 5", in the winning side's colour.
  ///
  /// Worded `Won hole` rather than a bare margin so it is not read as the
  /// match standing, which is the line directly underneath it.
  Widget _resultChip(SixesHoleOutcome r, int? won) {
    final fill = won == null
        ? const Color(0x33FFFFFF)
        : sixesSideColour(won, dark: true);
    final ink = won == null ? Colors.white : Halved.deepPine;
    final nets = (r.t1Net == null || r.t2Net == null)
        ? ''
        : 'net ${r.t1Net} v ${r.t2Net}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: Text(
              won == null
                  ? 'Hole ${card.hole} halved'
                  : 'Won hole ${card.hole}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: ink, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
        if (nets.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(nets,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: ink.withValues(alpha: 0.75), fontSize: 11)),
          ),
        ],
      ]),
    );
  }

  Widget _standingLine(SixesHoleOutcome r) {
    final lead = r.leadingSide;
    final leadName =
        lead == 1 ? card.match.team1.short : card.match.team2.short;
    final colour =
        lead == null ? Colors.white : sixesSideColour(lead, dark: true);

    final String head;
    final String tail;
    if (r.closed && lead != null) {
      head = '$leadName win ${r.marginText}';
      tail = ' · match ${card.match.number} over'
          '${card.betUnit == null ? '' : ' · \$${_money(card.betUnit!)} each'}';
    } else if (lead == null) {
      head = 'AS';
      tail = ' · ${r.leftAfter} to play';
    } else {
      head = '$leadName ${r.upAfter.abs()} UP';
      tail = ' · ${r.leftAfter} to play';
    }

    return Text.rich(
      TextSpan(children: [
        TextSpan(
            text: head,
            style: TextStyle(
                color: colour, fontWeight: FontWeight.w700, fontSize: 14)),
        TextSpan(
            text: tail,
            style: const TextStyle(color: _dim, fontSize: 13)),
      ]),
    );
  }

  Widget _nextCard(SixesNextMatch n) {
    final sides = n.teamsSet
        ? '${n.team1.short} v ${n.team2.short}'
        : 'sides not set';
    return CustomPaint(
      painter: const DashedRRect(color: Color(0x4DFFFFFF), width: 1),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Match ${n.number}'
              '${n.startHole == null ? '' : ' from ${n.startHole}'} · $sides',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14),
            ),
            const SizedBox(height: 2),
            Text(
              n.teamsSet
                  ? 'Partners change for the next match.'
                  : 'Set the sides before entering scores.',
              style: const TextStyle(color: _dim, fontSize: 12),
            ),
            if (!n.teamsSet && onSetTeams != null) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: OutlinedButton(
                      onPressed: onSetTeams,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0x66FFFFFF)),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                      ),
                      child: const Text('Pick the teams',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: FilledButton(
                      onPressed: onSetTeams,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Halved.deepPine,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                      ),
                      child: const Text('Spin for partners',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }


  Widget _buttons(SixesHoleOutcome? r) {
    final closed = r != null && r.closed && card.nextMatch != null;
    // `Complete Round`, the same words the pager uses — this button is what
    // replaces it on the last hole.
    final label = nextHole == null
        ? 'Complete Round'
        : closed
            ? 'Match ${card.nextMatch!.number} · hole $nextHole ›'
            : 'Hole $nextHole ›';
    return Row(children: [
      SizedBox(
        width: 48,
        height: 48,
        child: OutlinedButton(
          onPressed: onPrev,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            side: const BorderSide(color: Color(0x4DFFFFFF)),
            foregroundColor: Colors.white,
          ),
          child: const Text('‹', style: TextStyle(fontSize: 20)),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: SizedBox(
          height: 48,
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Halved.deepPine,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ── 4 · teams not set ────────────────────────────────────────────────────────

/// The band that takes the keypad's place when the next match has no sides.
///
/// It replaces the keypad rather than sitting above it, because the point is
/// that nothing can be entered yet — a keypad underneath an explanation of why
/// you cannot use it is an invitation to try.
class SixesTeamsBand extends StatelessWidget {
  final SixesHoleCard card;

  /// Both open the existing Sixes draw sheet; the difference is whether it
  /// lands on the reel or on the two legal pairings.
  final VoidCallback onPick;
  final VoidCallback onSpin;

  /// Back to the previous hole, so a wrong score can be fixed BEFORE partners
  /// are drawn — if the fix reopens the match, this band goes away by itself.
  final VoidCallback? onBack;
  final int? backHole;

  const SixesTeamsBand({
    super.key,
    required this.card,
    required this.onPick,
    required this.onSpin,
    this.onBack,
    this.backHole,
  });

  @override
  Widget build(BuildContext context) {
    final prev = card.previousMatch;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (prev != null && prev.result != null)
            Row(children: [
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: 'Match ${prev.number} · ',
                        style: const TextStyle(color: Colors.white)),
                    TextSpan(
                        text: prev.result!,
                        style: const TextStyle(
                            color: Halved.brightMint,
                            fontWeight: FontWeight.w700)),
                  ]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (prev.startHole != null && prev.endHole != null)
                Text('holes ${prev.startHole}–${prev.endHole}',
                    style: const TextStyle(color: _dim, fontSize: 13)),
            ]),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.lock_outline,
                  size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Set teams for Match ${card.match.number} before entering '
                'scores.',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.25,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            [
              // Match 3 is forced by the other two and never asks, so this
              // only ever describes match 2 — or an extra, where the four are
              // free to pair any way they like.
              if (card.match.isExtra)
                'Pick the sides for the extra, or spin for them.'
              else
                'Two pairings are left. Spin for match ${card.match.number}, '
                    'or set the teams yourself.',
              if (backHole != null)
                '‹ goes back to hole $backHole to fix a score first.',
            ].join(' '),
            style: const TextStyle(color: _dim, fontSize: 13, height: 1.35),
          ),
          const SizedBox(height: 14),
          Row(children: [
            SizedBox(
              width: 48,
              height: 48,
              child: OutlinedButton(
                onPressed: onBack,
                style: OutlinedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                  side: const BorderSide(color: Color(0x4DFFFFFF)),
                  foregroundColor: Colors.white,
                ),
                child: const Text('‹', style: TextStyle(fontSize: 20)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed: onPick,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0x66FFFFFF)),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Text('Pick the teams',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: onSpin,
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Halved.deepPine,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Text('Spin for partners',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
