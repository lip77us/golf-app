import 'package:flutter/material.dart' show Color;

import '../api/models.dart';

/// One shape for the Nassau board, whatever produced it.
///
/// Built from `~/Downloads/handoff-nassau-leaderboard`, whose scope line is
/// the one that matters: *"one widget used by every Nassau leaderboard: 2v2,
/// 1v1, Triple Nassau (one match at a time), cup Nassau tabs and group bets.
/// Do not draw a second Nassau table."*
///
/// ### Nothing here is DERIVED that the server already decided
///
/// The design reference computes statuses and money from hole indices —
/// `status(H, a, b)` walks the range and works out the close-out itself. We
/// do not, for a reason this codebase has already paid for twice:
///
/// > **The `M` in "3&2" ships from the server or it is wrong.** It is holes
/// > left in the match's own window counted along the group's play order, and
/// > the client cannot derive it from anything it holds.
///
/// `nassau_summary` emits `decided_margin` and `decided_remaining` per bet and
/// `holes_remaining` per press, so the close-out is read, never computed. The
/// money is `payoutTotalCapped` — already net of presses, Claremont's bottom
/// bets and the loss cap — for the same reason the skins board takes `net`:
/// a board that recomputes is a second opinion about money.
///
/// What IS derived here is layout: which tile belongs to which side, which
/// nine a press sits on, and the words around a status the server decided.
class NassauBoardData {
  const NassauBoardData({
    required this.sides,
    required this.holes,
    required this.front,
    required this.back,
    required this.overall,
    required this.presses,
    required this.stake,
    required this.pressStake,
    required this.net,
    this.lossCap,
    this.claremont,
    this.balls = const [],
    this.single = false,
    this.noMoney = false,
    this.showSides = true,
  });

  final List<NassauSide> sides;
  /// 18 entries: the side that won each hole, or null for a hole not played.
  final List<NassauHoleWinner> holes;
  final NassauBetView front;
  final NassauBetView back;
  final NassauBetView overall;
  final List<NassauPressView> presses;

  final double stake;
  final double pressStake;
  /// Signed, from side 0's view. Positive = side 0 is up. SERVER's figure,
  /// already capped.
  final double net;
  final double? lossCap;
  final ClaremontView? claremont;

  /// Claremont only: the two counted balls per side, per hole.
  ///
  /// The bottom bet is 2 points a hole — one for the lower LOW ball and one
  /// for the lower SECOND ball — so these four nets are what the points are
  /// made of, and the only way a reader can check them. Empty on every other
  /// variant, where there is no second ball and nothing to show.
  final List<NassauBallsHole> balls;

  /// One 18-hole match: Overall only, no Front/Back cards.
  final bool single;
  /// Cup matches play for points — the money line is hidden entirely.
  final bool noMoney;
  /// Hidden where the screen already names the match (Triple Nassau).
  final bool showSides;

  bool get allDone =>
      (single ? [overall] : [front, back, overall]).every((b) => b.done) &&
      presses.every((p) => p.done);

  /// Whose money the board shows. The side that is up, so the headline is a
  /// number somebody is winning rather than an arbitrary sign.
  int get me => net >= 0 ? 0 : 1;

  /// The amount for [me], always a magnitude with its own sign applied.
  double get moneyForMe => me == 0 ? net : -net;

