/// screens/confirm_tees_screen.dart
///
/// Reassigns each player's tee for a foursome.  Use case: at round
/// setup the captain didn't know which tee a player preferred, so they
/// picked a default.  Before the first hole is scored, anyone can pop
/// in here and confirm or correct the choices.
///
/// Server refuses the change if any hole has already been scored.
/// We additionally hide the entry point on the Round screen once
/// scoring starts, so the user shouldn't normally see the error.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/tee_assignment.dart';

/// The tee rows a save should send.
///
/// **Every row with a tee, not only the ones the user moved.** Skipping
/// unchanged rows looks like an obvious optimisation — a foursome is four rows,
/// so it buys nothing — and it broke the one job this screen uniquely does:
/// `PATCH /foursomes/{id}/tees/` is the ONLY place a membership's course and
/// playing handicap are recomputed from the golfer's index, and the change that
/// makes a recompute necessary happens somewhere else entirely, in My Golfers.
/// A TD who corrected an index there, came here and pressed Save got
/// "No changes." and an untouched handicap; the workaround was to change a tee
/// and change it back, which dirties the row twice and recomputes on the way.
///
/// A row with no tee selected is still skipped — there is nothing to assign.
List<Map<String, int>> buildTeePayload(
    List<Membership> members, Map<int, int> picks) {
  final out = <Map<String, int>>[];
  for (final m in members) {
    final pick = picks[m.player.id] ?? m.tee?.id;
    if (pick == null || pick == 0) continue;
    out.add({'player_id': m.player.id, 'tee_id': pick});
  }
  return out;
}


class ConfirmTeesScreen extends StatefulWidget {
  final int foursomeId;
  const ConfirmTeesScreen({super.key, required this.foursomeId});

  @override
  State<ConfirmTeesScreen> createState() => _ConfirmTeesScreenState();
}

class _ConfirmTeesScreenState extends State<ConfirmTeesScreen> {
  bool       _loading = true;
  bool       _saving  = false;
  Object?    _error;
  List<TeeInfo>     _tees    = [];
  List<Membership>  _members = [];
  /// Working state: player id → currently-selected tee id.
  final Map<int, int> _picks = {};
  /// player id → the forced playing handicap being typed. Empty string means
  /// "computed" — the field is blank and the golfer plays off his index.
  final Map<int, TextEditingController> _hcaps = {};
  /// Whether the forced-handicap fields are showing.
  ///
  /// Off by default: matching an externally-managed card is the exception,
  /// and a per-golfer handicap box on every round setup is both noise and an
  /// invitation to type in one by accident. It comes up ON whenever a golfer
  /// already carries one, because a forced handicap that cannot be seen is
  /// the reason nobody can explain a golfer's strokes.
  bool _forceHcaps = false;

