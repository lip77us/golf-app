/// screens/spots_setup_screen.dart
/// --------------------------------
/// Setup for Spots — a capture add-on settled on its own pot. The group decides
/// what counts (one-putt, sandy, barky, …) and tallies them by hand in score
/// entry. Knobs: value of one spot + payout style (pay-around / pool).
/// 2–4 real players.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../providers/round_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/stake_field.dart';
import '../widgets/spots_capture.dart' show spotTypeBlurb;

class SpotsSetupScreen extends StatefulWidget {
  final int foursomeId;
  final bool returnToHub;
  const SpotsSetupScreen({
    super.key,
    required this.foursomeId,
    this.returnToHub = false,
  });

  @override
  State<SpotsSetupScreen> createState() => _SpotsSetupScreenState();
}

class _SpotsSetupScreenState extends State<SpotsSetupScreen> {
  final _betCtrl = TextEditingController();
  bool   _stakeOk = false;
  String _payoutStyle  = 'per_point';   // 'pool' | 'per_point'
  String _perPointMode = 'all';         // 'average' | 'all' | 'first'
  bool _advancedOpen = false;
  bool _capEnabled   = false;

  /// Which spots the group is playing. **Null until the first load**, which
  /// is how "omitted" survives to the POST: an empty set would be sent as
  /// an empty list, which the server refuses on purpose.
  Set<String>? _types;
  bool   _greenieCarry = true;
  String _birdieBasis  = 'gross';     // 'gross' | 'net_so'

  /// Every type the server knows, with its label, so the checklist cannot
  /// print a slug and cannot drift from the enum. Filled on load.
  List<SpotTypeInfo> _catalogue = const [];
  final _capCtrl = TextEditingController();

