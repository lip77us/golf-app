/// sequoya_threes_setup_screen.dart
///
/// Sequoya 3s setup
/// (docs/design-review/handoff-sequoya-threes/README.md, screen 1).
///
/// **The group sets match 1 and nothing else about the rotation.** Four
/// golfers split 2v2 in exactly three ways and there is no fourth, so matches
/// 2 and 3 are the other two and 4-6 repeat them. A group that does not know
/// that will expect a second draw at the turn, which is why the screen says so
/// before the teams rather than after.
///
/// There are no format options beyond the handicap — no Classic vs High-Low,
/// no allocation choice. Strokes fall by full course stroke index.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/stake_field.dart';
import '../widgets/team_splitter_4.dart';

class SequoyaThreesSetupScreen extends StatefulWidget {
  const SequoyaThreesSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  final int  foursomeId;
  final bool returnToHub;

  @override
  State<SequoyaThreesSetupScreen> createState() =>
      _SequoyaThreesSetupScreenState();
}

class _SequoyaThreesSetupScreenState extends State<SequoyaThreesSetupScreen> {
  static const _blue   = Color(0xFF1976D2);
  static const _orange = Color(0xFFEF6C00);

  List<Membership> _ordered = [];
  String _mode       = 'net';
  int    _netPercent = 100;
  String _pressMode  = 'auto';      // the packet's default
  final _betCtrl     = TextEditingController(text: '5.00');
  bool   _stakeOk    = true;
  bool   _saving     = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    _ordered = fs?.realPlayers.toList() ?? [];
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  double get _stake => double.tryParse(_betCtrl.text.trim()) ?? 0;

  /// Six matches, and the ceiling depends only on how many bets each can carry.
  int get _betsPerMatch => switch (_pressMode) {
        'none'        => 1,
        'manual_auto' => 3,
        _             => 2,
      };

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  Future<void> _save() async {
    if (_ordered.length != 4 || !_stakeOk) return;
    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.postSequoyaThreesSetup(
        widget.foursomeId,
        // Side 1 of match 1; every other pairing derives from it.
        side1PlayerIds: _ordered.take(2).map((m) => m.player.id).toList(),
        handicapMode:   _mode,
        netPercent:     _netPercent,
        betAmount:      _betCtrl.text.trim(),
        pressMode:      _pressMode,
      );
      final rp = context.read<RoundProvider>();
      if (rp.round != null) await rp.loadRound(rp.round!.id);
      if (!mounted) return;
      if (widget.returnToHub) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pushReplacementNamed(
          '/sequoya-threes', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sequoya 3s')),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: FilledButton(
              onPressed: (_saving || _ordered.length != 4 || !_stakeOk)
                  ? null : _save,
              child: _saving
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Start Match 1',
                      style: TextStyle(fontSize: 16,
                                       fontWeight: FontWeight.bold)),
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

          // Said BEFORE the teams: a group that does not know matches 2-6 are
          // already decided will stand on the 4th tee expecting another draw.
          _Card(
            title: 'Six matches, three holes each',
            child: Text(
              'You only set match 1. Four golfers split two-a-side in exactly '
              'three ways, so matches 2 and 3 are the other two pairings and '
              'matches 4–6 repeat all three in the same order. Everyone '
              'partners everyone else exactly twice.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant, height: 1.5),
            ),
          ),
          const SizedBox(height: 12),

          _Card(
            title: 'Match 1 · Holes 1–3',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              // Side 1 / Side 2, not Team A / Team B: the pairings rotate every
              // third hole, so a side is a side for THIS match only. The play
              // screen uses the same words.
              TeamSplitter4(
                players:   _ordered,
                onChanged: (o) => setState(() => _ordered = o),
                teamALabel: 'Side 1',
                teamBLabel: 'Side 2',
                teamAColor: _blue,
                teamBColor: _orange,
              ),
              const SizedBox(height: 8),
              Text(
                'Drag to set the first two teams. The convention is the two '
                'long drives against the two short ones.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          ),
          const SizedBox(height: 12),

          HandicapModeSelector(
            mode: _mode,
            netPercent: _netPercent,
            onModeChanged: (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),
          const SizedBox(height: 12),

          _Card(
            title: 'Presses',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(
                'A press is a new bet at the same amount — not a doubling. It '
                'runs over the holes left in that match and settles on its '
                'own, so it can be halved while the match is won, or won by '
                'the side that lost it.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final o in const [
                  ('none',        'None'),
                  ('auto',        'Auto after 1st hole win'),
                  ('manual_auto', 'Manual + Auto'),
                ])
                  ChoiceChip(
                    label: Text(o.$2),
                    selected: _pressMode == o.$1,
                    onSelected: (_) => setState(() => _pressMode = o.$1),
                  ),
              ]),
              const Divider(height: 22),
              Row(children: [
                Expanded(
                  child: Text('Bets a single match can carry',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                Text('$_betsPerMatch',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ]),
            ]),
          ),
          const SizedBox(height: 12),

          _Card(
            title: 'Stake',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('A man a match, not a pair. Lose a match and you are down '
                   'the stake and so is your partner.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 10),
              StakeField(
                controller: _betCtrl,
                onChanged: (ok) => setState(() => _stakeOk = ok),
                label: 'Stake (\$ per man, per bet)',
              ),
            ]),
          ),
          const SizedBox(height: 12),

          // The ceiling, stated in money rather than in rules.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('🛡  '),
            Expanded(
              child: Text(
                'Most you can lose: ${_money(_stake * 6 * _betsPerMatch)} — '
                'all six matches lost with every bet live. No presses at all '
                'tops out at ${_money(_stake * 6)}; Manual + Auto raises the '
                'ceiling to ${_money(_stake * 18)}.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary)),
          const SizedBox(height: 8),
          child,
        ]),
      ),
    );
  }
}