  factory NassauBoardData.fromSummary(
    NassauSummary s, {
    bool showSides = true,
    bool noMoney = false,
    Color? side0Colour,
    Color? side1Colour,
  }) {
    String nameOf(List<NassauPlayerInfo> t) =>
        t.isEmpty ? '—' : t.map((p) => p.shortName).join(' & ');

    final holes = List<NassauHoleWinner>.generate(18, (i) {
      final h = s.holes.where((x) => x.hole == i + 1);
      if (h.isEmpty) return NassauHoleWinner.notPlayed;
      switch (h.first.winner) {
        case 'team1': return NassauHoleWinner.side0;
        case 'team2': return NassauHoleWinner.side1;
        case 'halved': return NassauHoleWinner.halved;
        default: return NassauHoleWinner.notPlayed;
      }
    });

    final isClaremont = s.variant == 'claremont';
    // Indexed by hole so a shotgun round (whose `holes` arrive in play order)
    // still lines these up under the tiles, which are drawn by hole number.
    final byHole = {for (final h in s.holes) h.hole: h};
    final balls = isClaremont
        ? List<NassauBallsHole>.generate(18, (i) {
            final h = byHole[i + 1];
            return NassauBallsHole(
              hole:     i + 1,
              lowA:     h?.t1Net,
              secondA:  h?.t12ndNet,
              lowB:     h?.t2Net,
              secondB:  h?.t22ndNet,
              delta:    h?.bottomDelta,
            );
          })
        : const <NassauBallsHole>[];

    final played = {for (final h in s.holes) h.hole};

    return NassauBoardData(
      sides: [
        NassauSide(name: nameOf(s.team1), colourIndex: 0,
            colour: side0Colour),
        NassauSide(name: nameOf(s.team2), colourIndex: 1,
            colour: side1Colour),
      ],
      holes: holes,
      front:   NassauBetView.fromBet(s.front9,  label: 'Front', startHole: 1),
      back:    NassauBetView.fromBet(s.back9,   label: 'Back',  startHole: 10),
      overall: NassauBetView.fromBet(s.overall, label: 'Match', startHole: 1),
      presses: [
        for (final p in s.presses)
          NassauPressView.fromPress(p, toPlay: _toPlay(p, played)),
        // Claremont's points presses are a SECOND series over the same holes,
        // labelled apart so a reader is never asked which of two identical
        // bars is which.
        for (final p in s.bottomPresses)
          NassauPressView.fromPress(p, points: true,
              toPlay: _toPlay(p, played)),
      ],
      stake:      s.betUnit,
      pressStake: s.pressUnit,
      // **The LIVE figure** (Design, 28 Oct 2026). `payoutTotalCapped` is
      // money already banked, and a bet only banks when its nine closes —
      // so a match 2 UP front and 2 UP overall read `All square · now $0`
      // on a card whose whole headline is the money. This is what changes
      // hands if the match ended now, which is what `· now` means.
      net:        s.payoutLiveTotal,
      lossCap:    s.lossCap,
      balls: balls,
      claremont: isClaremont
          ? ClaremontView(
              front:   s.bottomFront9  == null ? null
                  : NassauBetView.fromBottom(s.bottomFront9!,  startHole: 1),
              back:    s.bottomBack9   == null ? null
                  : NassauBetView.fromBottom(s.bottomBack9!,   startHole: 10),
              overall: s.bottomOverall == null ? null
                  : NassauBetView.fromBottom(s.bottomOverall!, startHole: 1),
              money: s.payoutBottomTotal,
            )
          : null,
      // TWO flags mean "one 18-hole match": `single_match` is the stored
      // setting, and `isEighteenHoleMatch` is the shape a Singles Match
      // actually arrives in (no front, no back, one golfer a side). Reading
      // only the first drew Front and Back cards that could never fill.
      single:   s.singleMatch || s.isEighteenHoleMatch,
      noMoney:  noMoney,
      showSides: showSides,
    );
  }
}

enum NassauHoleWinner { side0, side1, halved, notPlayed }

class NassauSide {
  const NassauSide({
    required this.name,
    required this.colourIndex,
    this.colour,
  });
  final String name;
  final int colourIndex;
  /// An explicit colour that OVERRIDES the palette slot.
  ///
  /// A cup match's sides have their own declared colours and a board that
  /// drew them pine-and-clay would be the fourball card's hardcoded-blue
  /// defect arriving by another route. Null everywhere else, where the slot
  /// is the right answer.
  final Color? colour;
}

