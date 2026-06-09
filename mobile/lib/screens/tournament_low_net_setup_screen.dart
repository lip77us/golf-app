/// screens/tournament_low_net_setup_screen.dart
/// ----------------------------------------------
/// Setup screen for the Low Net Championship — a tournament-level game
/// that accumulates net strokes across all rounds.
///
/// Knobs:
///   • Handicap mode (Net / Gross / Strokes-Off-Low) + Net % allowance
///   • Entry fee per player
///   • Payout amounts per finishing place (absolute dollar amounts)

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';
import '../widgets/handicap_mode_selector.dart';
import '../widgets/section_card.dart';

class TournamentLowNetSetupScreen extends StatefulWidget {
  final int tournamentId;
  const TournamentLowNetSetupScreen({super.key, required this.tournamentId});

  @override
  State<TournamentLowNetSetupScreen> createState() =>
      _TournamentLowNetSetupScreenState();
}

class _TournamentLowNetSetupScreenState
    extends State<TournamentLowNetSetupScreen> {
  String _mode       = 'net';
  int    _netPercent = 100;
  final  _entryCtrl       = TextEditingController(text: '0');
  // Local-only: used to estimate the prize pool (not saved to server)
  final  _numPlayersCtrl  = TextEditingController(text: '');

  // Payout rows — one controller per paid place (absolute amounts)
  final List<TextEditingController> _payoutCtrls = [];
  int _payoutPlaces = 0;

  bool    _loading = true;
  bool    _saving  = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _entryCtrl.addListener(() => setState(() {}));
    _numPlayersCtrl.addListener(() => setState(() {}));
    _load();
  }

  @override
  void dispose() {
    _entryCtrl.dispose();
    _numPlayersCtrl.dispose();
    for (final c in _payoutCtrls) c.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static String _fmt(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  TextEditingController _makePayoutCtrl(String text) {
    final c = TextEditingController(text: text.isEmpty ? '0' : text);
    c.addListener(() => setState(() {}));
    return c;
  }

  double get _totalPayout =>
      _payoutCtrls.fold(0.0, (s, c) => s + (double.tryParse(c.text.trim()) ?? 0.0));

  /// Estimated pool = entry fee × number of players (UI helper, not saved).
  double? get _estimatedPool {
    final fee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
    final n   = int.tryParse(_numPlayersCtrl.text.trim()) ?? 0;
    if (fee <= 0 || n <= 0) return null;
    return fee * n;
  }

  // ── Load / save ───────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final cfg    = await client.getTournamentLowNetSetup(widget.tournamentId);
      if (!mounted) return;

      final ctrls = <TextEditingController>[];
      for (final p in cfg.payouts) {
        final amt = (p['amount'] as num? ?? 0).toDouble();
        ctrls.add(_makePayoutCtrl(_fmt(amt)));
      }

      setState(() {
        _mode       = cfg.handicapMode;
        _netPercent = cfg.netPercent;
        _entryCtrl.text = _fmt(cfg.entryFee);
        _payoutPlaces   = ctrls.length;
        for (final c in _payoutCtrls) c.dispose();
        _payoutCtrls
          ..clear()
          ..addAll(ctrls);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  void _setPayoutPlaces(int n) {
    setState(() {
      while (_payoutCtrls.length < n) {
        _payoutCtrls.add(_makePayoutCtrl('0'));
      }
      while (_payoutCtrls.length > n) {
        _payoutCtrls.removeLast().dispose();
      }
      _payoutPlaces = n;
    });
  }

  Future<void> _save() async {
    setState(() { _saving = true; _error = null; });
    try {
      final client   = context.read<AuthProvider>().client;
      final entryFee = double.tryParse(_entryCtrl.text.trim()) ?? 0.0;
      final payouts  = <Map<String, dynamic>>[];
      for (int i = 0; i < _payoutCtrls.length; i++) {
        final amt = double.tryParse(_payoutCtrls[i].text.trim()) ?? 0.0;
        payouts.add({'place': i + 1, 'amount': amt});
      }

      final setup = LowNetChampionshipSetup(
        handicapMode: _mode,
        netPercent  : _netPercent,
        entryFee    : entryFee,
        payouts     : payouts,
      );
      await client.postTournamentLowNetSetup(widget.tournamentId, setup);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Stroke Play Championship — Setup')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && !_saving
              ? ErrorView(
                  message : friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry : _load,
                )
              : _buildBody(),
      bottomNavigationBar: _loading ? null : SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width : double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save Setup',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
            ),
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

          // ── About ─────────────────────────────────────────────────────────
          SectionCard(
            title: 'Stroke Play Championship',
            child: Text(
              'Cumulative net strokes across all rounds determine the winner. '
              'Each round\'s score is capped at double-bogey (par + 2) per hole '
              'before it is applied to the championship total.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 16),

          // ── Handicap mode ─────────────────────────────────────────────────
          // Shared selector — matches the casual setup screens and avoids
          // the "Handicap %" Row overflow the inline _HandicapCard had at
          // narrow widths.
          HandicapModeSelector(
            mode            : _mode,
            netPercent      : _netPercent,
            onModeChanged   : (m) => setState(() => _mode = m),
            onPercentChanged: (p) => setState(() => _netPercent = p),
          ),

          const SizedBox(height: 16),

          // ── Entry fee ─────────────────────────────────────────────────────
          SectionCard(
            title: 'Entry Fee',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    flex: 3,
                    child: GolfTextField(
                      controller: _entryCtrl,
                      label: 'Per player (\$)',
                      prefixIcon: Icons.attach_money,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GolfTextField(
                      controller: _numPlayersCtrl,
                      label: '# Players',
                      prefixIcon: Icons.people_outline,
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                // Pool estimate
                if (_estimatedPool != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer
                          .withOpacity(0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children: [
                      Icon(Icons.savings_outlined,
                          size: 16,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Prize pool: '
                        '\$${_entryCtrl.text.trim()} × '
                        '${_numPlayersCtrl.text.trim()} players = ',
                        style: theme.textTheme.bodySmall,
                      ),
                      Text(
                        '\$${_estimatedPool!.toStringAsFixed(2)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary),
                      ),
                    ]),
                  )
                else
                  Text(
                    'Enter a player count to estimate the prize pool.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Payout structure ──────────────────────────────────────────────
          SectionCard(
            title: 'Payouts',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Places paid',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),

                // Places stepper (0–8)
                LayoutBuilder(builder: (context, constraints) {
                  const maxPlaces = 8;
                  // n buttons → (n+1) borders at 1px each
                  final segW =
                      ((constraints.maxWidth - (maxPlaces + 1)) / maxPlaces)
                          .floorToDouble();
                  return ToggleButtons(
                    borderRadius : BorderRadius.circular(8),
                    constraints  : BoxConstraints.tightFor(width: segW, height: 40),
                    // Single-select: only the currently chosen count is highlighted
                    isSelected   : List.generate(
                        maxPlaces, (i) => i + 1 == _payoutPlaces),
                    // Tap same button again → deselect (0 places); tap new → select it
                    onPressed    : (i) => _setPayoutPlaces(
                        _payoutPlaces == i + 1 ? 0 : i + 1),
                    children     : List.generate(
                        maxPlaces, (i) => Text('${i + 1}')),
                  );
                }),

                const SizedBox(height: 16),

                // Payout input rows
                for (int i = 0; i < _payoutCtrls.length; i++) ...[
                  _PayoutRow(
                    place     : i + 1,
                    controller: _payoutCtrls[i],
                  ),
                  if (i < _payoutCtrls.length - 1) const SizedBox(height: 8),
                ],

                // Total
                if (_payoutCtrls.isNotEmpty) ...[
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Total payout',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      Text(
                        '\$${_totalPayout.toStringAsFixed(2)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                ],

                if (_payoutCtrls.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Select the number of paid places above.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),

                const SizedBox(height: 8),
                Text(
                  'Ties split the combined prize for their finishing positions equally.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          // ── Error banner ──────────────────────────────────────────────────
          if (_error != null && _saving == false) ...[
            const SizedBox(height: 16),
            Container(
              padding   : const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color        : theme.colorScheme.errorContainer,
                borderRadius : BorderRadius.circular(8),
              ),
              child: Row(children: [
                Icon(Icons.error_outline, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(friendlyError(_error!),
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer)),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// ===========================================================================
// Shared sub-widgets
// ===========================================================================

// _HandicapCard replaced by the shared HandicapModeSelector — see the
// import above and the call site in build().  The inline ToggleButtons +
// "Handicap %" Row overflowed by ~8 px on narrow widths and didn't match
// the casual-side handicap UI.

/// Single payout row (place + dollar input).
class _PayoutRow extends StatelessWidget {
  final int                   place;
  final TextEditingController controller;
  const _PayoutRow({required this.place, required this.controller});

  static String _ordinal(int n) {
    switch (n) {
      case 1: return '1st';
      case 2: return '2nd';
      case 3: return '3rd';
      default: return '${n}th';
    }
  }

  static Color _placeColor(int place) {
    switch (place) {
      case 1: return const Color(0xFFB8860B); // dark gold
      case 2: return const Color(0xFF708090); // slate silver
      case 3: return const Color(0xFF8B4513); // saddle brown / bronze
      default: return Colors.black87;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = place <= 3 ? _placeColor(place) : Colors.black87;
    return Row(children: [
      SizedBox(
        width: 44,
        child: Text(
          _ordinal(place),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: color),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: GolfTextField(
          controller: controller,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          prefixText: '\$ ',
          textAlign: TextAlign.right,
        ),
      ),
    ]);
  }
}
