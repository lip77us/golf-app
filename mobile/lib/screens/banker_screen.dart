/// banker_screen.dart
///
/// Banker, playing it (Downloads/handoff-banker/HANDOFF.md, screen 2).
///
/// **The only game in the app where money is decided before anybody swings,
/// and the sequence in which it is decided is the entire game.** Get the order
/// wrong on screen and the format collapses into a guessing contest.
///
/// Four moments, in this order: the banker names a maximum, each opponent
/// picks his own number, the bets LOCK, and only then does the banker tee off
/// — last, knowing all three. Then doubles are shouted at balls in the air.
///
/// Step three is the one the app has to ENFORCE rather than record, so the
/// button says what it does rather than what it is. The packet words it *Lock
/// bets — Paul tees off*; this says **increases only from here**, because the
/// app
/// cannot know when anybody swings and naming one golfer asserts an order the
/// format does not have — the banker plays last, but the other three tee off
/// in whatever order they like and every bet is in before any of them does.
/// The server refuses anything above the lock afterwards, so this screen is
/// the polite half of a rule that holds either way.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/hole_grid_scorecard.dart';
import '../widgets/round_chat_button.dart';

/// Three action colours, one concept each, reused for nothing else:
/// gold = the role, blue = a player's double, amber = the banker's counter.
const _gold      = Color(0xFFB8860B);
const _goldFill  = Color(0xFFFBF0D6);
const _goldLine  = Color(0xFFE4D3A8);
const _goldPanel = Color(0xFFFDF8EC);
const _blue      = Color(0xFF1A5490);
const _blueFill  = Color(0xFFF1F7FD);
const _blueLine  = Color(0xFFB8CFE8);
const _amber     = Color(0xFF8A5216);
const _amberFill = Color(0xFFFDF3E7);
const _amberLine = Color(0xFFE8D6BC);

/// Money lost, and nothing else — the app's own red, as every other
/// leaderboard in it uses.
///
/// **Not amber.** Amber is the counter-double here, and the packet is explicit
/// that each of its three action colours maps to exactly one concept. A
/// negative figure in the counter's brown reads as though the counter caused
/// it, and the two are unrelated: a bet can be lost with no counter anywhere
/// near it.
final _owed     = Colors.red.shade700;

class BankerScreen extends StatefulWidget {
  const BankerScreen({super.key, required this.foursomeId});
  final int foursomeId;

  @override
  State<BankerScreen> createState() => _BankerScreenState();
}

