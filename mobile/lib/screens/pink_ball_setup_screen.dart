import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';

/// Staff-only screen for Pink Ball round-level configuration:
///   • Ball colour label (e.g. "Pink", "Red", "Yellow")
///   • Entry fee per foursome (bet_unit)
///   • Number of places paid (1 = winner takes all)
///
/// The per-foursome hole rotation is set by each foursome on the Pink Ball
/// scoring screen before they start entering scores.
///
/// Route: /pink-ball-setup   arguments: int roundId
class PinkBallSetupScreen extends StatefulWidget {
  final int roundId;
  const PinkBallSetupScreen({super.key, required this.roundId});

  @override
  State<PinkBallSetupScreen> createState() => _PinkBallSetupScreenState();
}

class _PinkBallSetupScreenState extends State<PinkBallSetupScreen> {
  bool    _loading = true;
  bool    _saving  = false;
  String? _error;

  final _colorCtrl    = TextEditingController(text: 'Pink');
  final _entryFeeCtrl = TextEditingController(text: '1.00');
  int     _placesPaid = 1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _colorCtrl.dispose();
    _entryFeeCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final data   = await client.getPinkBallSetup(widget.roundId);
      setState(() {
        _colorCtrl.text    = data['ball_color'] as String? ?? 'Pink';
        _entryFeeCtrl.text = (data['bet_unit'] as num?)?.toStringAsFixed(2) ?? '1.00';
        _placesPaid        = (data['places_paid'] as int?) ?? 1;
        _loading           = false;
      });
    } catch (e) {
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _save() async {
    final entryFee = double.tryParse(_entryFeeCtrl.text.trim()) ?? 1.0;
    final color    = _colorCtrl.text.trim().isEmpty ? 'Pink' : _colorCtrl.text.trim();
    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.postPinkBallSetup(
        widget.roundId,
        ballColor:  color,
        betUnit:    entryFee,
        placesPaid: _placesPaid,
      );
      if (!mounted) return;
      context.read<RoundProvider>().loadRound(widget.roundId);
      Navigator.of(context).pop();
    } catch (e) {
      setState(() { _saving = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pink Ball Setup'),
        actions: [
          if (!_loading)
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorRetry(message: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _GameSettingsCard(
                      colorCtrl:           _colorCtrl,
                      entryFeeCtrl:        _entryFeeCtrl,
                      placesPaid:          _placesPaid,
                      onPlacesPaidChanged: (v) => setState(() => _placesPaid = v),
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(children: [
                          Icon(Icons.info_outline,
                              size: 18,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Each group sets their own ball rotation when '
                              'they open the scoring screen for the first time.',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ]),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// Game settings card
// ---------------------------------------------------------------------------

class _GameSettingsCard extends StatelessWidget {
  final TextEditingController colorCtrl;
  final TextEditingController entryFeeCtrl;
  final int    placesPaid;
  final void Function(int) onPlacesPaidChanged;

  const _GameSettingsCard({
    required this.colorCtrl,
    required this.entryFeeCtrl,
    required this.placesPaid,
    required this.onPlacesPaidChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Game Settings',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),

          // Ball colour
          TextFormField(
            controller: colorCtrl,
            decoration: const InputDecoration(
              labelText: 'Ball Colour',
              hintText: 'e.g. Pink, Red, Yellow',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
          ),
          const SizedBox(height: 12),

          // Entry fee
          TextFormField(
            controller: entryFeeCtrl,
            decoration: const InputDecoration(
              labelText: 'Entry Fee per Group (\$)',
              hintText: '1.00',
              prefixText: '\$ ',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 16),

          // Places paid
          Text('Places Paid',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            'How many finishing groups receive a payout.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('1st only')),
              ButtonSegment(value: 2, label: Text('1st & 2nd')),
              ButtonSegment(value: 3, label: Text('Top 3')),
            ],
            selected: {placesPaid.clamp(1, 3)},
            onSelectionChanged: (s) => onPlacesPaidChanged(s.first),
          ),
          const SizedBox(height: 8),
          Text(
            placesPaid == 1
                ? 'Winner takes the full pool.'
                : 'Pool split equally among the top $placesPaid finishing groups.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary),
          ),
        ]),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
          textAlign: TextAlign.center),
      const SizedBox(height: 12),
      FilledButton(onPressed: onRetry, child: const Text('Retry')),
    ]));
  }
}
