import 'package:flutter/material.dart';

import '../api/models.dart';
import '../theme/halved_brand.dart';
import 'side_colour.dart';
import 'tray_edit_header.dart';
import 'tray_label.dart';

// Nassau score entry — `~/Downloads/handoff-nassau-score-entry`, Claremont
// included. 2 v 2 or 1 v 1, Front / Back / Overall, and the presses.
//
// **Nothing here is a rule.** The press rules are the sharpest thing in the
// app — a press starts at 2 down on the LATEST bet in a nine (4 down on a
// Claremont bottom bet, which is two points a hole), runs to the end of that
// nine, and closes out against its own holes left — so every chip arrives
// composed on `NassauHoleCard`, every figure is the engine's, and the Press
// button is offered on the engine's own `can_press` rather than on a rule
// re-derived here.
//
// The side header over each pair is Fourball's `FourballSideHeader`: a
// Nassau side is the same object with the same best ball, and two headers
// meaning one thing is how they come to look different.

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// The dark tray: the hole, every bet in play, and what it is worth.
///
/// **It IS the bottom bar while it is up**, like Points', Sixes', Wolf's,
/// Rabbit's, Las Vegas' and Fourball's: the screen's pager hides underneath,
/// so the arrows here are the only ones on screen.
class NassauHoleTray extends StatelessWidget {
  final NassauHoleCard card;

  final VoidCallback onEdit;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  /// Call a manual press on that game, starting next hole. Null when the
  /// engine does not offer one — which is the only thing that decides it.
  ///
  /// **The side is a whole bet, not a flavour.** Claremont is two games at
  /// once and each presses itself, on its own band: the top at 1 down (it
  /// autos at 2) and the bottom at 1–3 points down (it autos at 4).
  final void Function(String side)? onPress;

  final bool gettingResult;
  final bool notSynced;
  final bool picking;
  final bool pressing;

  const NassauHoleTray({
    super.key,
    required this.card,
    required this.onEdit,
    this.onPrev,
    this.onNext,
    this.onPress,
    this.gettingResult = false,
    this.notSynced = false,
    this.picking = false,
    this.pressing = false,
  });

  @override
  Widget build(BuildContext context) {
    final hold = gettingResult || notSynced;
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Halved.deepPine,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrayEditHeader(
            title: gettingResult ? 'Getting result…' : _title(),
            onEdit: onEdit,
            picking: picking,
          ),
          // **Bounded, and scrollable inside.** A Claremont card is two
          // games, a balls grid and six bet lines — around 550pt, which on
          // a small phone would push the buttons below it off the screen,
          // and those buttons are the ONLY pager while this tray is up.
          if (!hold)
            ConstrainedBox(
              // **Bounded, and scrollable inside.** The cap leaves the
              // header above and the buttons below on screen — those
              // buttons are the ONLY pager while this tray is up — and
              // gives the content everything else. Two four-row blocks
              // plus a result line runs past a short phone whatever the
              // number is, so the tail scrolls.
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    TrayLabel(
                      card.roundOver
                          ? 'Round over'
                          : 'Hole ${card.hole} · ${card.title}',
                      // **No trailing label.** It read `FRONT NINE` /
                      // `BACK NINE`, or `HOLES 1–18` on a Nassau Nine — wrong
                      // for a nine that wraps the turn, and sitting right
                      // over the hole's result as if it described it. The
                      // chips below say which bet the hole is in.
                    ),
                    const SizedBox(height: 6),
                    _MatchCard(
                        card: card, onPress: onPress, pressing: pressing),
                    if (card.money.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      _Money(card: card),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          _Buttons(card: card, onPrev: onPrev, onNext: onNext),
        ],
      ),
    );
  }

  /// Two golfers read `Both scores in`, because `All 2 scores in` is not a
  /// sentence.
  String _title() {
    final n = card.players.length;
    if (card.scored < n) return '${card.scored} of $n scored';
    return n == 2 ? 'Both scores in' : 'All $n scores in';
  }
}

