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
/// bets — Paul tees off*; this says **doubles only from here**, because the
/// app cannot know when anybody swings and naming one golfer asserts an order
/// the format does not have — the banker plays last, but the other three tee
/// off in whatever order they like and every bet is in before any of them
/// does. The server refuses anything above the lock afterwards, so this screen
/// is the polite half of a rule that holds either way.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/error_view.dart';

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
const _owedFill = Color(0xFFFBECEA);

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
      appBar: AppBar(
        title: const Text('Banker'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
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
                  _bankerBanner(s, s.current!),
                  const SizedBox(height: 12),
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
              ],
            ),
    );
  }

  // -- the banner -----------------------------------------------------------

  /// The banker's own banner, and the only live worst case anywhere in the app
  /// — because it is the only place one exists. While a bet is still
  /// outstanding it reads as a RANGE, not a total: his exposure is not a
  /// number yet.
  Widget _bankerBanner(BankerSummary s, BankerHoleState h) {
    final banker = s.players
        .where((p) => p.playerId == h.bankerId).firstOrNull;
    // Before every number is in, his exposure is a RANGE — so the banner
    // projects the top of it and names who is still to bet, rather than
    // showing a total that grows silently as bets arrive.
    final pending = h.outstanding;
    final worst   = pending.isEmpty ? h.exposure : h.exposureIfMax;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: _goldPanel,
        border: Border.all(color: _goldLine),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('BANKING THE ${_ordinal(h.hole)}'.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  letterSpacing: 0.6, color: _gold)),
          const Spacer(),
          Text('HOLE ${h.hole}',
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 0.4, color: Halved.muted)),
        ]),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(banker?.name ?? 'Banker',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700,
                        color: Halved.deepPine)),
                const SizedBox(height: 2),
                const Text('Tees off last',
                    style: TextStyle(fontSize: 13, color: Halved.muted)),
              ],
            ),
          ),
          if (h.maxBet != null)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('\$${h.maxBet!.round()}',
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w700, color: _gold)),
              const Text('HIS MAX',
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w700,
                      letterSpacing: 0.5, color: _gold)),
            ]),
        ]),
        if (h.betsIn) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.only(top: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _goldLine)),
            ),
            child: Row(children: [
              Text(
                  !h.resolved
                      ? 'Facing ${h.lines.length} '
                        '${h.lines.length == 1 ? "bet" : "bets"}'
                      : h.bankerDelta > 0
                          ? 'The hole made him'
                          : h.bankerDelta < 0
                              ? 'The hole cost him'
                              : 'He came out level',
                  style: const TextStyle(fontSize: 13, color: Halved.muted)),
              const Spacer(),
              Flexible(
                child: Text(
                    // Once the hole is posted the worst case is history. What
                    // he wants then is what it actually did, and leaving a
                    // number labelled "worst case" beside a settled hole reads
                    // as money still at risk.
                    h.resolved
                        // Level reads as a word, not "—": on a hole where
                        // three bets cancelled, nothing moving IS the story.
                        ? (h.bankerDelta == 0
                            ? 'the three cancelled'
                            : _signed(h.bankerDelta))
                        : pending.isEmpty
                            ? '−\$${worst.round()} worst case'
                            : '−\$${worst.round()} if ${_andList(pending)} '
                              '${pending.length == 1 ? "takes" : "take"} the max',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700,
                        color: h.resolved && h.bankerDelta > 0
                            ? Halved.pine : _owed)),
              ),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _holeStrip(BankerHoleState h) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFDFE8E0),
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(children: [
          Text('Hole ${h.hole}',
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
          const SizedBox(height: 2),
          Text([
            if (h.par != null) 'Par ${h.par}',
            if (h.isPar3) 'triples, not doubles',
          ].join(' · '),
              style: const TextStyle(fontSize: 13, color: Halved.muted)),
        ]),
      );

  // -- before the lock ------------------------------------------------------

  List<Widget> _openHole(BankerSummary s, BankerHoleState h) {
    final need = _opponentCount(s) - h.lines.length;
    return [
      _note(
        h.maxBet == null
            ? 'The banker names his maximum first — nobody can pick a bet '
              'without it.'
            : 'Bets are open. Every opponent names his own number, and the '
              'banker plays the hole last.',
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
    final steps = _chipSteps(s.minBet, h.maxBet ?? s.maxBet);
    final atMax = line != null && line.bet == h.maxBet;

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
          Expanded(
            child: Text(m.name,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
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
              : 'Bets are final. Doubles are open until the first score goes '
                'in.',
          fill: const Color(0xFFEAF4EE),
          line: const Color(0xFFC2DDCD),
          icon: '🔒'),
      const SizedBox(height: 12),
      _label('THE ${h.lines.length} BETS',
             'v. ${_bankerShort(s, h)}, net'),
      for (final l in h.lines) _resolvedRow(l, scored),
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

  Widget _resolvedRow(BankerBetLine l, bool scored) {
    final (tag, tone, fill) = switch (l.outcome) {
      'won'  => ('WON', Halved.pine, const Color(0xFFEAF4EE)),
      'lost' => ('LOST', _owed, _owedFill),
      'tied' => ('TIED — NO ACTION', Halved.muted, const Color(0xFFF2F5F2)),
      _      => ('UNRESOLVED', Halved.muted, Halved.card),
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder),
        borderRadius: BorderRadius.circular(Halved.rCard),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(l.name,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          // The stroke is a fact of the MATCH, so it sits on the match's row —
          // never a dot on somebody's score box, because the banker holds a
          // different relationship in each of the three bets.
          if (l.strokes != 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE9F1EA),
                borderRadius: BorderRadius.circular(Halved.rPill),
              ),
              child: Text(l.strokeNote,
                  style: const TextStyle(
                      fontSize: 10.5, fontWeight: FontWeight.w600,
                      color: Halved.pine)),
            ),
          const SizedBox(width: 8),
          Text('\$${l.stake.round()}',
              style: const TextStyle(
                  fontSize: 19, fontWeight: FontWeight.w700,
                  color: Halved.deepPine)),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (l.ownMultiplier > 1)
            _tag('×${l.ownMultiplier} '
                 '${l.ownMultiplier == 3 ? "HIS TRIPLE" : "HIS DOUBLE"}',
                 _blue, _blueFill, _blueLine),
          if (l.countered) _tag('×2 COUNTER', _amber, _amberFill, _amberLine),
          if (l.birdie) _tag('×2 BIRDIE', Halved.pine,
                             const Color(0xFFEAF4EE),
                             const Color(0xFFC2DDCD)),
        ]),
        if (scored) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(Halved.rChip),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tag,
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w700,
                        letterSpacing: 0.4, color: tone)),
                const SizedBox(height: 3),
                // The only screen in the app that shows arithmetic, and it
                // earns it: the argument is always about the chain.
                Text(l.chain,
                    style: const TextStyle(
                        fontSize: 12.5, color: Halved.muted)),
              ],
            ),
          ),
        ],
      ]),
    );
  }

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
        const Row(children: [
          Text('IN THE AIR',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: _blue)),
          Spacer(),
          Text('OPEN UNTIL THE FIRST SCORE',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600,
                  color: Halved.muted)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          for (final l in h.lines) ...[
            Expanded(
              child: _airButton(
                l.shortName,
                l.ownMultiplier > 1 ? '${word}d' : word,
                on: l.ownMultiplier > 1,
                onTap: _busy
                    ? null
                    : () => _declare(
                        double_  : l.ownMultiplier > 1 ? null : l.playerId,
                        undouble : l.ownMultiplier > 1 ? l.playerId : null),
              ),
            ),
            if (l != h.lines.last) const SizedBox(width: 8),
          ],
        ]),
      ]),
    );
  }

  Widget _airButton(String name, String sub,
      {required bool on, VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Halved.rChip),
      child: Container(
        height: 58,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? _blue : Halved.card,
          border: Border.all(color: on ? _blue : _blueLine),
          borderRadius: BorderRadius.circular(Halved.rChip),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(name,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700,
                  color: on ? Colors.white : _blue)),
          Text(sub,
              style: TextStyle(
                  fontSize: 11,
                  color: on ? Colors.white70 : _blue.withValues(alpha: 0.7))),
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
            Text('One tap, all three bets',
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
        child: Row(children: [
          const Text('NEXT BANK',
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700,
                  letterSpacing: 0.5, color: _gold)),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${s.nextBankerName} had the low net',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w600,
                    color: Halved.deepPine)),
          ),
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
                  child: Text(p.name,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
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
      // NOT "— Paul tees off", which the packet asks for. The app cannot know
      // when anybody swings and naming one golfer asserts an order the format
      // does not have: the banker plays last, but the other three tee off in
      // whatever order they like and every bet has to be in before any of
      // them does. The button names the CONSEQUENCE instead — and "no changes
      // after this" would be wrong, because a double still moves a number.
      label = need > 0
          ? '$need ${need == 1 ? "bet" : "bets"} to go'
          : 'Lock the bets — doubles only from here';
      onTap = (need > 0 || h.maxBet == null || _busy)
          ? null
          : () => _declare(lock: true);
    } else if (!h.resolved) {
      label = 'Enter scores';
      onTap = () async {
        await Navigator.of(context)
            .pushNamed('/score-entry', arguments: widget.foursomeId);
        if (mounted) {
          await context.read<RoundProvider>().loadBanker(widget.foursomeId);
        }
      };
    } else {
      // Naming him on the button too: this is the tap that hands the role
      // over, and it should say whose it becomes.
      final who = s.nextBankerName.split(' ').first;
      label = who.isEmpty ? 'Next hole' : 'Next hole — $who banks it';
      onTap = _busy ? null : () => _advance(s);
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
        child: SizedBox(
          height: 52,
          width: double.infinity,
          child: FilledButton(
            onPressed: onTap,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
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

  List<BankerPlayerTotal> _opponents(BankerSummary s, BankerHoleState h) =>
      s.players.where((p) => p.playerId != h.bankerId).toList();

  String _bankerShort(BankerSummary s, BankerHoleState h) =>
      s.players.where((p) => p.playerId == h.bankerId)
          .map((p) => p.shortName).firstOrNull ?? 'the banker';

  /// Four or five habitual numbers between the floor and the ceiling — never a
  /// stepper, which invites a $17 bet nobody wants to settle.
  List<double> _chipSteps(double lo, double hi) {
    if (hi <= lo) return [lo];
    final out = <double>{lo};
    for (final f in [0.25, 0.5, 0.75]) {
      final v = (lo + (hi - lo) * f);
      out.add((v / 5).round() * 5.0);
    }
    out.add(hi);
    return out.where((v) => v >= lo && v <= hi).toList()..sort();
  }

  /// "Lee", "Sam and Lee", "Ryan, Sam and Lee".
  String _andList(List<String> names) {
    if (names.length <= 1) return names.isEmpty ? '' : names.first;
    return '${names.sublist(0, names.length - 1).join(", ")} and ${names.last}';
  }

  String _signed(double v) =>
      v == 0 ? '—' : (v > 0 ? '+\$${v.round()}' : '−\$${v.abs().round()}');

  String _ordinal(int n) {
    if (n >= 11 && n <= 13) return '${n}th';
    return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd',
                             _ => '${n}th' };
  }
}
