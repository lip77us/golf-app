/// banker_setup_screen.dart
///
/// Banker setup (Downloads/handoff-banker/HANDOFF.md, screen 1).
///
/// Every other game in the app has a stake you can write on one line. Banker
/// has a BAND, a per-hole ceiling one golfer sets on the tee, and four rules
/// that multiply — and the interaction of those is the only thing this screen
/// really has to communicate.
///
/// **Exposure is the headline, not a footnote.** This is the one game in the
/// set where a golfer can lose a genuinely surprising amount on a single hole,
/// and it is not because the stakes are high: the banker faces three bets at
/// once and both sides can double them. The panel shows the whole LADDER
/// rather than one worst case, because the point is not that the top number is
/// likely — it is that the top number exists, and a golfer who reads the
/// second line sets his ceiling differently.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart' show ApiException;
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../theme/halved_brand.dart';
import '../widgets/error_view.dart';
import 'banker_draw_screen.dart';

/// Gold marks the ROLE and does nothing else in this game — not a state, not a
/// warning. Mint stays the app's colour and never means banker.
const _gold      = Color(0xFFB8860B);
const _goldFill  = Color(0xFFFBF0D6);
const _goldLine  = Color(0xFFE4D3A8);
const _goldPanel = Color(0xFFFDF8EC);
/// The one sanctioned non-counter use of amber: the packet's own token note
/// reads "amber (the counter, and warnings)", and the top rung of the exposure
/// ladder is exactly a warning — the number nobody pictures when they set up a
/// "$50 game". It marks no action and appears nowhere else on this screen.
const _amber     = Color(0xFF8A5216);

class BankerSetupScreen extends StatefulWidget {
  const BankerSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  final int  foursomeId;
  final bool returnToHub;

  @override
  State<BankerSetupScreen> createState() => _BankerSetupScreenState();
}

class _BankerSetupScreenState extends State<BankerSetupScreen> {
  List<Membership> _players = [];
  int?    _firstBanker;
  bool    _flipped = false;

  // The band. Its WIDTH is the decision — $5 to $50 is a different game from
  // $20 to $25 — which is why it is one track and not two boxes.
  RangeValues _band = const RangeValues(5, 50);

  // Strokes-off by default: a Banker hole is three one-on-ones, and a match is
  // played off the difference between two handicaps.
  String _mode = 'strokes_off';
  String _rotation = 'ask';
  bool _playerDouble = true;
  bool _counter = true;
  bool _par3Triples = true;
  bool _birdieBonus = true;
  bool _capOn = false;

  /// Typed, not dragged. A slider spanning a whole exposure ladder cannot
  /// land on a round number — at a \$15–\$180 range in forty steps there is
  /// no \$100 to pick — and a ceiling somebody cannot state exactly is not a
  /// ceiling they agreed to.
  final TextEditingController _capCtrl = TextEditingController();
  bool _lossCapOn = false;

  /// Each golfer's own number, typed. Blank means he named none.
  ///
  /// Free entry rather than a ladder of amounts: the figure has to be sized
  /// against what a HOLE can reach, and the two are not proportional. A
  /// \$1–\$5 game can still put \$180 on a par 3, so a golfer good for \$500
  /// and one who stops at \$200 are both making sensible calls that no fixed
  /// list would offer them.
  final Map<int, TextEditingController> _lossCtrls = {};

  bool _saving = false;

  /// The screen opens on the SAVED game when there is one. Reached from the
  /// hub's *Edit configuration*, a form that came up on its defaults was not
  /// showing the round's settings, it was quietly proposing to replace them —
  /// and the first banker defaulting to the top of the roster meant the most
  /// destructive of those replacements was also the easiest to save.
  bool _loading = true;
  bool _editing = false;