/// Who won the hole, and every bet it moved.
class _MatchCard extends StatelessWidget {
  final NassauHoleCard card;
  final void Function(String side)? onPress;
  final bool pressing;
  const _MatchCard({required this.card, this.onPress, this.pressing = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Header(card: card),
        if (card.claremont) ...[
          const SizedBox(height: 10),
          const _SubHead('TOP', 'low v low · 1 pt · press at 2 down'),
        ],
        for (final l in card.lines)
          _Line(line: l, card: card, side: 'top',
                canPress: card.canPress,
                onPress: onPress, pressing: pressing),
        if (card.bottom != null) ...[
          const SizedBox(height: 10),
          const _SubHead('BOTTOM', 'low + high · 2 pts · press at 4 down'),
          const SizedBox(height: 4),
          _Balls(bottom: card.bottom!),
          const SizedBox(height: 2),
          for (final l in card.bottom!.lines)
            _Line(line: l, card: card, side: 'bottom',
                  canPress: card.canPressBottom,
                  onPress: onPress, pressing: pressing),
        ],
      ]),
    );
  }
}

/// `Paul + Dave v Sam + Mike   net 5 v 4  [Won]` — one row.
///
/// **The names, then why, then the result** (Paul, 10 Nov 2026: *"putting
/// net 5 v 4 and the Won badge on the same row as the names … with net 5 v 4
/// first"*). It was three sizes of type across two lines; short names made
/// the room to say it on one, and the eye now runs left to right through
/// who, the two figures, and the verdict.
///
/// **The names are what yield.** They are flexible with an ellipsis each,
/// and the reason and the badge take their natural width: a long pairing
/// loses a letter before the result loses a digit, because the result is
/// what the tray exists to say.
class _Header extends StatelessWidget {
  final NassauHoleCard card;
  const _Header({required this.card});

  @override
  Widget build(BuildContext context) {
    final s1 = card.sides.isNotEmpty ? card.sides[0] : null;
    final s2 = card.sides.length > 1 ? card.sides[1] : null;
    final winner = card.winner;
    final leader = winner == 'team1' ? 1 : (winner == 'team2' ? 2 : null);
    return LayoutBuilder(builder: (context, box) =>
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      // **Each name yields on its own.** One `Text.rich` ellipsises from
      // the right, which takes the SECOND side away entirely — and that is
      // the one the reader cannot name from anywhere else on this card.
      // **Loose, not `Expanded`**: the result follows the names directly
      // instead of being pushed to the right edge. Right-justified it sat
      // under the tray's `HOLES 1–18` label on a large phone and read as
      // belonging to that, when it is about the hole just played (Paul,
      // 10 Nov 2026).
      Flexible(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (s1 != null)
            Flexible(
              child: Text(s1.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: sideColour(1, onDark: true),
                      fontSize: 14, fontWeight: FontWeight.w700)),
            ),
          // The `v` rides INSIDE the second name's run, so nothing in
          // this row is rigid: with the result sharing the line the names
          // can be squeezed hard, and a fixed `v` between two flexible
          // names is the one piece that would overflow.
          if (s2 != null)
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(
                      text: ' v ',
                      style: TextStyle(color: _trayMuted, fontSize: 12)),
                  TextSpan(text: s2.label),
                ]),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: sideColour(2, onDark: true),
                    fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
        ]),
      ),
      if (winner != null) ...[
        const SizedBox(width: 12),
        // **At most two thirds of the row, and it scales rather than
        // spills.** On a phone it fits at full size with room to spare; the
        // cap is for a narrow screen or large type, where the names would
        // otherwise be squeezed to nothing and then the row would overflow.
        // Names give way first, and only then does the result get smaller.
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box.maxWidth * 0.66),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _Reason(card: card),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: leader == null
                      ? Colors.white.withValues(alpha: 0.14)
                      : sideColour(leader, onDark: true),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(leader == null ? 'Halved' : 'Won',
                    style: TextStyle(
                        color:
                            leader == null ? Colors.white : Halved.deepPine,
                        fontSize: 14, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ),
      ],
    ]));
  }
}

/// `net 5 v 5`, each figure in its own side's colour.
///
/// The words stay muted so the two numbers are what is read; an older
/// server sends no parts, and then the sentence draws flat as it always did
/// — bigger, but uncoloured, rather than this guessing which digit is whose.
class _Reason extends StatelessWidget {
  final NassauHoleCard card;
  const _Reason({required this.card});

  static const _words = TextStyle(
      color: _secondary, fontSize: 14, fontWeight: FontWeight.w600);

  @override
  Widget build(BuildContext context) {
    if (!card.hasReasonParts) {
      if (card.reason.isEmpty) return const SizedBox.shrink();
      return Text(card.reason,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: _words);
    }
    TextSpan figure(int v, int side) => TextSpan(
        text: '$v',
        style: TextStyle(
            color: sideColour(side, onDark: true),
            fontSize: 16, fontWeight: FontWeight.w800));
    return Text.rich(
      TextSpan(style: _words, children: [
        TextSpan(text: '${card.reasonLabel} '),
        figure(card.reasonTeam1!, 1),
        const TextSpan(text: ' v '),
        figure(card.reasonTeam2!, 2),
      ]),
      maxLines: 1, overflow: TextOverflow.ellipsis,
    );
  }
}