  @override
  void dispose() {
    for (final c in _hcaps.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      // Resolve the foursome (and its course) from the round provider so
      // we don't have to re-fetch.  If for any reason it's not loaded,
      // the dropdown list will be empty and the user can back out.
      final round = context.read<RoundProvider>().round;
      final fs    = round?.foursomes
          .where((f) => f.id == widget.foursomeId)
          .firstOrNull;
      if (fs == null) {
        throw Exception('Foursome not found on the loaded round.');
      }
      _members = fs.realPlayers.toList();
      for (final m in _members) {
        _hcaps[m.player.id] = TextEditingController(
            text: m.playingHandicapOverride?.toString() ?? '');
      }
      _forceHcaps = _members.any((m) => m.playingHandicapOverride != null);
      // Fetch the tees at THIS foursome's course (scorer-accessible — sourced
      // from the round's course, not the viewer's account, so a cross-account
      // scorer doesn't get an empty dropdown).
      _tees = await client.getFoursomeCourseTees(widget.foursomeId);

      // Seed _picks with each player's current tee (or first available
      // tee that matches their sex if for some reason they don't have
      // one yet).
      for (final m in _members) {
        final cur = m.tee?.id;
        if (cur != null && _tees.any((t) => t.id == cur)) {
          _picks[m.player.id] = cur;
        } else {
          final fallback = _teesForPlayer(m.player).firstOrNull?.id ?? 0;
          _picks[m.player.id] = fallback;
        }
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  /// Tees this player can play — matches their sex, plus any unisex.
  List<TeeInfo> _teesForPlayer(PlayerProfile p) => teesForPlayer(_tees, p);

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      // Every row, not only the moved ones — see buildTeePayload.
      final payload = buildTeePayload(_members, _picks);

      // Forced handicaps — only the ones that actually moved. A blank field
      // clears the override, which is a real change and must be sent as an
      // explicit null rather than skipped.
      final hcaps = <Map<String, dynamic>>[];
      for (final m in _members) {
        final typed = (_hcaps[m.player.id]?.text ?? '').trim();
        final now   = typed.isEmpty ? null : int.tryParse(typed);
        if (typed.isNotEmpty && now == null) {
          throw Exception('"$typed" is not a whole number — '
                          '${m.player.name}\'s handicap.');
        }
        if (now == m.playingHandicapOverride) continue;
        hcaps.add({'player_id': m.player.id,
                   'playing_handicap_override': now});
      }

      if (payload.isEmpty && hcaps.isEmpty) {
        // Only reachable when nobody has a tee at all.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nothing to save — no tees selected.')),
        );
        Navigator.of(context).pop(false);
        return;
      }
      await client.patchFoursomeTees(widget.foursomeId,
                                     tees: payload, handicaps: hcaps);
      // Re-fetch the round so the foursome's memberships pick up the
      // new tees + handicaps the server just recomputed.
      final rp = context.read<RoundProvider>();
      if (rp.round != null) {
        await rp.loadRound(rp.round!.id);
      }
      if (!mounted) return;
      final touched = {...payload.map((e) => e['player_id']),
                       ...hcaps.map((e) => e['player_id'])}.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
            'Updated $touched player${touched == 1 ? '' : 's'}.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tees & Handicaps')),
      body: _buildBody(),
      bottomNavigationBar: (_loading || _error != null)
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Save',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorView(
        message:   friendlyError(_error!),
        isNetwork: isNetworkError(_error!),
        onRetry:   _load,
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Pick the tee each player will play.  Course handicaps and '
          'stroke allocations recompute automatically.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Text(
          'Neither tees nor handicaps can change once a hole is scored — both '
          're-net every hole already played.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 8),
        // The switch, not the fields, is what most rounds see: a forced
        // handicap is for a card somebody else manages, which is the
        // exception.
        Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
          child: Column(children: [
            SwitchListTile(
              value: _forceHcaps,
              onChanged: _toggleForceHcaps,
              dense: true,
              title: const Text('Set playing handicaps by hand',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                _forceHcaps
                    ? 'Type a card\'s number beside a golfer. Blank still '
                      'computes his.'
                    : 'Every golfer plays off his index.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            if (_forceHcaps)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Playing a card someone else manages — Golf Genius, a club '
                  'sheet? Type that card\'s playing handicap beside a golfer '
                  'and Halved uses it exactly, ignoring their index and '
                  'applying no allowance on top.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        TeeAssignmentList(
          players:   _members.map((m) => m.player).toList(),
          tees:      _tees,
          picks:     _picks,
          onChanged: (pid, id) => setState(() => _picks[pid] = id),
          subtitle:  (p) {
            final m = _members.firstWhere((m) => m.player.id == p.id);
            return 'Course Hcp ${m.courseHandicap}'
                '  ·  Playing ${m.playingHandicap}';
          },
          trailing:  _forceHcaps ? _handicapField : null,
        ),
      ],
    );
  }

  /// Turning the switch OFF clears every field, and Save then sends those
  /// clears through. A switch that said "off" while forced handicaps stayed
  /// in force would be worse than no switch — the numbers empty on screen, so
  /// what is about to be saved is what is shown.
  void _toggleForceHcaps(bool on) {
    setState(() {
      _forceHcaps = on;
      if (!on) {
        for (final c in _hcaps.values) {
          c.clear();
        }
      }
    });
  }

  /// The forced-handicap field for one golfer.
  ///
  /// Blank is a meaningful value — it means "compute it" — so the field is
  /// never pre-filled with the computed number. Showing it there would make a
  /// computed handicap indistinguishable from a forced one that happens to
  /// match, and every golfer would look overridden.
  Widget _handicapField(PlayerProfile p) {
    final theme = Theme.of(context);
    final ctrl  = _hcaps[p.id];
    if (ctrl == null) return const SizedBox.shrink();
    final forced = ctrl.text.trim().isNotEmpty;
    return Row(children: [
      SizedBox(
        // Wide enough for the floating label — at 96 it clipped to "Playin…",
        // which reads as a broken field rather than a narrow one.
        width: 124,
        child: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          decoration: const InputDecoration(
            labelText: 'Playing hcp',
            hintText:  'auto',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          forced
              ? 'Forced — index ignored, no allowance applied'
              : 'From ${p.name.split(' ').first}\'s index',
          style: theme.textTheme.bodySmall?.copyWith(
            color: forced
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: forced ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    ]);
  }
}
