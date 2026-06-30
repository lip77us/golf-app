/// screens/three_person_match_setup_screen.dart
/// -----------------------------------------------
/// Setup screen for the Three-Person Match tournament game.
///
/// Nine holes of Points 5-3-1 scoring.  Final standings are determined
/// by cumulative points after hole 9.  Ties stand as ties — there is no
/// play-off extension.
///
/// This screen collects:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + allowance %
///   • Per-player entry fee and place payouts (1st / 2nd / 3rd)
///
/// Redirects to /score-entry immediately if the game is already running.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/inline_message.dart';
import '../widgets/payout_config_field.dart';
import '../widgets/section_card.dart';

class ThreePersonMatchSetupScreen extends StatefulWidget {
  final int foursomeId;

  /// When true, this screen was opened from round creation: after saving the
  /// match it returns to the /round launch page instead of jumping into
  /// scoring, and it won't auto-redirect to score entry during setup.
  final bool returnToHub;

  const ThreePersonMatchSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<ThreePersonMatchSetupScreen> createState() =>
      _ThreePersonMatchSetupScreenState();
}

class _ThreePersonMatchSetupScreenState
    extends State<ThreePersonMatchSetupScreen> {
  ThreePersonMatchSummary? _summary;
  bool    _loading = true;
  bool    _saving  = false;
  Object? _error;

  // Form state
  // Casual default → Strokes-Off Low.  Existing games overwrite this
  // from their persisted mode in _load().
  String _mode       = 'strokes_off';
  int    _netPercent = 100;

  final _entryFeeCtrl = TextEditingController();
  // Payout controllers indexed 0..2 → places "1st" / "2nd" / "3rd".  Number
  // of *active* places is driven by [_payoutPlaces] (0–3), matching the
  // Pink Ball / Low Net "Places paid" toggle UX.  Inactive places aren't
  // sent on save.
  static const _placeLabels = ['1st', '2nd', '3rd'];
  final List<TextEditingController> _payoutCtrls = List.generate(
      3, (_) => TextEditingController());
  int _payoutPlaces = 1;

  /// Format a monetary amount without unnecessary decimal places — "5"
  /// instead of "5.00", "5.50" stays "5.50".  Matches the convention
  /// used by Pink Ball / Low Net setup.
  static String _fmtAmount(num value) {
    final d = value.toDouble();
    return d == d.truncateToDouble()
        ? d.toInt().toString()
        : d.toStringAsFixed(2);
  }

  @override
  void initState() {
    super.initState();
    _load();
    _entryFeeCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _entryFeeCtrl.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  // ── Derived ───────────────────────────────────────────────────────────────

  List<Membership> get _realMembers {
    final rp = context.read<RoundProvider>();
    final fs = rp.round?.foursomes
        .where((f) => f.id == widget.foursomeId)
        .firstOrNull;
    if (fs == null) return const [];
    return fs.memberships.where((m) => !m.player.isPhantom).toList();
  }

  bool get _rosterValid => _realMembers.length == 3;

  double get _entryFee =>
      double.tryParse(_entryFeeCtrl.text.trim()) ?? 0.0;

  double get _pool => _entryFee * (_rosterValid ? 3 : 3);

  // ── Load / Save ───────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      _summary = await client.getThreePersonMatch(widget.foursomeId);
      if (!mounted) return;

      // Already in progress — skip setup.  In round-creation (returnToHub)
      // stay on the form so the user can return to the launch page instead
      // of being bounced into score entry.
      if (_summary!.status != 'pending' && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
            '/score-entry', arguments: widget.foursomeId);
        return;
      }

      // Pre-populate from existing config.
      setState(() {
        _mode       = _summary!.handicapMode;
        _netPercent = _summary!.netPercent;
        final money = _summary!.money;
        final fee   = (money['entry_fee'] as num?)?.toDouble() ?? 0.0;
        if (fee > 0) {
          _entryFeeCtrl.text = _fmtAmount(fee);
          final cfg = (money['payout_config'] as Map<String, dynamic>?) ?? {};
          // Derive the previously-saved place count: count from the top
          // until we hit a missing or zero entry.  This keeps the toggle
          // and the rendered rows consistent with what the backend stored.
          int places = 0;
          for (int i = 0; i < _placeLabels.length; i++) {
            final amt = (cfg[_placeLabels[i]] as num?)?.toDouble() ?? 0.0;
            _payoutCtrls[i].text = amt > 0 ? _fmtAmount(amt) : '';
            if (amt > 0) places = i + 1;
          }
          _payoutPlaces = places.clamp(1, 3);
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 404) {
        // Game not yet configured — show the setup form with defaults.
        setState(() { _loading = false; });
      } else {
        setState(() { _error = e; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  void _suggestPayouts() {
    final pool = _pool.round();
    if (pool <= 0) return;
    final amts = suggestPayouts(pool, _payoutPlaces);
    setState(() {
      for (int i = 0; i < _payoutPlaces; i++) {
        _payoutCtrls[i].text = amts[i] == 0 ? '' : '${amts[i]}';
      }
    });
  }

  Future<void> _save() async {
    if (!_rosterValid) return;
    setState(() { _saving = true; _error = null; });
    try {
      // Only send the active places' amounts.  Inactive places aren't
      // worth a zero entry — the backend treats absent keys as 0 anyway.
      final payouts = <String, double>{};
      for (int i = 0; i < _payoutPlaces; i++) {
        payouts[_placeLabels[i]] =
            double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
      }

      final rp = context.read<RoundProvider>();
      final ok = await rp.setupThreePersonMatch(
        widget.foursomeId,
        handicapMode: _mode,
        netPercent:   _netPercent,
        entryFee:     _entryFee,
        payoutConfig: payouts,
      );

      if (!mounted) return;
      if (ok) {
        // Reload round so configuredGames / the /round launch page is up to
        // date for the caller.
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        // Pop back to whoever pushed us (round screen, wizard Step 6,
        // tournament list) rather than jumping straight into score
        // entry — matches the Match Play setup behaviour and saves
        // the user from backing through several screens to return
        // to the main menu.  In round-creation (returnToHub) pop with no
        // result back to the /round launch page; otherwise pop with `true`
        // so wizard Step 6 can flip the per-foursome "configured" icon.
        Navigator.of(context).pop(widget.returnToHub ? null : true);
      } else {
        setState(() { _saving = false; _error = rp.error; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Three-Person Match — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _summary == null
              ? ErrorView(
                  message:   friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry:   _load,
                )
              : _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InlineMessage(
                    kind: InlineMessageKind.error,
                    text: friendlyError(_error!),
                  ),
                ),
              SizedBox(
                width: double.infinity, height: 52,
                child: FilledButton(
                  onPressed: (_saving || !_rosterValid) ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Start Match',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RosterCard(members: _realMembers),
          const SizedBox(height: 16),
          // Shared handicap selector — same widget the other casual /
          // tournament setup screens use, so the picker reads identically
          // across the app.  Defaults to SO Low like the other games.
          HandicapModeSelector(
            mode:             _mode,
            netPercent:       _netPercent,
            onModeChanged:    (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
            soNote: 'The lowest-handicap player in this threesome plays '
                'to 0.  Other players receive (own HCP − low HCP) '
                'strokes by stroke index, scaled by Net %.',
          ),
          const SizedBox(height: 16),
          _entryFeeCard(theme),
          const SizedBox(height: 16),
          _payoutsCard(theme),
          const SizedBox(height: 16),
          _rulesCard(theme),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  // ── Section widgets ───────────────────────────────────────────────────────

  Widget _entryFeeCard(ThemeData theme) => SectionCard(
    title: 'Entry Fee',
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GolfTextField(
        controller: _entryFeeCtrl,
        label: 'Per player (\$)',
        hint: '0',
        prefixIcon: Icons.attach_money,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
      if (_pool > 0) ...[
        const SizedBox(height: 6),
        Text(
          'Prize pool: \$${_fmtAmount(_pool)} (3 players)',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    ]),
  );

  Widget _payoutsCard(ThemeData theme) => SectionCard(
    title: 'Payouts',
    // Shared payout construct — paid-places stepper (max 3 for a threesome),
    // amount fields, balance + Auto-suggest. Matches every other game.
    child: PayoutConfigField(
      pool:                _pool.round(),
      numPayouts:          _payoutPlaces.clamp(1, 3),
      payoutCtrls:         _payoutCtrls,
      maxPayouts:          3,
      onNumPayoutsChanged: (n) => setState(() => _payoutPlaces = n),
      onPayoutChanged:     () => setState(() {}),
      onSuggest:           _suggestPayouts,
    ),
  );

  Widget _rulesCard(ThemeData theme) => SectionCard(
    title: 'How it works',
    child: Text(
      'Holes 1–9: Points 5-3-1 per hole (5 pts to best net score, '
      '3 to 2nd, 1 to 3rd; ties split evenly so every hole pays 9 pts total).\n\n'
      'After hole 9, the player with the most cumulative points finishes 1st, '
      'second-most finishes 2nd, fewest finishes 3rd.\n\n'
      'Ties stand as ties — tied players share the combined payout for '
      'their tied positions.',
      style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    ),
  );
}

// ===========================================================================
// _RosterCard
// ===========================================================================

class _RosterCard extends StatelessWidget {
  final List<Membership> members;
  const _RosterCard({required this.members});

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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              ok ? Icons.people_alt_outlined : Icons.error_outline,
              color: color,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ok
                        ? 'Three-Person Match — ready to configure.'
                        : 'Three-Person Match requires exactly 3 real players.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600, color: color),
                  ),
                  if (members.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      members
                          .map((m) => '${m.player.displayShort} '
                              '(HCP ${m.playingHandicap})')
                          .join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Final standings determined by 9-hole 5-3-1 points.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// (Removed) _HandicapCard — replaced by the shared HandicapModeSelector
// widget so the picker reads identically across every game setup screen.