class _SubHead extends StatelessWidget {
  final String title;
  final String note;
  const _SubHead(this.title, this.note);

  @override
  Widget build(BuildContext context) => Row(children: [
        Text(title,
            style: const TextStyle(
                color: Colors.white, fontSize: 10.5, letterSpacing: 1.0,
                fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(note,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _trayMuted, fontSize: 10.5,
                  fontWeight: FontWeight.w600)),
        ),
      ]);
}

/// One nine: its label, its bet, and every press riding on it.
class _Line extends StatelessWidget {
  final NassauBetLine line;
  final NassauHoleCard card;

  /// Which of Claremont's two games this block is — `top` on a plain
  /// Nassau, where there is only one.
  final String side;
  final bool canPress;
  final void Function(String side)? onPress;
  final bool pressing;
  const _Line({required this.line, required this.card, required this.side,
               required this.canPress, this.onPress, this.pressing = false});

  @override
  Widget build(BuildContext context) {
    // **The Press button sits at the end of its own block's LAST line** —
    // `OVERALL` on a Nassau, the one `MATCH` line on a Nassau Nine; the
    // server names it (`pressLine`) —
    // which is the design's placement and reads as the end of that list
    // rather than as part of any one nine. On Claremont there are two
    // buttons, one a game, because the two press at different bands — and
    // which nine either joins is the engine's answer, not this widget's.
    final showPress =
        onPress != null && line.key == card.pressLine && canPress;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      // **Top-aligned.** A nine with a press can wrap to two chip rows, and
      // a centred label then floats between them rather than naming the
      // first one.
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SizedBox(
          width: 52,
          child: Text(line.label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: _trayMuted, fontSize: 9.5, letterSpacing: 0.8,
                  fontWeight: FontWeight.w700)),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 5, runSpacing: 5,
            children: [for (final c in line.chips) _Chip(chip: c)],
          ),
        ),
        if (showPress) ...[
          const SizedBox(width: 6),
          _PressButton(onPress: () => onPress!(side), busy: pressing),
        ],
      ]),
    );
  }
}

/// A bet, a press, or one that has not started.
///
/// The three states are the design's: a live bet is outlined, a press that
/// has been called but has not reached its first hole is DASHED (it is a
/// promise, not a bet), and a finished bet is filled and un-outlined because
/// nothing more can happen to it.
class _Chip extends StatelessWidget {
  final NassauChip chip;
  const _Chip({required this.chip});

  @override
  Widget build(BuildContext context) {
    final colour = chip.leader == null
        ? Colors.white
        : sideColour(chip.leader!, onDark: true);
    final box = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: chip.isFinal ? Colors.white.withValues(alpha: 0.10) : null,
        borderRadius: BorderRadius.circular(999),
        border: chip.isFinal
            ? null
            : Border.all(
                color: Colors.white.withValues(
                    alpha: chip.isPending ? 0.22 : 0.30)),
      ),
      child: Text(chip.text,
          style: TextStyle(
              color: chip.isPending ? _secondary : colour,
              fontSize: 11.5,
              fontStyle: chip.isPending ? FontStyle.italic : FontStyle.normal,
              fontWeight: FontWeight.w700)),
    );
    return chip.isPending ? Opacity(opacity: 0.85, child: box) : box;
  }
}

class _PressButton extends StatelessWidget {
  final VoidCallback onPress;
  final bool busy;
  const _PressButton({required this.onPress, required this.busy});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 30,
        child: FilledButton(
          onPressed: busy ? null : onPress,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Halved.deepPine,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: const Size(60, 30),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999)),
          ),
          child: busy
              ? const SizedBox(
                  width: 13, height: 13,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Halved.deepPine))
              : const Text('Press',
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w800)),
        ),
      );
}

