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
  bool? _dayBetOn;
  String? _dayBetNote;
  bool _dayBetBusy = false;

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
        if (mounted) setState(() => _dayBetOn = null);
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
        _dayBetNote = on
            ? '\$${fee.toStringAsFixed(0)} a golfer, '
                '\$${first.toStringAsFixed(0)} to the winner. '
                'This switch saves as soon as you change it.'
            : null;
      });
    } catch (_) {
      // A round that cannot have one, or a fetch that failed: either way no
      // card, rather than a switch whose position is a guess.
      if (mounted) setState(() => _dayBetOn = null);
    }
  }

  /// ON needs an entry fee and a prize table, so it opens the setup screen
  /// and re-reads whatever came back — a switch cannot invent a stake. OFF
  /// deletes the config, which asks first, because the standings it was
  /// paying are derived from the round's scores and nothing played is lost
  /// but the money is.
  Future<void> _toggleDayBet(bool on) async {
    if (_dayBetBusy) return;
    if (on) {
      await Navigator.of(context)
          .pushNamed('/day-bet-setup', arguments: widget.roundId);
      if (mounted) await _loadDayBet();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Turn off the day bet?'),
        content: const Text(
            'The entry fee and prizes are removed and nobody is charged. '
            'Nothing scored is lost — the standings come from the round, so '
            'turning it back on rebuilds them.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Keep it')),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Turn off')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _dayBetBusy = true);
    try {
      await context
          .read<AuthProvider>()
          .client
          .deleteDayBetSetup(widget.roundId);
      if (!mounted) return;
      setState(() {
        _dayBetOn = false;
        _dayBetNote = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _dayBetBusy = false);
    }
  }

  bool get _dirty =>
      _selected.length != _initial.length ||
      !_selected.every(_initial.contains);

  /// Turning a game OFF does not delete what it has scored — the config and
  /// its results stay, and turning it back on shows them again. Said out
  /// loud, because "remove" on a round that is being played is the reading
  /// a TD would otherwise reach for.
  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final rp = context.read<RoundProvider>();
      await context.read<AuthProvider>().client.updateRound(
            widget.roundId,
            activeGames: _selected.toList(),
          );
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
                onDayBetToggle: _dayBetOn == null ? null : _toggleDayBet,
                dayBetNote: _dayBetNote,
              ),
              const SizedBox(height: 16),
              Text(
                'Turning a game off leaves its setup and anything it has '
                'scored in place — turn it back on and they are still there.',
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
