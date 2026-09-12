/// screens/confirm_tees_screen.dart
///
/// Reassigns each player's tee for a foursome.  Use case: at round
/// setup the captain didn't know which tee a player preferred, so they
/// picked a default.  Before the first hole is scored, anyone can pop
/// in here and confirm or correct the choices.
///
/// **It is no longer setup-only.** Inside the edit ceiling — the first three
/// scored holes, and none at all in a Banker round — a wrong tee or a wrong
/// forced handicap can still be corrected, and the server RESCORES the holes
/// already played rather than leaving the round scored under two different
/// allocations. Past the ceiling it refuses, and says which rule it is.
///
/// Because money can move under a group that is looking at it, a save that
/// rescored anything reports how many holes it touched and offers one step of
/// Undo. That step is replaced by the next edit, so a standing one is shown
/// BEFORE a second save rather than after it — discovering that the first
/// change is now unreachable is no use once it is.

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

  /// What a standing undo would put back — '' when there is none. Shown while
  /// the user is deciding on a SECOND edit, because that is the one that makes
  /// the first permanent.
  String _undoNote = '';

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

      // Best-effort: a round that has never been edited has nothing to report,
      // and a screen that cannot open because of a banner is worse than a
      // screen with no banner.
      try {
        final undo = await client.getFoursomeSetupUndo(widget.foursomeId);
        _undoNote = (undo['available'] == true)
            ? (undo['note'] as String? ?? '') : '';
      } catch (_) {
        _undoNote = '';
      }

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

  /// Put the last change back — scores, strokes and setting together.
  ///
  /// Takes the ids rather than reading them off `context`, because by the time
  /// the Undo action is tapped this screen has popped and its context is
  /// dead. The round provider is captured for the same reason.
  Future<void> _undo(int foursomeId, RoundProvider rp) async {
    final messenger = ScaffoldMessenger.of(context);
    final client    = context.read<AuthProvider>().client;
    try {
      final resp = await client.undoFoursomeSetup(foursomeId);
      if (rp.round != null) await rp.loadRound(rp.round!.id);
      final what = (resp['undone'] as String? ?? '').trim();
      messenger.showSnackBar(SnackBar(
          content: Text(what.isEmpty ? 'Change undone.'
                                     : 'Undone — $what')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not undo: $e')));
    }
  }

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
      // Captured BEFORE the await — after it this screen may be gone, and the
      // Undo action in the snackbar outlives the screen entirely.
      final rp = context.read<RoundProvider>();
      final resp = await client.patchFoursomeTees(widget.foursomeId,
                                                  tees: payload,
                                                  handicaps: hcaps);
      // Re-fetch the round so the foursome's memberships pick up the
      // new tees + handicaps the server just recomputed.
      if (rp.round != null) {
        await rp.loadRound(rp.round!.id);
      }
      if (!mounted) return;
      final touched = {...payload.map((e) => e['player_id']),
                       ...hcaps.map((e) => e['player_id'])}.length;
      final rescored = (resp['holes_rescored'] as int?) ?? 0;

      // A save that only moved a setting gets the old line. A save that
      // rewrote scored holes has to SAY so — the money can have moved on a
      // board somebody is looking at — and hand back the way out.
      ScaffoldMessenger.of(context).showSnackBar(
        rescored > 0
            ? SnackBar(
                duration: const Duration(seconds: 8),
                content: Text(
                    'Updated $touched player${touched == 1 ? '' : 's'} · '
                    '$rescored hole${rescored == 1 ? '' : 's'} rescored'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _undo(widget.foursomeId, rp),
                ),
              )
            : SnackBar(content: Text(
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
      // Room to scroll the last row clear of the keyboard. The Done bar and the
      // tap-outside dismissal are the way OUT; this is what makes the field you
      // are typing in reachable in the first place, on a screen whose rows run
      // to the bottom edge.
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      children: [
        Text(
          'Pick the tee each player will play.  Course handicaps and '
          'stroke allocations recompute automatically.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Text(
          'Both re-net every hole already played, so they can only be '
          'corrected through the first three holes — after that, start a new '
          'match with the same golfers.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic),
        ),
        // A change is already standing, and saving again would replace the way
        // back to it. Said HERE, above the controls, because after the second
        // save it is no longer useful information.
        if (_undoNote.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.history, size: 18,
                   color: theme.colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Last change: $_undoNote\nSaving again replaces it — you '
                  'can only step back once.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
              TextButton(
                onPressed: _saving ? null : () async {
                  await _undo(widget.foursomeId,
                              context.read<RoundProvider>());
                  if (mounted) _load();
                },
                child: const Text('Undo'),
              ),
            ]),
          ),
        ],
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
