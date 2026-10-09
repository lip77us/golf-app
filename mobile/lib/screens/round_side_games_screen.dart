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

  @override
  void initState() {
    super.initState();
    final round = context.read<RoundProvider>().round;
    _initial = {...?round?.activeGames};
    _selected = {..._initial};
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