/// One bet — a nine, the overall, or a press — as the board states it.
class NassauBetView {
  const NassauBetView({
    required this.label,
    required this.startHole,
    required this.leader,
    required this.headline,
    required this.sub,
    required this.done,
    required this.notStarted,
    required this.points,
    this.holesPlayed = 0,
  });

  final String label;
  final int startHole;
  /// 0, 1, or null when level / not started.
  final int? leader;
  /// `3 UP` · `4&3` · `AS` · `—`.
  final String headline;
  /// `thru 7` · `Final` · `Push` · `starts 10`.
  final String sub;
  final bool done;
  final bool notStarted;
  /// Carried so a caller never has to parse `sub` back apart.
  final int holesPlayed;
  /// Claremont's points row rather than a match-play status.
  final bool points;

  static int? _leaderOf(int margin) =>
      margin > 0 ? 0 : margin < 0 ? 1 : null;

  /// **Reads the server's close-out, never computes one.**
  factory NassauBetView.fromBet(NassauBetResult b,
      {required String label, required int startHole}) {
    if (b.holesPlayed == 0) {
      return NassauBetView(
        label: label, startHole: startHole, leader: null,
        headline: '—', sub: 'starts $startHole',
        done: false, notStarted: true, points: false, holesPlayed: 0,
      );
    }
    final decided = (b.decidedRemaining ?? 0) > 0 && b.decidedMargin != null;
    if (decided) {
      final m = b.decidedMargin!;
      return NassauBetView(
        label: label, startHole: startHole, leader: _leaderOf(m),
        headline: '${m.abs()}&${b.decidedRemaining}', sub: 'Final',
        done: true, notStarted: false, points: false,
        holesPlayed: b.holesPlayed,
      );
    }
    final over = b.result != null;
    final up = b.margin.abs();
    return NassauBetView(
      label: label, startHole: startHole, leader: _leaderOf(b.margin),
      headline: up == 0 ? 'AS' : '$up UP',
      sub: over ? (up == 0 ? 'Push' : 'Final') : 'thru ${b.holesPlayed}',
      done: over, notStarted: false, points: false,
      holesPlayed: b.holesPlayed,
    );
  }

  /// Claremont's bottom bet.
  ///
  /// **It is a MATCH, not a points tally** (Paul, 28 Oct 2026): two points a
  /// hole — best ball plus the second ball — four points to a press, and it
  /// **can be won before the finish when there are not enough 2-point holes
  /// left to catch up**. So it closes out like any other bet; what differs is
  /// the arithmetic, `2 x holes remaining` rather than `1 x`, which the
  /// engine has always applied and the summary now reports.
  ///
  /// The margin is still shown in POINTS (`+6`), because that is the unit the
  /// bet is played and pressed in — a bare `3 UP` would invite reading it as
  /// three holes.
  factory NassauBetView.fromBottom(NassauBottomBetResult b,
      {required int startHole}) {
    if (b.holesPlayed == 0) {
      return NassauBetView(
        label: 'Points', startHole: startHole, leader: null,
        headline: '—', sub: 'starts $startHole',
        done: false, notStarted: true, points: true,
      );
    }
    final decided = (b.decidedRemaining ?? 0) > 0 && b.decidedMargin != null;
    final m = decided ? b.decidedMargin! : b.margin;
    final over = decided || b.result != null;
    return NassauBetView(
      label: 'Points', startHole: startHole, leader: _leaderOf(m),
      headline: m == 0 ? 'AS' : '${m > 0 ? '+' : '−'}${m.abs()}',
      sub: !over
          ? 'thru ${b.holesPlayed}'
          : decided
              ? 'Final · ${b.decidedRemaining} to play'
              : (m == 0 ? 'Push' : 'Final'),
      done: over, notStarted: false, points: true,
      holesPlayed: b.holesPlayed,
    );
  }
}

