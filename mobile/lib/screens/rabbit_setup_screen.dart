/// screens/rabbit_setup_screen.dart
/// --------------------------------
/// Setup screen for the Rabbit casual game (exactly 3 real players).
///
/// Knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + net percentage.
///   • Accumulate vs Stop: in Accumulate the rabbit builds a lead and is
///     lost only when the lead hits 0; in Stop it's lost on the first hole
///     the rabbit is beaten.
///   • Segments: one 18-hole match, two 9-hole matches, or three 6-hole
///     matches — the rabbit resets each segment and the holder at the end
///     wins that share of the pot.
///   • Stake (the pot).
///
/// Entry is gated to a 3-player foursome (the casual picker enforces it; we
/// re-check here against a direct route push or roster change).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/stake_field.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/handicap_mode_selector.dart';

class RabbitSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation or the launch
  /// page's "Edit Configuration" action: it stays on the form even when the
  /// game is already configured (instead of bouncing to score entry), and
  /// returns to the /round launch page on save instead of jumping to scoring.
  final bool returnToHub;

  const RabbitSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<RabbitSetupScreen> createState() => _RabbitSetupScreenState();
}

class _RabbitSetupScreenState extends State<RabbitSetupScreen> {
  String _mode       = 'strokes_off';
  int    _netPercent = 100;
  bool   _accumulate = true;
  // Default to three 6-hole matches (rabbit resets each segment) rather than a
  // single 18-hole match — keeps more of the round in play.
  int    _segments   = 3;

  final TextEditingController _betCtrl = TextEditingController();
  /// True once a stake is entered or "no stakes" is chosen (gates Start).
  bool _stakeOk = false;
  bool _betCtrlInitialized = false;

  bool   _loading  = true;
  bool   _starting = false;
  /// True when editing an already-configured game (drives Save vs Start label).
  bool   _editing  = false;
  Object? _error;
  RabbitSummary? _summary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      _summary = await client.getRabbitSummary(widget.foursomeId);
      if (!mounted) return;

      // A Rabbit game already exists → jump to the play screen instead of
      // re-showing setup (re-setup would wipe results).  The empty-default
      // summary (no game) reports status 'pending' with no segments.
      final configured = _summary!.status == 'in_progress' ||
          _summary!.status == 'complete' ||
          _summary!.segments.isNotEmpty;

