/// screens/road_trip_rounds_screen.dart
/// ------------------------------------
/// **Rounds & Side Games** — the trip's rounds, each with the field games the
/// organiser has set on it.
///
/// A trip is the one event shape where the ROUNDS are the thing you navigate:
/// ten courses over ten days, each with its own board, and the question a
/// golfer asks on the bus is "what are we playing today". The tournament card
/// already lists rounds for setting up and scoring; this lists them for
/// reading, and is where the organiser changes what a round plays.
///
/// **Field games, not every game.** The chips here are the games the whole
/// field is ranked on together. A group's own — Skins, Nassau, Wolf — are set
/// and settled by the group on its own screen, and this screen never touches
/// them: the endpoint behind it leaves them exactly where they are.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/section_card.dart';

/// The games a field plays together. **Not the packet's separate Low net and
/// Low gross chips**: this app scores both with ONE game — Stroke Play, whose
/// own setup carries the net/gross switch — so two chips writing the same slug
/// would let a TD pick both and get one. See the handoff note.
///
/// **Ids only; the NAME comes from the catalog.** It used to carry its own
/// labels, which made this file a second place each game is named — and the
/// Hot Spot to Hot Seat rename is exactly what a second place costs, since
/// this copy would have gone on saying Hot Spot with nothing to catch it.
/// `gameDisplayName` falls back to the id, as the old `orElse` did.
///
/// The last four are one competition scored four ways and the sheet lets a TD
/// hold one of them; Stroke Play is an overlay and sits beside any of them.
/// The exclusion is NOT restated here — it is read from the catalog's own
/// `excludes` through `applyGameToggle`, so this list says what is offered and
/// the catalog says what combines.
const kRoadTripFieldGames = <String>[
  GameIds.strokePlay,
  GameIds.betterBall,
  GameIds.irishRumble,
  GameIds.hotSpot,
  GameIds.fortyBalls,
];

String kFieldGameLabel(String id) => gameDisplayName(id);

/// The offered games that exclude at least one OTHER offered game — i.e. the
/// one-pool family, derived rather than listed so the sheet's copy cannot go
/// stale when a game joins. Stroke Play is an overlay and excludes none of
/// them, so it falls out on its own.
List<String> get kOnePoolFieldGames => kRoadTripFieldGames
    .where((a) => kRoadTripFieldGames.any((b) => !gamesCompatible(a, b)))
    .toList();

class RoadTripRoundsScreen extends StatefulWidget {
  final int    tournamentId;
  final String tournamentName;

  const RoadTripRoundsScreen({
    super.key,
    required this.tournamentId,
    required this.tournamentName,
  });

  @override
  State<RoadTripRoundsScreen> createState() => _RoadTripRoundsScreenState();
}

class _RoadTripRoundsScreenState extends State<RoadTripRoundsScreen> {
  Tournament? _tournament;
  bool    _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final list   = await client.getTournaments();
      if (!mounted) return;
      setState(() {
        _tournament = list.firstWhere((t) => t.id == widget.tournamentId,
            orElse: () => list.first);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rounds = _tournament?.rounds ?? const <RoundSummary>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Rounds & Side Games')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(message: friendlyError(_error!), onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                    itemCount: rounds.length,
                    itemBuilder: (_, i) => _RoundCard(
                      round: rounds[i],
                      onEdit: () => _editGames(rounds[i]),
                    ),
                  ),
                ),
    );
  }

  Future<void> _editGames(RoundSummary round) async {
    final current = round.activeGames
        .where(kRoadTripFieldGames.contains)
        .toList();
    final picked = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _FieldGamesSheet(
        roundNumber: round.roundNumber,
        course     : round.courseName,
        initial    : current,
      ),
    );
    if (picked == null || !mounted) return;
    try {
      await context.read<AuthProvider>().client
          .setRoundFieldGames(round.id, picked);
      if (!mounted) return;
      // The round hub reads `active_games`, so anything holding this round
      // has to re-read rather than keep the list it was drawn from. Reloading
      // here is what makes the chips on this screen agree with it.
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendlyError(e)),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }
}

class _RoundCard extends StatelessWidget {
  final RoundSummary round;
  final VoidCallback onEdit;
  const _RoundCard({required this.round, required this.onEdit});

  bool get _complete => round.status == 'complete';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final games = round.activeGames
        .where(kRoadTripFieldGames.contains)
        .map(kFieldGameLabel)
        .toList();
    return SectionCard(
      title: 'R${round.roundNumber} · ${round.courseName}',
      trailing: _StateTag(status: round.status),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          games.isEmpty ? 'No field games' : games.join(' · '),
          style: theme.textTheme.bodyMedium?.copyWith(
              color: games.isEmpty
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface),
        ),
        const SizedBox(height: 6),
        if (_complete)
          // **Said, not just disabled.** A button that has quietly gone grey
          // reads as a fault; the rule is that the results have been read.
          Text('Round complete. Side games are final.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant))
        else
          Row(children: [
            Expanded(
              child: Text(
                'Side games can change any time before or during the round.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            TextButton(onPressed: onEdit, child: const Text('Edit')),
          ]),
      ]),
    );
  }
}

class _StateTag extends StatelessWidget {
  final String status;
  const _StateTag({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, colour) = switch (status) {
      'complete'    => ('Played',   theme.colorScheme.onSurfaceVariant),
      'in_progress' => ('Today',    theme.colorScheme.primary),
      _             => ('Upcoming', theme.colorScheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: colour),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: colour, fontWeight: FontWeight.w600)),
    );
  }
}

/// The edit sheet. **Save is dead until something changes** — a live Save on
/// an untouched sheet invites a write that says nothing and posts a chat
/// message about it.
String _listOf(List<String> ids) {
  final names = ids.map(gameDisplayName).toList();
  if (names.length < 2) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

class _FieldGamesSheet extends StatefulWidget {
  final int          roundNumber;
  final String       course;
  final List<String> initial;

  const _FieldGamesSheet({
    required this.roundNumber,
    required this.course,
    required this.initial,
  });

  @override
  State<_FieldGamesSheet> createState() => _FieldGamesSheetState();
}

class _FieldGamesSheetState extends State<_FieldGamesSheet> {
  late Set<String> _picked = widget.initial.toSet();

  bool get _changed =>
      _picked.length != widget.initial.length ||
      !_picked.containsAll(widget.initial);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Side games · R${widget.roundNumber} ${widget.course}',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            "Field games for this round only. The trip championship isn't "
            'affected.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final id in kRoadTripFieldGames)
              FilterChip(
                selected: _picked.contains(id),
                // **Turning one on turns an incompatible one off**, rather
                // than greying it out — the same call the new-round wizard
                // makes, and through the same shared function so the two
                // cannot drift. A TD who taps the second of two games that
                // rank the same groups has changed his mind, not made a
                // mistake to be blocked. The server refuses the pair too.
                onSelected: (v) => setState(() {
                  _picked = applyGameToggle(_picked, id, v);
                }),
                label: Text(kFieldGameLabel(id)),
              ),
          ]),
          const SizedBox(height: 14),
          Text(
            '${_listOf(kOnePoolFieldGames)} all rank the same groups, so '
            'picking one clears the others. '
            '${gameDisplayName(GameIds.strokePlay)} sits beside any of them.\n'
            'Adding a game mid-round scores it from hole 1 using the scores '
            'already entered. The group is told about any change.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant, height: 1.45),
          ),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _changed
                  ? () => Navigator.of(context).pop(_picked.toList())
                  : null,
              child: const Text('Save'),
            ),
          ]),
        ]),
    );
  }
}