  /// A hole is already on the books. The band, the rules and the caps can all
  /// still change from here — the first banker cannot, because hole 1 has
  /// already been banked by somebody.
  bool _played = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final rp = context.read<RoundProvider>();
    final fs =
        rp.round?.foursomes.where((f) => f.id == widget.foursomeId).firstOrNull;
    _players = fs?.realPlayers.toList() ?? [];
    if (_players.isNotEmpty) _firstBanker = _players.first.player.id;
    for (final m in _players) {
      _lossCtrls[m.player.id] = TextEditingController();
    }
    _load();
  }

  /// Adopt the saved configuration, or fall back to the casual defaults when
  /// no game exists yet.
  ///
  /// A 404 is the ordinary answer here — it is how the server says *no Banker
  /// game*, which is exactly the state a first setup is in — so it is not
  /// surfaced as an error. Anything else is.
  Future<void> _load() async {
    try {
      final s = await context
          .read<AuthProvider>()
          .client
          .getBanker(widget.foursomeId);
      if (!mounted) return;
      setState(() {
        _editing = true;
        _played = s.holes.any((h) => h.resolved || h.betsIn);
        // Clamp rather than trust: the band track is $1–$100 and a stored
        // band outside it would assert on the first frame.
        _band = RangeValues(s.minBet.clamp(1, 100).toDouble(),
            s.maxBet.clamp(1, 100).toDouble());
        _mode = s.handicapMode;
        _rotation = s.rotationRule;
        _playerDouble = s.rules.playerDouble;
        _counter = s.rules.counter;
        _par3Triples = s.rules.par3Triples;
        _birdieBonus = s.rules.birdieBonus;
        _capOn = s.holeCap != null;
        if (s.holeCap != null) _capCtrl.text = _plain(s.holeCap!);
        for (final p in s.players) {
          if (p.lossCap == null) continue;
          _lossCapOn = true;
          _lossCtrls[p.playerId]?.text = _plain(p.lossCap!);
        }
        final first = s.holes.isEmpty ? null : s.holes.first.bankerId;
        if (first != null) {
          _firstBanker = first;
          _flipped = true; // settled already; no reel to run
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.statusCode != 404) _error = e;
        _loading = false;
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _error = e;
          _loading = false;
        });
    }
  }

  /// `500`, not `500.0` — the field is one a golfer typed and will read back.
  static String _plain(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  @override
  void dispose() {
    _capCtrl.dispose();
    for (final c in _lossCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// A typed money amount, or null when the field says nothing usable.
  ///
  /// **A minus sign is read as a magnitude.** Both of these numbers describe
  /// money going OUT, so a golfer typing `-500` means five hundred down — and
  /// dropping it as "not positive" is the worst possible answer, because the
  /// screen then says nothing and the cap silently never exists. Currency
  /// symbols and separators go the same way: the field is asking for an
  /// amount, not a format.
  static double? _amount(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
    final v = double.tryParse(cleaned);
    return (v != null && v > 0) ? v : null;
  }

  double? get _holeCap => _amount(_capCtrl.text);

  /// The typed caps, ignoring anything blank or not a positive number.
  Map<int, double> get _lossCaps {
    final out = <int, double>{};
    _lossCtrls.forEach((id, c) {
      final v = _amount(c.text);
      if (v != null) out[id] = v;
    });
    return out;
  }

  int get _opponents => (_players.length - 1).clamp(1, 3);

  double get _minBet => _band.start.roundToDouble();
  double get _maxBet => _band.end.roundToDouble();

  String _money(num v) => '\$${v.round()}';

  /// The same climb the server computes, drawn before the game exists. Rungs a
  /// switched-off rule cannot reach are dropped rather than greyed: a ladder
  /// overstating what THIS group can lose is not an argument, it is a scare.
  List<(String, double)> get _ladder {
    final base = _maxBet * _opponents;
    final out = <(String, double)>[('$_opponents opponents at the max', base)];
    var step = base;
    if (_playerDouble) {
      step = base * 2;
      out.add(('All of them double off the tee', step));
    }
    if (_counter) {
      step = step * 2;
      out.add(('Banker counter-doubles', step));
    }
    if (_playerDouble && _par3Triples) {
      step = base * (_counter ? 6 : 3);
      out.add(('On a par 3, tripled instead', step));
    }
    if (_birdieBonus) {
      out.add(('$_opponents birdies against him', step * 2));
    }
    return out;
  }

  /// A flipped tee on the first box, which is how the group would do it.
  ///
  /// **The draw happens HERE, before the reel opens.** The slot machine is a
  /// reveal of a name that already exists, never the source of it — the same
  /// rule the Sixes draw holds to. This one hands somebody three bets on the
  /// first hole, so it has to be auditable rather than theatrical.
  Future<void> _flip() async {
    if (_players.isEmpty) return;
    final winner = Random().nextInt(_players.length);
    final picked = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => BankerDrawScreen(
          names: _players.map((m) => m.player.name).toList(),
          winnerIndex: winner,
        ),
      ),
    );
    if (!mounted || picked == null) return; // backed out — nothing drawn
    setState(() {
      _firstBanker = _players[picked].player.id;
      _flipped = true;
    });
  }

  Future<void> _save() async {
    if (_firstBanker == null) return;
    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.postBankerSetup(
        widget.foursomeId,
        firstBankerId    : _firstBanker!,
        minBet           : _minBet,
        maxBet           : _maxBet,
        handicapMode     : _mode,
        rotationRule     : _rotation,
        allowPlayerDouble: _playerDouble,
        allowCounter: _counter,
        par3Triples: _par3Triples,
        birdieBonus: _birdieBonus,
        holeCapEnabled: _capOn && _holeCap != null,
        holeCapAmount: _capOn ? _holeCap : null,
        lossCaps: _lossCapOn ? _lossCaps : const {},
      );
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      if (rp.round != null) await rp.loadRound(rp.round!.id);
      if (!mounted) return;
      if (widget.returnToHub) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context)
            .pushReplacementNamed('/banker', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Banker')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final bankerName = _players
        .where((m) => m.player.id == _firstBanker)
        .map((m) => m.player.name.split(' ').first)
        .firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Banker')),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed:
                  (_saving || _loading || _firstBanker == null) ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(
                      _editing
                          ? 'Save changes'
                          : bankerName == null
                              ? 'Start'
                              : 'Start — $bankerName banks the 1st',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          if (_error != null) ...[
            ErrorView(message: friendlyError(_error!), onRetry: _save),
            const SizedBox(height: 12),
          ],
          _explainer(),
          const SizedBox(height: 12),
          _bandCard(),
          const SizedBox(height: 12),
          _firstBankerCard(),
          const SizedBox(height: 12),
          _rotationCard(),
          const SizedBox(height: 12),
          _handicapCard(),
          const SizedBox(height: 12),
          _actionCard(),
          const SizedBox(height: 12),
          _exposureCard(),
          const SizedBox(height: 12),
          _lossCapCard(),
        ],
      ),
    );
  }

  /// The round-long companion to the hole cap — and unlike it, **one number
  /// per golfer.**
  ///
  /// The hole cap is a house rule: nobody wants a single hole to reach $1,800.
  /// How much a man is willing to lose over a round is a different question
  /// and it is his own, so four golfers give four answers and one of them
  /// usually says none.
  ///
  /// **A threshold, not a ceiling.** Reaching his number does not forgive a
  /// penny of what he already owes — every bet stands as it was agreed on the
  /// tee, which is what lets this game's receipt name who owes whom for which
  /// hole. What it changes is the rest of the round: floor bets, no doubles,
  /// the counter goes past him, and he cannot take the bank. And it does not
  /// lift again — a cap that switched off when he won a hole back would be a
  /// free option.
  Widget _lossCapCard() {
    return _card(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _head('Cut a golfer off'),
              _blurb('Each golfer sets his own limit. Once he is down that '
                  'much he plays out the round at the minimum with no '
                  'doubles, and cannot take the bank. Nothing he already '
                  'owes changes, and he can still drift past it — slowly.'),
            ],
          ),
        ),
        Switch(
            value: _lossCapOn,
            onChanged: (v) => setState(() => _lossCapOn = v)),
      ]),
      if (_lossCapOn) ...[
        const SizedBox(height: 4),
        for (final m in _players) _lossCapRow(m),
        const SizedBox(height: 10),
        // Sized against the hole, not the round: the two are not proportional,
        // and a cap under one bad hole would fire on the first one.
        Text(
            'A single hole can reach ${_money(_ladder.last.$2)} here. '
            'Leave a golfer blank and he plays without a cap.',
            style: const TextStyle(
                fontSize: 12, height: 1.45, color: Halved.muted)),
        const SizedBox(height: 4),
        const Text(
            'He is cut off for the round once he crosses his own '
            'number — winning back above it does not restore his '
            'doubles.',
            style: TextStyle(fontSize: 12, height: 1.45, color: Halved.muted)),
      ],
    ]);
  }

  Widget _lossCapRow(Membership m) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F5F1))),
      ),
      child: Row(children: [
        Expanded(
          child: Text(m.player.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          width: 118,
          child: TextField(
            controller: _lossCtrls[m.player.id],
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
            textAlign: TextAlign.right,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              prefixText: '\$ ',
              // Blank is the answer most golfers give, so it says so rather
              // than sitting empty and looking unfinished.
              hintText: 'No cap',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            ),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
        ),
      ]),
    );
  }

  // -- pieces ---------------------------------------------------------------

  Widget _card({required List<Widget> children, Color? fill, Color? line}) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: fill ?? Halved.card,
          border: Border.all(color: line ?? Halved.cardBorder),
          borderRadius: BorderRadius.circular(Halved.rCard),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _head(String text) => Text(text,
      style: Halved.body(weight: FontWeight.w700, color: Halved.pine)
          .copyWith(fontSize: 16));

  Widget _blurb(String text) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13, height: 1.45, color: Halved.muted)),
      );

  Widget _explainer() => _card(children: [
        _head(_opponents == 2
            ? 'One against two, every hole'
            : 'One against three, every hole'),
        _blurb('The banker plays each opponent separately. Beat the banker and '
            'he pays you your bet; lose and you pay him. A tie is no action — '
            'nobody pays. He tees off last. Lowest net on the hole takes the '
            'role for the next one.'),
      ]);

  Widget _bandCard() => _card(children: [
        _head('Wager band'),
        _blurb('The floor every opponent must have on the hole, and the '
            'ceiling the banker cannot raise past.'),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: _bandBox('MINIMUM', _minBet)),
          const SizedBox(width: 12),
          Expanded(child: _bandBox('MAXIMUM', _maxBet)),
        ]),
        const SizedBox(height: 6),
        // One track, not two fields: the WIDTH of the band is the decision and
        // two boxes hide it.
        RangeSlider(
          values: _band,
          min: 1,
          max: 100,
          divisions: 99,
          labels: RangeLabels(_money(_minBet), _money(_maxBet)),
          onChanged: (v) => setState(() {
            _band = RangeValues(v.start.roundToDouble(), v.end.roundToDouble());
          }),
        ),
        const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('\$1', style: TextStyle(fontSize: 11, color: Halved.muted)),
          Text('\$25', style: TextStyle(fontSize: 11, color: Halved.muted)),
          Text('\$50', style: TextStyle(fontSize: 11, color: Halved.muted)),
          Text('\$100', style: TextStyle(fontSize: 11, color: Halved.muted)),
        ]),
      ]);

  Widget _bandBox(String label, double value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: Halved.muted)),
          const SizedBox(height: 6),
          Container(
            height: 52,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              border: Border.all(color: Halved.cardBorder),
              borderRadius: BorderRadius.circular(Halved.rChip),
            ),
            child: Row(children: [
              const Text('\$',
                  style: TextStyle(fontSize: 17, color: Halved.muted)),
              const SizedBox(width: 6),
              Text('${value.round()}',
                  style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: Halved.deepPine)),
            ]),
          ),
        ],
      );

  Widget _firstBankerCard() => _card(children: [
        _head('First banker'),
        _blurb(_played
            ? 'The 1st has been banked. Everything else on this screen can '
                'still change.'
            : 'Traditionally a flipped tee on the first box. The app will '
                'draw if you would rather not.'),
        const SizedBox(height: 8),
        for (final m in _players) _bankerRow(m),
        if (!_played) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed:
                    _flipped ? () => setState(() => _flipped = false) : null,
                child: const Text('Group picked'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _flip,
                icon: const Text('🎲', style: TextStyle(fontSize: 14)),
                label: const Text('Flip for it'),
              ),
            ),
          ]),
        ],
      ]);

  Widget _bankerRow(Membership m) {
    final on = m.player.id == _firstBanker;
    return InkWell(
      onTap: _played
          ? null
          : () => setState(() {
                _firstBanker = m.player.id;
                _flipped = false;
              }),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFF1F5F1))),
        ),
        child: Row(children: [
          CircleAvatar(
            radius: 17,
            backgroundColor: on ? _goldFill : Halved.surface,
            // Initials, not `displayShort` — a golfer's short name is
            // user-set and is often a first name, which a 34pt circle cannot
            // hold. The row already carries the full name.
            child: Text(PlayerProfile.computeInitials(m.player.name),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: on ? _gold : Halved.muted)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(m.player.name,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          Text(m.player.displayHandicap,
              style: const TextStyle(fontSize: 13, color: Halved.muted)),
          if (on) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: _goldFill,
                borderRadius: BorderRadius.circular(Halved.rPill),
              ),
              child: const Text('BANKER',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: _gold)),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _rotationCard() => _card(children: [
        _head('Rotation'),
        _blurb('Lowest net on the hole becomes banker for the next one.'),
        const SizedBox(height: 6),
        _radio(
            'ask',
            'The group says who',
            'On a tie the app asks, on the tee, and the group answers — '
                'usually with whoever holed out first. The one thing a phone '
                'cannot see, so it does not guess.'),
        _radio(
            'draw',
            'Tied low scores are drawn',
            'A draw is honest; asking four golfers to remember is not. It '
                'stays changeable until a score is posted.'),
        _radio(
            'keep',
            'Current banker keeps it',
            'Simpler, and it hands the role and the exposure to whoever is '
                'playing best.'),
      ]);

  Widget _radio(String value, String title, String blurb) => InkWell(
        onTap: () => setState(() => _rotation = value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Radio<String>(
              value: value,
              groupValue: _rotation,
              onChanged: (v) => setState(() => _rotation = v!),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(blurb,
                      style: const TextStyle(
                          fontSize: 12.5, height: 1.4, color: Halved.muted)),
                ],
              ),
            ),
          ]),
        ),
      );

  Widget _handicapCard() => _card(children: [
        _head('Handicap'),
        const SizedBox(height: 10),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'strokes_off', label: Text('Strokes Off')),
            ButtonSegment(value: 'net', label: Text('Net')),
            ButtonSegment(value: 'gross', label: Text('Gross')),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _mode = v.first),
        ),
        const SizedBox(height: 8),
        // The correction that changed the shape of this game: strokes come off
        // inside each one-on-one, so the banker holds three relationships on
        // one hole and each opponent holds exactly one.
        _blurb(switch (_mode) {
          'strokes_off' =>
            'Each bet is played off the difference between two handicaps, '
                'allocated by stroke index. The banker can be giving shots in one '
                'bet and taking them in another on the same hole — his card shows '
                'the stroke on each bet rather than on his own score.',
          'net' =>
            'Every golfer plays his own full allocation and the banker has one '
                'net like everyone else. Simpler to read, and further from how the '
                'game is usually played.',
          _ => 'Nobody strokes. For a group playing off scratch.',
        }),
      ]);

  Widget _actionCard() => _card(children: [
        _head('Action'),
        _blurb('Turn any of them off and the game still works — it just gets '
            'quieter.'),
        const SizedBox(height: 4),
        _rule(
            'Player double off the tee',
            'Call it while your ball is in the air. Doubles your bet with the '
                'banker, nobody else\'s.',
            'Before it lands',
            _playerDouble,
            (v) => setState(() => _playerDouble = v)),
        _rule(
            'Banker counter-double',
            'After his own tee shot the banker can double every standing bet '
                'on the hole. He hits last, so he is answering '
                '${_opponents == 2 ? "both" : "all three"} at once.',
            'His shot only',
            _counter,
            (v) => setState(() => _counter = v)),
        _rule(
            'Par 3s triple instead',
            'On a par 3 the airborne call is a triple, not a double. The '
                'counter still doubles what stands.',
            'Par 3 only',
            _par3Triples,
            (v) => setState(() => _par3Triples = v)),
        _rule(
            'Birdie bonus',
            'A player\'s birdie doubles his own payout. It never doubles the '
                'banker\'s collection — a banker who birdies already wins the hole '
                '$_opponents times over.',
            'Pays out only',
            _birdieBonus,
            (v) => setState(() => _birdieBonus = v)),
      ]);

  Widget _rule(String title, String blurb, String tag, bool value,
      ValueChanged<bool> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF1F5F1))),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Flexible(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 14.5, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                // Neutral, not amber. These are SCOPE labels — when the call
                // can be made, which holes it applies to — and amber means the
                // banker's counter. "Before it lands" sitting in the counter's
                // brown on the row about a PLAYER's double is the same
                // collision one screen over.
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDF1EE),
                    borderRadius: BorderRadius.circular(Halved.rPill),
                  ),
                  child: Text(tag,
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: Halved.muted)),
                ),
              ]),
              const SizedBox(height: 3),
              Text(blurb,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.4, color: Halved.muted)),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ]),
    );
  }

  Widget _exposureCard() => _card(
        fill: _goldPanel,
        line: _goldLine,
        children: [
          Text('What a hole can reach',
              style: Halved.body(weight: FontWeight.w700, color: _gold)
                  .copyWith(fontSize: 16)),
          _blurb('The banker faces $_opponents bets at once and both sides can '
              'double them. At a ${_money(_maxBet)} ceiling:'),
          const SizedBox(height: 10),
          for (final (label, amount) in _ladder)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(
                  child: Text(label,
                      style: const TextStyle(
                          fontSize: 13, color: Halved.deepPine)),
                ),
                Text(_money(amount),
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        // The top rung is the one nobody pictures when they
                        // set up a "$50 game".
                        color: amount == _ladder.last.$2
                            ? _amber
                            : Halved.deepPine)),
              ]),
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _goldLine)),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cap the hole',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    SizedBox(height: 3),
                    // Off by default on purpose: a safety rail switched on
                    // without being asked reads as the app deciding the stakes.
                    Text(
                        'One ceiling for the whole hole, all bets and doubles '
                        'included. Not a traditional rule — on if your group '
                        'wants a rail.',
                        style: TextStyle(
                            fontSize: 12.5, height: 1.4, color: Halved.muted)),
                  ],
                ),
              ),
              Switch(
                  value: _capOn, onChanged: (v) => setState(() => _capOn = v)),
            ]),
          ),
          if (_capOn) ...[
            const SizedBox(height: 4),
            Row(children: [
              const Expanded(
                child: Text('Most this hole can cost, all in',
                    style: TextStyle(fontSize: 13, color: Halved.muted)),
              ),
              SizedBox(
                width: 118,
                child: TextField(
                  controller: _capCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: false),
                  textAlign: TextAlign.right,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixText: '\$ ',
                    hintText: 'None',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  ),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ]),
          ],
        ],
      );
}