/// Claremont's balls grid: LOW, HIGH and what the hole paid.
///
/// The ball a side WON is bold in its own colour; a lost or halved ball is
/// muted, because the bottom game pays for each ball separately and a reader
/// has to be able to see which of the two moved.
class _Balls extends StatelessWidget {
  final NassauBottomGame bottom;
  const _Balls({required this.bottom});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      const Row(children: [
        Expanded(child: SizedBox()),
        SizedBox(width: 44, child: Text('LOW', textAlign: TextAlign.center,
            style: TextStyle(color: _trayMuted, fontSize: 9,
                letterSpacing: 0.6, fontWeight: FontWeight.w700))),
        SizedBox(width: 44, child: Text('HIGH', textAlign: TextAlign.center,
            style: TextStyle(color: _trayMuted, fontSize: 9,
                letterSpacing: 0.6, fontWeight: FontWeight.w700))),
        SizedBox(width: 38, child: Text('HOLE', textAlign: TextAlign.right,
            style: TextStyle(color: _trayMuted, fontSize: 9,
                letterSpacing: 0.6, fontWeight: FontWeight.w700))),
      ]),
      for (final b in bottom.balls) _row(b),
    ]);
  }

  Widget _row(NassauBalls b) {
    final colour = sideColour(b.side, onDark: true);
    final pts = bottom.points;
    // The points are reported from side 1's point of view, so only the side
    // they went to shows a figure.
    final mine = pts == null
        ? null
        : (b.side == 1 ? pts : -pts);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        Container(
          width: 9, height: 9,
          decoration: BoxDecoration(
              color: colour, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(b.label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12.5,
                  fontWeight: FontWeight.w600)),
        ),
        _ball(b.low, b.lowWon, colour),
        _ball(b.high, b.highWon, colour),
        SizedBox(
          width: 38,
          child: Text(
            mine == null || mine <= 0 ? '0' : '+$mine',
            textAlign: TextAlign.right,
            style: TextStyle(
                color: mine != null && mine > 0 ? colour : _trayMuted,
                fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
      ]),
    );
  }

  Widget _ball(int? v, bool won, Color colour) => SizedBox(
        width: 44,
        child: Text(v?.toString() ?? '–',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: won ? colour : _trayMuted,
                fontSize: won ? 16 : 14,
                fontWeight: won ? FontWeight.w800 : FontWeight.w600)),
      );
}

/// `EACH · NOW` / `FINAL, EACH` — two rows, the leading side first, and on
/// Claremont the note that splits the figure into its two games.
class _Money extends StatelessWidget {
  final NassauHoleCard card;
  const _Money({required this.card});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 3, 13, 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 24,
          child: Row(children: [
            Expanded(
              child: Text(card.roundOver ? 'FINAL, EACH' : 'EACH · NOW',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: _secondary, fontSize: 10.5,
                      letterSpacing: 0.4, fontWeight: FontWeight.w700)),
            ),
            const Text('MONEY',
                style: TextStyle(
                    color: _secondary, fontSize: 10.5,
                    letterSpacing: 0.4, fontWeight: FontWeight.w700)),
          ]),
        ),
        for (final m in card.money) _row(m),
        if (card.moneyNote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(card.moneyNote,
                maxLines: 2,
                style: const TextStyle(color: _secondary, fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
      ]),
    );
  }

  Widget _row(FourballMoneyRow m) {
    final colour = sideColour(m.side, onDark: true);
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Row(children: [
        Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
              color: colour, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(m.label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
        _money(m.amount),
      ]),
    );
  }

  Widget _money(double v) {
    final text = v == 0 ? '\$0' : '${v > 0 ? '+' : '−'}\$${_amt(v.abs())}';
    if (v <= 0) {
      return Text(text,
          style: TextStyle(
              color: v == 0 ? _secondary : Colors.white,
              fontSize: 13, fontWeight: FontWeight.w700));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Halved.brightMint,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(color: Halved.deepPine, fontSize: 13,
              fontWeight: FontWeight.w700)),
    );
  }
}

class _Buttons extends StatelessWidget {
  final NassauHoleCard card;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Buttons({required this.card, required this.onPrev,
                  required this.onNext});

  @override
  Widget build(BuildContext context) {
    // **The last hole's forward button is Complete Round.** This tray takes
    // the screen's pager away while it is up, so there is nothing else left
    // to finish the round with.
    final last = card.nextHole == null;
    return Row(children: [
      SizedBox(
        width: 50, height: 50,
        child: OutlinedButton(
          onPressed: onPrev,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
            foregroundColor: Colors.white,
          ),
          child: const Icon(Icons.chevron_left, size: 24),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: onNext,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Halved.deepPine,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(25)),
            ),
            child: Text(
                last ? 'Complete Round ›' : 'Hole ${card.nextHole} ›',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    ]);
  }
}

String _amt(num v) {
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(2);
}