class _BankerScreenState extends State<BankerScreen> {
  bool    _busy = false;
  Object? _error;
  /// The tied golfer the group has picked, before it is confirmed.
  int?    _tiePick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<RoundProvider>().loadBanker(widget.foursomeId);
    });
  }

  // -- posting --------------------------------------------------------------

  /// Every declaration is one POST returning the whole summary, so the screen
  /// never has to guess what the server made of it.
  Future<void> _declare({
    double? maxBet,
    List<Map<String, dynamic>>? bets,
    bool? lock,
    int? double_,
    int? undouble,
    bool? counter,
  }) async {
    final hole = context.read<RoundProvider>().bankerSummary?.currentHole;
    if (hole == null || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final s = await client.postBankerHole(
        widget.foursomeId,
        holeNumber: hole,
        maxBet: maxBet, bets: bets, lock: lock,
        double_: double_, undouble: undouble, counter: counter,
      );
      if (!mounted) return;
      context.read<RoundProvider>().setBankerSummary(s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _advance(BankerSummary s, {int? bankerId}) async {
    if (_busy || s.currentHole == null) return;
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final next = await client.postBankerAdvance(
        widget.foursomeId,
        afterHole: s.currentHole!,
        bankerId : bankerId,
        tieReason: bankerId == null ? null : 'holed_first',
      );
      if (!mounted) return;
      context.read<RoundProvider>().setBankerSummary(next);
      setState(() => _tiePick = null);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // -- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    final s  = rp.bankerSummary;

    return Scaffold(
      backgroundColor: Halved.surface,
      // The same bar every other play screen carries. Banker had a bare one,
      // so the round's chat and leaderboard were unreachable from the screen a
      // group spends the whole hole on — and this is the game whose board
      // exists precisely because nobody can hold fifty-four one-on-ones in
      // their head.
      appBar: GolfAppBar(
        title: 'Banker',
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          if (rp.round != null) RoundChatButton(roundId: rp.round!.id),
          IconButton(
            tooltip: 'Leaderboard',
            icon: const Icon(Icons.leaderboard_outlined),
            onPressed: rp.round == null
                ? null
                : () => Navigator.of(context)
                    .pushNamed('/leaderboard', arguments: rp.round!.id),
          ),
          IconButton(
            tooltip: 'Settle up',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).pushNamed(
                '/banker-settlement', arguments: widget.foursomeId),
          ),
        ],
      ),
      bottomNavigationBar: s == null ? null : _bottomBar(s),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
              children: [
                if (_error != null) ...[
                  ErrorView(message: friendlyError(_error!)),
                  const SizedBox(height: 12),
                ],
                if (s.current != null) ...[
                  // No banner card. The banker leads the list below with his
                  // gross, his three nets and what the hole is doing to him —
                  // a card above it repeating his name was saying the same
                  // thing twice and pushing the hole itself off the fold.
                  _holeStrip(s.current!),
                  const SizedBox(height: 12),
                  if (!s.current!.locked) ..._openHole(s, s.current!)
                  else ..._lockedHole(s, s.current!),
                ],
                if (s.awaitingTie != null) ...[
                  const SizedBox(height: 12),
                  _tiePicker(s),
                ] else if (s.nextBankerId != null) ...[
                  const SizedBox(height: 12),
                  _rotationNote(s),
                ],
                const SizedBox(height: 16),
                _standings(s),
                const SizedBox(height: 16),
                // **The card belongs on both screens.** A one-screen game
                // keeps it under the hole all round; Banker splits the hole
                // across two, and leaving the card on only one of them means
                // the group loses sight of the round exactly when the bets
                // are being argued over. Same shared grid, same gold banker
                // cells, same stroke plan.
                if (s.grid.isNotEmpty)
                  HoleGridScorecard(
                    holes: s.grid,
                    participants: s.gridPlayers,
                    legend: null,
                  ),
              ],
            ),
    );
  }

  /// Hole, par and STROKE INDEX on one line. The index earns its place here
  /// rather than being course trivia: it is what decides who strokes in each
  /// of the three matches, so it is the reason a bet is worth what it is.
  Widget _holeStrip(BankerHoleState h) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFDFE8E0),
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(children: [
          Text([
            'Hole ${h.hole}',
            if (h.par != null) 'Par ${h.par}',
            if (h.strokeIndex != null) 'SI ${h.strokeIndex}',
          ].join('   ·   '),
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
          if (h.isPar3) ...[
            const SizedBox(height: 2),
            const Text('triples, not doubles',
                style: TextStyle(fontSize: 12.5, color: Halved.muted)),
          ],
        ]),
      );

  // -- before the lock ------------------------------------------------------

  List<Widget> _openHole(BankerSummary s, BankerHoleState h) {
    final need = _opponentCount(s) - h.lines.length;
    final first = _bankerFirstName(s, h);
    return [
      // **He leads the hole from the first frame.** Dropping the old banner
      // card took his name off the screen entirely until a maximum had been
      // named — on the one screen whose whole subject is what HE is about to
      // do. The row is the same one the locked and settled frames use, so the
      // reader's eye lands in the same place all the way through the hole.
      _label('THE HOLE', 'floor \$${s.minBet.round()}'),
      _bankerRow(s, h, false),
      const SizedBox(height: 12),
      _note(
        h.maxBet == null
            // Named, not "the banker". Three golfers are waiting on one man
            // and the sentence should say which.
            ? '$first names his maximum first — nobody can pick a bet '
              'without it.'
            : 'Bets are open. Every opponent names his own number, and $first '
              'plays the hole last.',
        fill: _goldPanel, line: _goldLine, icon: '⏱',
      ),
      const SizedBox(height: 12),
      _maxChips(s, h),
      if (h.maxBet != null) ...[
        const SizedBox(height: 12),
        _label('THE BETS', 'floor \$${s.minBet.round()} · '
                           'max \$${h.maxBet!.round()}'),
        for (final m in _opponents(s, h)) _betRow(s, h, m),
        if (need > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                '$need ${need == 1 ? "bet" : "bets"} still to come.',
                style: const TextStyle(fontSize: 12.5, color: Halved.muted)),
          ),
      ],
    ];
  }

  /// Chips rather than a keypad: a hole max is one of four or five habitual
  /// numbers, and a stepper invites a $17 bet nobody wants to settle.
  Widget _maxChips(BankerSummary s, BankerHoleState h) {
    final steps = _chipSteps(s.minBet, s.maxBet);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('HIS MAXIMUM FOR THIS HOLE',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: Halved.muted)),
          const Spacer(),
          Text('ceiling \$${s.maxBet.round()}',
              style: const TextStyle(fontSize: 11, color: Halved.muted)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final v in steps)
            _chip('\$${v.round()}', on: h.maxBet == v, tone: _gold,
                onTap: _busy ? null : () => _declare(maxBet: v)),
        ]),
      ]),
    );
  }

  Widget _betRow(BankerSummary s, BankerHoleState h, BankerPlayerTotal m) {
    final line  = h.lines.where((l) => l.playerId == m.playerId).firstOrNull;
    // A golfer at his loss cap has no number to choose: the server holds him
    // to the floor whatever he taps. Offering the ladder anyway was the
    // screen asking a question it would then overrule — tap $50, watch $5
    // light up.
    final capped = h.cutOff.contains(m.playerId);
    final steps = capped
        ? [s.minBet]
        : _chipSteps(s.minBet, h.maxBet ?? s.maxBet);
    final atMax = !capped && line != null && line.bet == h.maxBet;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        // Row highlighted, amount greyed, until his number is in.
        color: line == null ? _goldPanel : Halved.card,
        border: Border.all(color: line == null ? _goldLine
                                               : Halved.cardBorder),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Flexible(
            child: Text(m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          // The handicap is on the row while the bet is being CHOSEN, which
          // is when it matters: a golfer picking his number wants to know how
          // many shots sit between him and the banker.
          _getsChip(m.playingHandicap),
          const Spacer(),
          if (capped) _tag('CAPPED', _amber, _amberFill, _amberLine),
          if (atMax)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _goldFill,
                borderRadius: BorderRadius.circular(Halved.rPill),
              ),
              child: const Text('AT THE MAX',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      color: _gold)),
            ),
          const SizedBox(width: 8),
          Text(line == null ? '—' : '\$${line.bet.round()}',
              style: TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w700,
                  color: line == null ? Halved.muted : Halved.deepPine)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 7, runSpacing: 7, children: [
          for (final v in steps)
            _chip('\$${v.round()}',
                on: line?.bet == v, tone: Halved.pine,
                onTap: _busy ? null : () => _declare(bets: [
                      {'player_id': m.playerId, 'amount': v}
                    ])),
        ]),
        if (capped)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'He reached his loss cap, so the floor is already down for '
                'him. No doubles, and the counter goes past him.',
                style: TextStyle(fontSize: 12, color: _amber)),
          ),
      ]),
    );
  }

  // -- after the lock -------------------------------------------------------

  List<Widget> _lockedHole(BankerSummary s, BankerHoleState h) {
    final scored = h.resolved;
    return [
      _note(
          scored
              ? 'The hole is posted. Every bet below settled on its own pair '
                'of strokes.'
              // Nothing here about the calls staying open. On the course
              // they are decided the moment the ball lands — the score going
              // in later is bookkeeping, not the deadline — so a screen
              // announcing a window is describing its own plumbing.
              : 'Bets can only increase from here.',
          fill: const Color(0xFFEAF4EE),
          line: const Color(0xFFC2DDCD),
          icon: '🔒'),
      const SizedBox(height: 12),
      _label('THE HOLE', '${h.lines.length} bets, strokes off'),
      // The banker leads the list and the opponents follow by index. He is
      // the man all three are measured against, and index order is the order
      // the strokes are in — everyone giving him a shot above everyone taking
      // one. It also makes the list add up on screen: his row plus the three
      // sums to zero, which is the only check a reader can run at a glance.
      _bankerRow(s, h, scored),
      for (final l in _byIndex(h.lines)) _resolvedRow(l, scored, h),
      if (!scored) ...[
        const SizedBox(height: 12),
        if (s.rules.playerDouble) _inTheAir(s, h),
        if (s.rules.counter) ...[
          const SizedBox(height: 10),
          _counterControl(h),
        ],
      ],
    ];
  }

  /// The banker's row, and the only place his three nets can honestly live.
  ///
  /// **He has one gross and three nets.** Strokes come off inside each
  /// one-on-one, so he plays Paul off one difference and Jim off another in
  /// the same breath — there is no single "his net", and every screen that
  /// tried to print one was printing a number that is not true of two of the
  /// three bets. So the gross stands alone and the three nets are named by
  /// whose match each belongs to.
  Widget _bankerRow(BankerSummary s, BankerHoleState h, bool scored) {
    final banker = s.players
        .where((p) => p.playerId == h.bankerId).firstOrNull;
    // Named, not initialled: "net versus Sean 4, RyanL 5, Paul 5". His three
    // nets are the one thing on this screen a reader cannot derive, so each
    // one says whose match it belongs to.
    final nets = _byIndex(h.lines)
        .map((l) => '${l.shortName} ${l.bankerNet ?? "–"}')
        .join(', ');

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _goldPanel,
        border: Border.all(color: _goldLine),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(banker?.name ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _goldFill,
                    borderRadius: BorderRadius.circular(Halved.rPill),
                  ),
                  child: const Text('BANKS',
                      style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700,
                          letterSpacing: 0.4, color: _gold)),
                ),
                // His handicap, on his row only. Every opponent's strokes are
                // the gap between this number and his own, so with it here the
                // three differentials can be checked without leaving the
                // screen — and the opponents' rows stay uncluttered, since
                // each already carries the one stroke that applies to him.
                _getsChip(h.bankerHandicap),
              ]),
              const SizedBox(height: 5),
              if (h.bankerGross != null)
                Text('gross ${h.bankerGross}   ·   net versus $nets',
                    style: const TextStyle(
                        fontSize: 12.5, color: Halved.muted))
              else if (h.maxBet == null)
                const Text('to name his maximum',
                    style: TextStyle(fontSize: 12.5, color: Halved.muted))
              else
                // Before every number is in his exposure is a RANGE, so it
                // projects the outstanding bets at his own maximum and names
                // who is still to bet.
                Text(
                    h.outstanding.isEmpty
                        ? 'facing ${h.lines.length} '
                          '${h.lines.length == 1 ? "bet" : "bets"}'
                        : 'if ${_andList(h.outstanding)} '
                          '${h.outstanding.length == 1 ? "takes" : "take"} '
                          'the max',
                    style: const TextStyle(
                        fontSize: 12.5, color: Halved.muted)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // Before the hole settles this is not a loss, it is EXPOSURE — so it
        // is labelled rather than signed. A minus in front of a number nobody
        // has lost yet reads as money already gone.
        if (scored)
          Text(h.bankerDelta == 0 ? '\$0' : _signed(h.bankerDelta),
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w700,
                  color: h.bankerDelta > 0
                      ? Halved.pine
                      : h.bankerDelta < 0 ? _owed : Halved.muted))
        else if (h.maxBet != null)
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            const Text('AT RISK',
                style: TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.w700,
                    letterSpacing: 0.5, color: Halved.muted)),
            Text(_money(h.outstanding.isEmpty
                    ? h.exposure : h.exposureIfMax),
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w700,
                    color: Halved.deepPine)),
          ]),
      ]),
    );
  }

  /// Opponents by handicap index. See `_bankerRow` for why that is the order.
  List<BankerBetLine> _byIndex(List<BankerBetLine> lines) =>
      List<BankerBetLine>.from(lines)
        ..sort((a, b) => a.handicapIndex.compareTo(b.handicapIndex));

  String _money(double v) => '\$${v.round()}';

  /// One bet, before or after the hole.
  ///
  /// **The number means one thing at each stage.** Before it resolves it is
  /// the STAKE — what is at risk, which is the only figure that exists yet.
  /// After, it is the RESULT: what actually changed hands. Leading with the
  /// stake on a settled hole made the loudest number on the row the one
  /// nobody owes.
  Widget _resolvedRow(BankerBetLine l, bool scored, BankerHoleState h) {
    final result = switch (l.outcome) {
      'won'  => l.amount,
      'lost' => -l.amount,
      _      => 0.0,
    };
    final tone = result > 0 ? Halved.pine : result < 0 ? _owed : Halved.muted;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(l.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ),
                // The stroke is a fact of the MATCH, so it sits on the match's
                // row — never a dot on somebody's score box, because the
                // banker holds a different relationship in each of the three.
                _getsChip(l.playingHandicap),
                if (l.strokes != 0) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEAF1FF),
                      borderRadius: BorderRadius.circular(Halved.rPill),
                    ),
                    child: Text(l.strokeNote,
                        style: const TextStyle(
                            fontSize: 10.5, fontWeight: FontWeight.w600,
                            color: _blue)),
                  ),
                ],
              ]),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                ..._multiplierTags(l),
                // A tie pays nothing, and a bare $0 with no reason beside it
                // is the most confusing thing this game produces. The void
                // still names what the bet had REACHED — a doubled bet that
                // paid nothing is a fact the group wants to see, and it is
                // what makes the counter a real gamble.
                if (scored && l.outcome == 'tied')
                  Text('no action · \$${l.stake.round()} void',
                      style: const TextStyle(
                          fontSize: 12, color: Halved.muted)),
                if (!scored)
                  Text('\$${l.stake.round()} at risk',
                      style: const TextStyle(
                          fontSize: 12, color: Halved.muted)),
              ]),
              // His gross, his net off the difference with the banker, and
              // the banker's net in THIS match — the two numbers that
              // actually decided this bet, side by side.
              if (l.gross != null) ...[
                const SizedBox(height: 4),
                Text('gross ${l.gross}   ·   net ${l.net}'
                     ' v ${l.bankerNet ?? "–"}',
                    style: const TextStyle(
                        fontSize: 12.5, color: Halved.muted)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
            scored
                ? (result == 0 ? '\$0' : _signed(result))
                : '\$${l.stake.round()}',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w700,
                color: scored ? tone : Halved.deepPine)),
      ]),
    );
  }

  /// "gets 17" — the playing handicap, on every one of the four rows.
  ///
  /// The strokes in each match are the gap between two of these, so the whole
  /// hole's handicap arithmetic can be checked on one screen without trusting
  /// the app to have done it right.
  Widget _getsChip(int? hcp) {
    if (hcp == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFE9F1EA),
        borderRadius: BorderRadius.circular(Halved.rPill),
      ),
      child: Text('gets $hcp',
          style: const TextStyle(
              fontSize: 10.5, fontWeight: FontWeight.w600,
              color: Halved.pine)),
    );
  }

  /// Named for who called it, not for the arithmetic. "×2 his double" told a
  /// reader the factor and left them to work out whose shot it rode on; the
  /// two doubles in this game come from opposite sides of the table and that
  /// is the part worth reading at a glance.
  List<Widget> _multiplierTags(BankerBetLine l) => [
        // Cut off by the house — floor bet, no double, and the counter went
        // past him. First on the row, because it explains why the rest of it
        // is so quiet.
        if (l.capped) _tag('CAPPED', _amber, _amberFill, _amberLine),
        // The bet he actually agreed on the tee, first in the row. With the
        // multipliers beside it the whole chain is legible again — $20 · a
        // golfer double · a banker double is $80 — but as bubbles rather than
        // the sentence of arithmetic that used to run under the row. The
        // headline stays the RESULT; this is how a golfer checks it.
        _tag('\$${l.bet.round()} bet', Halved.deepPine,
             const Color(0xFFEDF1EE), const Color(0xFFDDE5DF)),
        if (l.ownMultiplier > 1)
          _tag(l.ownMultiplier == 3 ? 'Golfer triple' : 'Golfer double',
               _blue, _blueFill, _blueLine),
        if (l.countered)
          _tag('Banker double', _amber, _amberFill, _amberLine),
        if (l.birdie)
          _tag('Birdie ×2', Halved.pine, const Color(0xFFEAF4EE),
               const Color(0xFFC2DDCD)),
      ];

  /// One tap per player, no confirmation — a double is shouted at a ball in
  /// flight and nobody is holding a phone. These controls are not live; they
  /// are a fast way to record what was just called.
  Widget _inTheAir(BankerSummary s, BankerHoleState h) {
    final word = (h.isPar3 && s.rules.par3Triples) ? 'triple' : 'double';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: _blueFill,
        border: Border.all(color: _blueLine),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('IN THE AIR',
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700,
                letterSpacing: 0.5, color: _blue)),
        const SizedBox(height: 8),
        // Index order, the same order the bets are listed in directly above.
        // Two rows of the same three men in two different orders is a
        // misread waiting to happen when the button says only a short name.
        Builder(builder: (_) {
          final lines = _byIndex(h.lines);
          return Row(children: [
            for (final l in lines) ...[
              Expanded(
                child: _airButton(
                  l.shortName,
                  // A capped golfer cannot double, so the button says why
                  // rather than taking the tap and returning a server error.
                  l.capped
                      ? 'capped'
                      : l.ownMultiplier > 1 ? '${word}d' : word,
                  on: l.ownMultiplier > 1,
                  off: l.capped,
                  onTap: (_busy || l.capped)
                      ? null
                      : () => _declare(
                          double_  : l.ownMultiplier > 1 ? null : l.playerId,
                          undouble : l.ownMultiplier > 1 ? l.playerId : null),
                ),
              ),
              if (l != lines.last) const SizedBox(width: 8),
            ],
          ]);
        }),
      ]),
    );
  }

  Widget _airButton(String name, String sub,
      {required bool on, bool off = false, VoidCallback? onTap}) {
    final ink = off ? Halved.muted : (on ? Colors.white : _blue);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Halved.rChip),
      child: Container(
        height: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: off ? Halved.surface : (on ? _blue : Halved.card),
          border: Border.all(
              color: off ? Halved.cardBorder : (on ? _blue : _blueLine)),
          borderRadius: BorderRadius.circular(Halved.rChip),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(name,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: ink)),
          Text(sub,
              style: TextStyle(
                  fontSize: 11,
                  color: off ? Halved.muted
                             : (on ? Colors.white70
                                   : _blue.withValues(alpha: 0.7))),
          ),
        ]),
      ),
    );
  }

  /// One decision landing on all three bets, so it is one full-width control.
  /// Three toggles would suggest he can pick.
  Widget _counterControl(BankerHoleState h) => InkWell(
        onTap: _busy ? null : () => _declare(counter: !h.countered),
        borderRadius: BorderRadius.circular(Halved.rCard),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: h.countered ? _amber : _amberFill,
            border: Border.all(color: h.countered ? _amber : _amberLine),
            borderRadius: BorderRadius.circular(Halved.rCard),
          ),
          child: Column(children: [
            Text(h.countered
                    ? 'Countered — every bet doubled'
                    : 'Banker counter-doubles',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700,
                    color: h.countered ? Colors.white : _amber)),
            const SizedBox(height: 2),
            // Only the bets the counter can actually reach — it goes past a
            // capped golfer, so "all three bets" would be a promise the
            // settlement does not keep.
            Text(_allBets(h.lines.where((l) => !l.capped).length),
                style: TextStyle(
                    fontSize: 11.5,
                    color: h.countered ? Colors.white70
                                       : _amber.withValues(alpha: 0.8))),
          ]),
        ),
      );

  // -- the tie a phone cannot settle ---------------------------------------

  Widget _tiePicker(BankerSummary s) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          color: _goldPanel,
          border: Border.all(color: _goldLine),
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('WHO TAKES THE BANK?',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: _gold)),
          const SizedBox(height: 6),
          const Text(
              'Tied for the low net. The traditional tiebreak is whoever '
              'holed out first, which the phone did not see — so it asks.',
              style: TextStyle(fontSize: 13, height: 1.45,
                               color: Halved.muted)),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in s.tieCandidates)
              _chip(c['short_name'] as String? ?? '',
                  on: _tiePick == c['player_id'],
                  tone: _gold,
                  onTap: () =>
                      setState(() => _tiePick = c['player_id'] as int?)),
          ]),
        ]),
      );

  /// Low net takes the role, and when it is outright the app simply says so —
  /// a role that changed hands unannounced is how two golfers end up both
  /// thinking they are banking the 8th.
  Widget _rotationNote(BankerSummary s) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: _goldPanel,
          border: Border.all(color: _goldLine),
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('THE BANK PASSES',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: _gold)),
          const SizedBox(height: 4),
          Text('${s.nextBankerName} had the low net',
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
          const SizedBox(height: 2),
          const Text('Outright, so there is nothing to settle — but it is '
                     'said out loud, because a role that changes hands '
                     'quietly is how two golfers both think they are banking '
                     'the next one.',
              style: TextStyle(
                  fontSize: 12.5, height: 1.45, color: Halved.muted)),
        ]),
      );

  // -- the money so far -----------------------------------------------------

  /// Where everybody stands, and nothing else.
  ///
  /// This deliberately does NOT carry the banking / betting split the
  /// leaderboard leads with. That pair is an observation about a whole round —
  /// a golfer can finish level having been wildly up as banker and wildly down
  /// as a player — and it is worth reading once the round is done. Standing on
  /// a tee with a bet to place, the only number anybody can act on is what he
  /// is up or down, and putting three figures on the row makes the eye hunt
  /// for the one that matters.
  Widget _standings(BankerSummary s) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
        decoration: BoxDecoration(
          color: Halved.card,
          border: Border.all(color: Halved.cardBorder),
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('WHERE IT STANDS',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: Halved.muted)),
          const SizedBox(height: 6),
          for (final p in s.players)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(children: [
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14.5, fontWeight: FontWeight.w600)),
                    ),
                    if (p.cutOff) ...[
                      const SizedBox(width: 7),
                      _tag('CAPPED', _amber, _amberFill, _amberLine),
                    ],
                  ]),
                ),
                Text(_signed(p.total),
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700,
                        color: p.total > 0
                            ? Halved.pine
                            : p.total < 0 ? _owed : Halved.muted)),
              ]),
            ),
        ]),
      );

  // -- the bar --------------------------------------------------------------

  Widget _bottomBar(BankerSummary s) {
    final h = s.current;
    final tie = s.awaitingTie != null;

    String label;
    VoidCallback? onTap;

    if (tie) {
      label = _tiePick == null ? 'Confirm the banker' : 'Confirm the banker';
      onTap = _tiePick == null || _busy
          ? null
          : () => _advance(s, bankerId: _tiePick);
    } else if (h == null) {
      label = 'Enter scores';
      onTap = () => Navigator.of(context)
          .pushNamed('/score-entry', arguments: widget.foursomeId);
    } else if (!h.locked) {
      final need = _opponentCount(s) - h.lines.length;
      // NOT "— Paul tees off", which the packet asks for: the app cannot know
      // when anybody swings, and naming one golfer asserts an order the
      // format does not have. The button names the CONSEQUENCE.
      //
      // And not "doubles only from here" either — on a par 3 the call is a
      // TRIPLE, so the word was wrong on four holes of the round. "Presses"
      // would be worse: in this app a press is a NEW BET at the same amount
      // and explicitly not a doubling (Nassau's meaning, and Sequoya's), so
      // it would point at the wrong mechanic entirely.
      //
      // "Amounts are final" was nearly right and quietly false: a $10 bet can
      // reach $60 after the lock. What the lock closes is the DIRECTION —
      // nothing can come down again, only up, whether by a double, a triple
      // or the counter. That holds on all eighteen holes and tells the banker
      // the thing he actually needs: his exposure has one way to go.
      label = need > 0
          ? '$need ${need == 1 ? "bet" : "bets"} to go'
          : 'Lock the bets — increases only from here';
      onTap = (need > 0 || h.maxBet == null || _busy)
          ? null
          : () => _declare(lock: true);
    } else if (!h.resolved) {
      label = 'Enter scores';
      onTap = _openScoreEntry;
    } else {
      // **A settled hole is a stop, not a step.** With a clean low net there
      // is nothing to ask, so it would be easy to slide straight into the
      // next hole's betting — and the group would never see what the last one
      // did to them. So the screen holds here on the result, the rotation is
      // announced above, and the button names where it goes next rather than
      // saying "next": you are proceeding FROM something you have read.
      final next = _nextHoleNumber(s);
      label = next == null ? 'Proceed' : 'Proceed to hole $next';
      onTap = _busy ? null : () => _advance(s);
    }

    // **A posted hole still has to be reachable.** Once the three bets
    // resolved, the only button here was "Next hole" — so a score typed wrong
    // had nowhere to be corrected from: this screen had stopped offering
    // score entry and the hub sends a Banker round back here rather than to
    // it. The way in stays open for the whole round.
    final canEdit = h != null && h.locked;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        child: Row(children: [
          if (canEdit && (h.resolved || tie)) ...[
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed: _busy ? null : _openScoreEntry,
                  child: const Text('Edit scores',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 52,
              child: FilledButton(
                onPressed: onTap,
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  String _bankerFirstName(BankerSummary s, BankerHoleState h) =>
      s.players
          .where((p) => p.playerId == h.bankerId)
          .map((p) => p.name.split(' ').first)
          .firstOrNull ??
      'The banker';

  /// "all three bets", "both bets", "the bet" — Banker plays three-handed as
  /// happily as four, and a control that lands on two while announcing three
  /// is the sort of thing that makes a group stop trusting the numbers beside
  /// it.
  String _allBets(int n) => switch (n) {
        0 => 'One tap',
        1 => 'One tap, the whole bet',
        2 => 'One tap, both bets',
        _ => 'One tap, all $n bets',
      };

  /// The hole after the one on screen, in PLAY order — a shotgun start does
  /// not go 3, 4.
  int? _nextHoleNumber(BankerSummary s) {
    final holes = s.holes.map((h) => h.hole).toList();
    final i = holes.indexOf(s.currentHole ?? -1);
    if (i < 0 || i + 1 >= holes.length) return null;
    return holes[i + 1];
  }

  /// Into the shared entry screen, and back with the summary refreshed. The
  /// same door whether the hole is being scored for the first time or a wrong
  /// number is being put right.
  Future<void> _openScoreEntry() async {
    await Navigator.of(context)
        .pushNamed('/score-entry', arguments: widget.foursomeId);
    if (!mounted) return;
    await context.read<RoundProvider>().loadBanker(widget.foursomeId);
  }

  // -- small pieces ---------------------------------------------------------

  Widget _note(String text,
      {required Color fill, required Color line, required String icon}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: fill,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(Halved.rChip),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(icon, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 9),
        Expanded(
          child: Text(text,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.45, color: Halved.deepPine)),
        ),
      ]),
    );
  }

  Widget _label(String left, String right) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 4, 2, 2),
        child: Row(children: [
          Text(left,
              style: const TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: Halved.pine)),
          const Spacer(),
          Text(right,
              style: const TextStyle(fontSize: 11, color: Halved.muted)),
        ]),
      );

  Widget _chip(String text,
      {required bool on, required Color tone, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Halved.rPill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: on ? tone.withValues(alpha: 0.12) : Halved.card,
          border: Border.all(color: on ? tone : Halved.cardBorder,
                             width: on ? 1.5 : 1),
          borderRadius: BorderRadius.circular(Halved.rPill),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700,
                color: on ? tone : Halved.deepPine)),
      ),
    );
  }

  Widget _tag(String text, Color ink, Color fill, Color line) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(Halved.rPill),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: ink)),
      );

  // -- helpers --------------------------------------------------------------

  int _opponentCount(BankerSummary s) => (s.players.length - 1).clamp(1, 3);

  /// The three opponents, by handicap — the same order the resolved list and
  /// score entry use, so a golfer's row is in the same place at every stage of
  /// the hole.
  List<BankerPlayerTotal> _opponents(BankerSummary s, BankerHoleState h) =>
      s.players.where((p) => p.playerId != h.bankerId).toList()
        ..sort((a, b) => a.handicapIndex.compareTo(b.handicapIndex));


  /// The numbers golfers actually bet, laddered — never a stepper, which
  /// invites a \$17 bet nobody wants to settle.
  ///
  /// This used to interpolate quarters and round them to multiples of five,
  /// which worked at \$5–\$50 and fell apart underneath it: a \$1–\$4 band
  /// rounded every intermediate to 0 or 5, both outside the band, and offered
  /// ONE chip. A dollar game is worth playing — it gets big fast enough
  /// through the doubles — so the small end has to work as well as the big.
  ///
  /// Walking a fixed ladder of habitual amounts fixes both ends at once:
  /// \$1–\$5 lands exactly on \$1 \$2 \$3 \$5, and \$5–\$50 thins to four
  /// round numbers instead of five arbitrary ones.
  static const _ladder = [1, 2, 3, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100,
                          150, 200];

  List<double> _chipSteps(double lo, double hi) {
    if (hi <= lo) return [lo];
    // Both ends always appear: the floor is what he must have on, and the
    // banker's maximum is the number the group is watching for.
    final vals = <double>{lo, hi};
    for (final v in _ladder) {
      if (v > lo && v < hi) vals.add(v.toDouble());
    }
    final all = vals.toList()..sort();
    if (all.length <= 4) return all;
    // Four is the most a thumb picks from without reading. Thin by position
    // so the ends survive and the middle stays evenly spread.
    final out = <double>{};
    for (var i = 0; i < 4; i++) {
      out.add(all[((i * (all.length - 1)) / 3).round()]);
    }
    return out.toList()..sort();
  }

  /// "Lee", "Sam and Lee", "Ryan, Sam and Lee".
  String _andList(List<String> names) {
    if (names.length <= 1) return names.isEmpty ? '' : names.first;
    return '${names.sublist(0, names.length - 1).join(", ")} and ${names.last}';
  }

  String _signed(double v) =>
      v == 0 ? '—' : (v > 0 ? '+\$${v.round()}' : '−\$${v.abs().round()}');
}