/// Holes left in a press's window: its holes not yet played. A window can
/// wrap the 18th off a shotgun start (the 16th to the 2nd), so it is walked
/// rather than subtracted.
int _toPlay(NassauPressResult p, Set<int> played) {
  final window = <int>[];
  var h = p.startHole;
  for (var i = 0; i < 18; i++) {
    window.add(h);
    if (h == p.endHole) break;
    h = h == 18 ? 1 : h + 1;
  }
  return window.where((x) => !played.contains(x)).length;
}

class NassauPressView {
  const NassauPressView({
    required this.nine,
    required this.from,
    required this.to,
    required this.label,
    required this.view,
    required this.points,
  });

  final String nine;       // 'front' | 'back'
  final int from;
  final int to;
  final String label;
  final NassauBetView view;
  final bool points;

  bool get done => view.done;

  factory NassauPressView.fromPress(NassauPressResult p,
      {bool points = false, int? toPlay}) {
    // A press is a bet like any other; the only thing that differs is that
    // its window is a hole range rather than a nine, and the SERVER says how
    // many holes were left when it closed.
    final decided = p.holesRemaining > 0 && p.margin != null && p.result != null;
    final m = p.margin ?? 0;
    final leader = m > 0 ? 0 : m < 0 ? 1 : null;
    final String headline, sub;
    final bool done;
    if (p.result == null) {
      headline = m == 0 ? 'AS' : '${m.abs()} UP';
      // How much golf is left, not "live" (Paul, 29 Oct 2026): "1 UP ·
      // 1 to play", or "dormie" when the lead equals what is left — the
      // trailing side cannot win it, only halve it.
      sub = toPlay == null
          ? 'live'
          : (m != 0 && m.abs() == toPlay)
              ? 'dormie'
              : '$toPlay to play';
      done = false;
    } else if (decided) {
      headline = '${m.abs()}&${p.holesRemaining}';
      sub = 'Final';
      done = true;
    } else {
      headline = m == 0 ? 'AS' : '${m.abs()} UP';
      sub = m == 0 ? 'Push' : 'Final';
      done = true;
    }
    return NassauPressView(
      nine: p.nine, from: p.startHole, to: p.endHole,
      // The long form, the way the leaderboard already words it — the short
      // "F9 Press 1" chips are the PLAY screen's and stay there.
      label: '${points ? 'Points press' : 'Press'} '
             '${p.startHole}–${p.endHole}',
      points: points,
      view: NassauBetView(
        label: 'Press', startHole: p.startHole, leader: leader,
        headline: headline, sub: sub, done: done,
        notStarted: false, points: points,
      ),
    );
  }
}

/// One hole's counted balls, from the two sides, for Claremont's bottom bet.
///
/// `delta` is the SERVER's net points for side 0 on this hole (−2..+2) — not
/// recomputed from the four nets, because the engine owns what a tied ball
/// does and a second reading of it is a second opinion about money.
class NassauBallsHole {
  const NassauBallsHole({
    required this.hole,
    this.lowA,
    this.secondA,
    this.lowB,
    this.secondB,
    this.delta,
  });

  final int  hole;
  final int? lowA;
  final int? secondA;
  final int? lowB;
  final int? secondB;
  final int? delta;

  bool get played => lowA != null && lowB != null;

  /// Which side took the lower ball of a pair, or null when level / unplayed.
  int? _winnerOf(int? a, int? b) {
    if (a == null || b == null || a == b) return null;
    return a < b ? 0 : 1;
  }

  int? get lowWinner    => _winnerOf(lowA, lowB);
  int? get secondWinner => _winnerOf(secondA, secondB);
}

class ClaremontView {
  const ClaremontView({
    required this.front,
    required this.back,
    required this.overall,
    required this.money,
  });
  final NassauBetView? front;
  final NassauBetView? back;
  final NassauBetView? overall;
  /// The bottom bets' own settlement, already in the board's `net`.
  final double money;
}