      // Normal flow: an already-set-up game jumps straight to the play screen.
      // In edit mode (returnToHub — round creation / "Edit Configuration")
      // stay on the form so the user can change settings.
      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/rabbit', arguments: widget.foursomeId);
        return;
      }

      setState(() {
        // Adopt saved settings when the game has been configured (non-empty
        // segments is the tell — covers the pending-with-config edit case);
        // a brand-new game keeps the casual defaults above.
        if (configured || _summary!.status != 'pending') {
          if (configured) _editing = true;
          _mode       = _summary!.handicapMode;
          _netPercent = _summary!.netPercent;
          _accumulate = _summary!.accumulate;
          _segments   = _summary!.numSegments;
        }
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes.firstWhere(
      (f) => f.id == widget.foursomeId,
      orElse: () => rp.round!.foursomes.first,
    );
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  bool get _rosterValid => _realMembers.length == 3;

  Future<void> _start() async {
    if (!_rosterValid) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;

      final parsed = double.tryParse(_betCtrl.text.trim());
      if (parsed != null && rp.round != null && parsed != rp.round!.betUnit) {
        await rp.updateRoundBetUnit(parsed);
      }

      final summary = await client.postRabbitSetup(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        accumulate:   _accumulate,
        numSegments:  _segments,
      );
      rp.setRabbitSummary(summary);

      if (widget.returnToHub) {
        // Round creation / "Edit Configuration": reload the round so the hub
        // reflects the freshly-saved game, then pop back to the launch page.
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/rabbit', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    if (!_betCtrlInitialized && rp.round != null) {
      _betCtrlInitialized = true;
      final b = rp.round!.betUnit;
      // Only prefill a real, previously-set stake — a fresh round
      // (bet 0) starts empty so the user must consciously set a
      // stake or tick "Play for fun" before Start enables.
      if (b > 0) {
        _betCtrl.text =
            b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
        _stakeOk = true;
      }
    }

    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Rabbit' : 'Rabbit Setup'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load,
                )
              : Column(children: [
                  Expanded(child: _buildBody()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton(
                          onPressed: (_starting || !_rosterValid || !_stakeOk) ? null : _start,
                          child: _starting
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text(_editing ? 'Save Configuration' : 'Start Game',
                                  style: const TextStyle(
                                      fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ),
                  ),
                ]),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RosterBanner(members: _realMembers),
          const SizedBox(height: 16),

          HandicapModeSelector(
            mode:       _mode,
            netPercent: _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),
          const SizedBox(height: 16),

          // ── Accumulate vs Stop ──
          _Card(
            title: 'Rabbit mode',
            child: Column(children: [
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                value: true,
                groupValue: _accumulate,
                onChanged: (v) => setState(() => _accumulate = v ?? true),
                title: const Text('Accumulate (build a lead)'),
                subtitle: const Text(
                    'Each hole the rabbit wins adds +1, each loss −1; the '
                    'rabbit is lost only when the lead hits 0.'),
              ),
              RadioListTile<bool>(
                contentPadding: EdgeInsets.zero,
                value: false,
                groupValue: _accumulate,
                onChanged: (v) => setState(() => _accumulate = v ?? false),
                title: const Text('Stop after one'),
                subtitle: const Text(
                    'The rabbit is lost on the first hole the holder is '
                    'beaten.'),
              ),
            ]),
          ),
          const SizedBox(height: 16),

          // ── Segments ──
          _Card(
            title: 'Match format',
            subtitle: 'The rabbit resets each segment; the holder at the end '
                'of a segment wins that share of the pot.',
            child: Column(children: [
              for (final opt in const [
                (1, 'One 18-hole match', 'Winner takes the whole pot.'),
                (2, 'Two 9-hole matches', 'Each match is half the pot.'),
                (3, 'Three 6-hole matches', 'Each match is a third of the pot.'),
              ])
                RadioListTile<int>(
                  contentPadding: EdgeInsets.zero,
                  value: opt.$1,
                  groupValue: _segments,
                  onChanged: (v) => setState(() => _segments = v ?? 3),
                  title: Text(opt.$2),
                  subtitle: Text(opt.$3),
                ),
            ]),
          ),
          const SizedBox(height: 16),

          StakeField(
            controller: _betCtrl,
            label: 'Stake per match',
            onChanged: (v) => setState(() => _stakeOk = v)),
          const SizedBox(height: 16),

          _Card(
            title: 'How Rabbit works',
            child: Text(
              'The first player to win a hole outright catches the rabbit and '
              'runs ahead. They hold it until an opponent beats them on a '
              'hole, which sets it loose again — then all three race to win a '
              'hole and grab it. Hold the rabbit at the end of a segment to '
              'win that share of the pot.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ===========================================================================
// Small shared widgets
// ===========================================================================

class _Card extends StatelessWidget {
  final String  title;
  final String? subtitle;
  final Widget  child;
  const _Card({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
          ],
          const SizedBox(height: 6),
          child,
        ]),
      ),
    );
  }
}

class _RosterBanner extends StatelessWidget {
  final List<Membership> members;
  const _RosterBanner({required this.members});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok    = members.length == 3;
    final color = ok ? theme.colorScheme.primary : theme.colorScheme.error;
    return Card(
      elevation: 0,
      color: color.withOpacity(0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                ok
                  ? 'Rabbit is ready for this 3-player group.'
                  : 'Rabbit needs exactly 3 real players.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600, color: color),
              ),
              const SizedBox(height: 4),
              Text(
                'Players: ${members.map((m) => m.player.displayShort).join(' / ')}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
