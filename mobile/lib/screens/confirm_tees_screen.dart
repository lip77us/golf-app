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
      // Only send rows that actually changed — keeps the payload small
      // and avoids touching memberships we don't need to.
      final payload = <Map<String, int>>[];
      for (final m in _members) {
        final pick = _picks[m.player.id];
        if (pick == null || pick == 0) continue;
        if (pick == m.tee?.id) continue;
        payload.add({'player_id': m.player.id, 'tee_id': pick});
      }
      if (payload.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No changes.')),
        );
        Navigator.of(context).pop(false);
        return;
      }
      await client.patchFoursomeTees(widget.foursomeId, tees: payload);
      // Re-fetch the round so the foursome's memberships pick up the
      // new tees + handicaps the server just recomputed.
      final rp = context.read<RoundProvider>();
      if (rp.round != null) {
        await rp.loadRound(rp.round!.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(
            'Updated ${payload.length} player'
            '${payload.length == 1 ? '' : 's'}.')),
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
      appBar: AppBar(title: const Text('Edit Tee Boxes')),
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
                        : const Text('Save Tees',
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
          'stroke allocations recompute automatically.  Tees can\'t be '
          'changed once any hole is scored.',
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant),
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
        ),
      ],
    );
  }
}