  bool    _loading  = true;
  bool    _starting = false;
  bool    _editing  = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _betCtrl.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client  = context.read<AuthProvider>().client;
      final summary = await client.getSpotsSummary(widget.foursomeId);
      if (!mounted) return;
      final configured =
          summary.status == 'in_progress' || summary.players.isNotEmpty;
      if (configured && !widget.returnToHub) {
        Navigator.of(context).pushReplacementNamed(
          '/score-entry', arguments: widget.foursomeId);
        return;
      }
      setState(() {
        // The catalogue is whatever the server offers. On a configured game
        // `in_play` is the group's own picks, so the full list comes from the
        // defaults a fresh game reports — which is why an unconfigured
        // summary still carries them.
        _catalogue = _mergeCatalogue(summary);
        if (configured) {
          _editing      = true;
          _types        = {for (final t in summary.inPlay) t.type};
          _greenieCarry = summary.greenie.carry;
          _birdieBasis  = summary.birdieBasis;
          _payoutStyle  = summary.payoutStyle;
          _perPointMode = summary.perPointMode;
          if (summary.lossCap != null) {
            _capEnabled   = true;
            _advancedOpen = true;
            _capCtrl.text = summary.lossCap!.toStringAsFixed(0);
          }
          final b = summary.betUnit;
          _betCtrl.text =
              b % 1 == 0 ? b.toStringAsFixed(0) : b.toStringAsFixed(2);
          _stakeOk = true;
        } else {
          _types = {for (final t in summary.inPlay) t.type};
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

  bool get _rosterValid {
    final n = _realMembers.length;
    return n >= 2 && n <= 4;
  }

  /// At least one spot has to be in play, so Save is dead until there is one.
  /// The server refuses an empty list as well; this is the half that keeps
  /// the TD out of a form he cannot save.
  bool get _anyTypePicked => (_types ?? const <String>{}).isNotEmpty;

  Future<void> _start() async {
    if (!_rosterValid || !_anyTypePicked) return;
    setState(() { _starting = true; _error = null; });
    try {
      final rp     = context.read<RoundProvider>();
      final client = context.read<AuthProvider>().client;
      final bet    = double.tryParse(_betCtrl.text.trim());
      await client.postSpotsSetup(
        widget.foursomeId,
        betUnit:      bet,
        payoutStyle:  _payoutStyle,
        perPointMode: _perPointMode,
        types:        _types?.toList(),
        greenieCarry: _greenieCarry,
        birdieBasis:  _birdieBasis,
        lossCap: (_payoutStyle == 'per_point' && _capEnabled)
            ? (double.tryParse(_capCtrl.text.trim()) ?? 0.0)
            : null,
      );
      await rp.loadSpots(widget.foursomeId);
      if (widget.returnToHub) {
        await rp.loadRound(rp.round!.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        if (!mounted) return;
        Navigator.of(context).pushReplacementNamed(
          '/score-entry', arguments: widget.foursomeId);
      }
    } catch (e) {
      if (mounted) setState(() { _error = e; _starting = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GolfAppBar(title: _editing ? 'Edit Spots' : 'Spots Setup'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorView(
                  message: friendlyError(_error!),
                  isNetwork: isNetworkError(_error!),
                  onRetry: _load)
              : Column(children: [
                  Expanded(child: _buildBody()),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: GolfPrimaryButton(
                        label: (_editing || widget.returnToHub)
                            ? 'Save Configuration'
                            : 'Start Spots',
                        loading: _starting,
                        onPressed: (_rosterValid && _stakeOk &&
                                    _anyTypePicked) ? _start : null,
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
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('How the money settles',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'pool',      label: Text('Pool')),
                      ButtonSegment(value: 'per_point', label: Text('Per spot')),
                    ],
                    selected: {_payoutStyle},
                    onSelectionChanged: (s) =>
                        setState(() => _payoutStyle = s.first),
                  ),
                  const SizedBox(height: 8),
                  if (_payoutStyle == 'pool')
                    Text(
                        'Everyone antes the spot value; the pot splits by '
                        'spots won.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant))
                  else ...[
                    SegmentedButton<String>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'average', label: Text('vs Average')),
                        ButtonSegment(value: 'all',     label: Text('Above you')),
                        ButtonSegment(value: 'first',   label: Text('Just leader')),
                      ],
                      selected: {_perPointMode},
                      onSelectionChanged: (s) =>
                          setState(() => _perPointMode = s.first),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      switch (_perPointMode) {
                        'first' => 'Only the leader collects — everyone else pays '
                            'the leader their spot deficit × the spot value.',
                        'all' => 'Each spot pays the achiever the spot value from '
                            'every other player ("pay around").',
                        _ => 'Settle vs the field average — spots above the '
                            'average win, below owe, at the spot value.',
                      },
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        initiallyExpanded: _advancedOpen,
                        onExpansionChanged: (v) => _advancedOpen = v,
                        childrenPadding: EdgeInsets.zero,
                        title: Text('Advanced', style: theme.textTheme.bodyMedium),
                        children: [
                          SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text("Cap each player's losses"),
                            value: _capEnabled,
                            onChanged: (v) => setState(() => _capEnabled = v),
                          ),
                          if (_capEnabled)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: 180,
                                child: TextField(
                                  controller: _capCtrl,
                                  keyboardType: TextInputType.number,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.digitsOnly
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: 'Max loss',
                                    prefixText: '\$ ',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          StakeField(
            controller: _betCtrl,
            label: _payoutStyle == 'pool' ? 'Ante per player' : 'Value per spot',
            onChanged: (v) => setState(() => _stakeOk = v),
          ),
          const SizedBox(height: 16),
          _whichSpotsCard(theme),
          const SizedBox(height: 16),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('How Spots works',
                      style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary)),
                  const SizedBox(height: 8),
                  Text(
                    'A "spot" is anything the group agrees on — a one-putt, a '
                    'sandy, a barky, hitting the flag. Tally them per player on '
                    'each hole from the score-entry screen. Spots are a separate '
                    'pot, kept apart from your main game.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  /// Every type the server knows about, straight from the summary.
  ///
  /// It USED to merge `in_play` with `sheet_types` and fill the gaps from a
  /// label map typed here — because a configured game's `in_play` holds only
  /// the group's own picks. That made this screen a second place every type
  /// is named, and adding Hogan is what proved the cost: two edits, and
  /// forgetting this one shows a golfer the slug. The server sends the whole
  /// catalogue now.
  List<SpotTypeInfo> _mergeCatalogue(SpotsSummary s) => s.catalogue;

  /// "Which spots are we playing" — the agreement the feature exists for,
  /// which is why it is a card of its own under the stake rather than a line
  /// in the How-it-works blurb.
  Widget _whichSpotsCard(ThemeData theme) {
    final picked = _types ?? const <String>{};
    // The Gross / Net sub-row belongs to whichever of the two derived types
    // is on, and disappears when neither is — it is one setting for both.
    final birdieOn = picked.contains('birdie');
    final eagleOn  = picked.contains('eagle');
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: theme.colorScheme.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Which spots are we playing',
              style: theme.textTheme.labelLarge
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text('Listed on the leaderboard so the group knows what counts.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          for (final t in _catalogue) ...[
            CheckboxListTile(
              value: picked.contains(t.type),
              onChanged: (on) => setState(() {
                final next = {...picked};
                on == true ? next.add(t.type) : next.remove(t.type);
                _types = next;
              }),
              title: Text(t.label),
              subtitle: Text(spotTypeBlurb(t.type),
                  style: theme.textTheme.bodySmall),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
            // Greenie's own setting, and the only one any type has.
            if (t.type == 'greenie' && picked.contains('greenie'))
              Padding(
                padding: const EdgeInsets.only(left: 32, bottom: 6),
                child: SwitchListTile(
                  value: _greenieCarry,
                  onChanged: (v) => setState(() => _greenieCarry = v),
                  title: const Text('Carry over'),
                  subtitle: const Text('If nobody hits the green, the greenie '
                      'rolls to the next par 3.'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
            // One setting for both, under whichever is ticked — and under
            // Eagle when Birdie is off, which is the design's own rule.
            if ((t.type == 'birdie' && birdieOn) ||
                (t.type == 'eagle' && eagleOn && !birdieOn))
              Padding(
                padding: const EdgeInsets.only(left: 32, bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Birdies and eagles count',
                        style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'gross', label: Text('Gross')),
                        ButtonSegment(value: 'net_so', label: Text('Net (SO)')),
                      ],
                      selected: {_birdieBasis},
                      showSelectedIcon: false,
                      onSelectionChanged: (v) =>
                          setState(() => _birdieBasis = v.first),
                    ),
                    const SizedBox(height: 4),
                    Text('Net is strokes off the lowest handicap in the '
                        'group, at the group\'s allowance.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
          ],
          if (picked.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text('Pick at least one spot to play for.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
        ]),
      ),
    );
  }

}
