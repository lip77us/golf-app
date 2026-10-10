/// Change a round's side games after it exists.
///
/// **Side games belong to the ROUND, not the tournament**, and a tournament's
/// rounds often play different ones. Round 1's were set once inside the create
/// wizard and then unreachable; every later round got its own screen at setup
/// and no way back. This is the way back, for any of them.
///
/// It draws the same `SideGamesPicker` as the wizard and the later-round
/// setup screen, so all three show the same games and say the same things
/// about them.
///
/// **On the final round it also carries the day bet**, which is not an
/// `active_games` game but is a side game by every reading a TD has. It used
/// to be reachable only through its own setup screen, where the way to turn
/// one off was an action under the Save button — so a TD who wanted no day bet
/// went looking for a switch and found none. Its switch acts at once rather
/// than on Save, because it is its own resource; the card says so.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/side_games_picker.dart';

class RoundSideGamesScreen extends StatefulWidget {
  final int roundId;
  const RoundSideGamesScreen({super.key, required this.roundId});

  @override
  State<RoundSideGamesScreen> createState() => _RoundSideGamesScreenState();
}

class _RoundSideGamesScreenState extends State<RoundSideGamesScreen> {
  late Set<String> _selected;
  late Set<String> _initial;
  bool _saving = false;
  Object? _error;

  /// Null until the day bet's own config has been read, and null forever on a
  /// round that cannot have one — the picker draws no card in either case,
  /// so a slow fetch shows nothing rather than a switch that flips itself.
  ///
  /// **It behaves exactly like the switches above it**: moved here, saved on
  /// Save, and nothing it does is special. The only thing that makes the day
  /// bet different is that it appears on the final round of a multi-round
  /// event and nowhere else. An earlier pass had its switch write at once and
  /// open the setup screen on the way on, which made it a second kind of
  /// switch on one screen and needed a sentence on the card to explain
  /// itself. Its fee and prizes are set from the hub's Configure button, the
  /// same way Hot Spot's and Better Ball's are.
  bool? _dayBetOn;
  bool? _dayBetInitial;
  String? _dayBetNote;

  @override
  void initState() {
    super.initState();
    final round = context.read<RoundProvider>().round;
    _initial = {...?round?.activeGames};
    _selected = {..._initial};
    if (round?.isFinalRound ?? false) _loadDayBet();
  }

  Future<void> _loadDayBet() async {
    try {
      final cfg = await context
          .read<AuthProvider>()
          .client
          .getDayBetSetup(widget.roundId);
      if (!mounted) return;
      // The server knows more than "is this the last round" — it also wants a
      // tournament and more than one round. Its own answer wins, so an
      // ineligible round draws no card instead of a switch that would 400.
      if (cfg['eligible'] != true) {
        setState(() {
          _dayBetOn = null;
          _dayBetInitial = null;
        });
        return;
      }
      final on = cfg['configured'] == true;
      final fee = (cfg['entry_fee'] as num?)?.toDouble() ?? 0;
      // A payout is {place, amount}, not a number.
      final payouts = (cfg['payouts'] as List?) ?? const [];
      final first = payouts.isEmpty
          ? 0.0
          : ((payouts.first as Map)['amount'] as num?)?.toDouble() ?? 0.0;
      setState(() {
        _dayBetOn = on;
        _dayBetInitial = on;
        // On but worth nothing is a real state — it is what a game looks like
        // between being switched on and being configured — so the note says
        // where to put the numbers rather than showing a bet for $0.
        _dayBetNote = !on
            ? null
            : fee > 0
                ? '\$${fee.toStringAsFixed(0)} a golfer, '
                    '\$${first.toStringAsFixed(0)} to the winner.'
                : 'Set the entry fee and prizes with Configure Day bet on '
                    'the round.';
      });
    } catch (_) {
      // A round that cannot have one, or a fetch that failed: either way no
      // card, rather than a switch whose position is a guess.
      if (mounted) {
        setState(() {
          _dayBetOn = null;
          _dayBetInitial = null;
        });
      }
    }
  }

  /// The day bet is in here with the games, so one Save covers the lot and a
  /// TD never has two kinds of pending change on one screen.
  bool get _dirty =>
      _selected.length != _initial.length ||
      !_selected.every(_initial.contains) ||
      _dayBetOn != _dayBetInitial;

  /// Turning a game OFF does not delete what it has scored — the config and
  /// its results stay, and turning it back on shows them again. Said out
  /// loud, because "remove" on a round that is being played is the reading
  /// a TD would otherwise reach for.
  ///
  /// The day bet is the one exception, and only because its existence IS its
  /// on switch: there is no `active` flag to clear, so off means the config
  /// goes and its fee and prizes go with it. Nothing scored is touched — the
  /// standings derive from the round — and the footer says so.
  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rp = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      await client.updateRound(
        widget.roundId,
        activeGames: _selected.toList(),
      );
      // The day bet is its own config rather than an `active_games` entry, so
      // it needs its own call — but it is made HERE, with the others, so the
      // switch behaves like the switches beside it.
      //
      // Only on a change: a day bet already set up and left alone must not be
      // re-posted, or a TD who toggled it off and back on in one visit would
      // have his $4 and $20 replaced by the blank defaults.
      if (_dayBetOn != _dayBetInitial) {
        if (_dayBetOn == true) {
          // On, worth nothing yet — exactly what a game looks like between
          // being switched on and being configured. The numbers come from the
          // hub's Configure Day bet button.
          await client.postDayBetSetup(widget.roundId,
              entryFee: 0, payouts: const []);
        } else {
          // Its existence IS its on switch, so off means gone. The fee and
          // prizes do not survive it; nothing scored is touched, because the
          // standings derive from the round.
          await client.deleteDayBetSetup(widget.roundId);
        }
      }
      if (!mounted) return;
      await rp.loadRound(widget.roundId);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final round = context.watch<RoundProvider>().round;
    final multi = (round?.foursomes.length ?? 0) > 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(round?.roundNumber == null
            ? 'Side games'
            : 'Round ${round!.roundNumber} side games'),
      ),
      body: Column(children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'The side games for this round only. Each round has its own, '
                'and they are often different.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              SideGamesPicker(
                selected: _selected,
                multiFoursome: multi,
                onToggle: (id, on) => setState(() {
                  on ? _selected.add(id) : _selected.remove(id);
                }),
                dayBetOn: _dayBetOn,
                onDayBetToggle: _dayBetOn == null
                    ? null
                    : (on) => setState(() => _dayBetOn = on),
                dayBetNote: _dayBetNote,
              ),
              const SizedBox(height: 16),
              Text(
                'Turning a game off leaves its setup and anything it has '
                'scored in place — turn it back on and they are still there. '
                'The day bet is the exception: its entry fee and prizes are '
                'the config, so turning it off forgets them. Nothing scored '
                'is lost either way.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (_error != null && !_saving) ...[
                const SizedBox(height: 16),
                ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _save,
                ),
              ],
              const SizedBox(height: 80),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_saving || !_dirty) ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(_dirty ? 'Save' : 'No changes'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
