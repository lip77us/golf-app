/// Solo setup — one golfer, and the opponent is par.
///
/// `handoff-solo-games`. Four sections top to bottom: the Golfer, the
/// Handicap, How it works, and then "For fun. No stakes." above Start Round.
///
/// **There is almost nothing to set, and that is the design.** No Net/Gross —
/// a solo game against par in gross is stroke play with extra words, and the
/// allowance is the whole point of playing par. No stake, no presses, no
/// payout table. One slider, and a sentence that says what it just did.
///
/// The slider goes ABOVE 100%, which no other screen in the app allows. A
/// golfer who wants par beatable gives himself more; nobody is paying, so
/// there is nobody for it to be unfair to.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../game_catalog.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/section_card.dart';

/// Copy for "How it works", one paragraph per variant — the handoff's words.
const _howItWorks = {
  'stroke': 'Count every shot. Your score is your net total against par for '
      'the round.',
  'nassau': 'A simple Nassau against par: the front nine, the back nine and '
      'all 18 are three matches. Beat par to win a hole, make par to halve '
      'it, go over to lose it.',
  'match': 'An 18-hole match against par. Beat par to win the hole, make par '
      'to halve it, make bogey or worse to lose it. The match can be decided '
      'early; you can still finish the round.',
};

const _title = {
  'stroke': 'Stroke Play',
  'nassau': 'Nassau',
  'match': 'Match Play',
};

/// Which variant a round's active games imply.
String soloVariantOf(List<String> activeGames) {
  if (activeGames.contains(GameIds.soloNassau)) return 'nassau';
  if (activeGames.contains(GameIds.soloMatch)) return 'match';
  return 'stroke';
}

class SoloSetupScreen extends StatefulWidget {
  final int roundId;

  /// Which of the three was picked on the create screen. The round's
  /// `active_games` carries it, but the chip is what the golfer chose and the
  /// screen is titled after it — so it is passed rather than re-derived.
  final String variant;

  const SoloSetupScreen({
    super.key,
    required this.roundId,
    required this.variant,
  });

  @override
  State<SoloSetupScreen> createState() => _SoloSetupScreenState();
}

class _SoloSetupScreenState extends State<SoloSetupScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;

  int _pct = 100;
  String _name = '';
  int? _ch;
  String _tee = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context
          .read<AuthProvider>()
          .client
          .getSoloSetup(widget.roundId);
      if (!mounted) return;
      setState(() {
        _pct = (d['net_percent'] as num?)?.toInt() ?? 100;
        _name = (d['player_name'] as String?) ?? '';
        _ch = (d['course_handicap'] as num?)?.toInt();
        _tee = (d['tee_name'] as String?) ?? '';
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _loading = false; });
    }
  }

  /// Strokes at the current allowance — the number the sentence quotes.
  ///
  /// Rounded the same way the server allocates (`effective_hcp_for`), so the
  /// screen cannot promise 13 and the card give 12.
  int get _strokes => _ch == null ? 0 : ((_ch! * _pct) / 100).round();

  Future<void> _start() async {
    setState(() { _saving = true; _error = null; });
    try {
      await context.read<AuthProvider>().client.postSoloSetup(
            widget.roundId,
            variant: widget.variant,
            netPercent: _pct,
          );
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed('/score-entry',
          arguments: widget.roundId);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _title[widget.variant] ?? 'Solo';
    return Scaffold(
      appBar: GolfAppBar(title: '$name — Setup'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: 'Golfer',
                  // The pill says who the opponent is, which is the one thing
                  // about this round that is not like any other.
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('vs Par',
                        style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onSecondaryContainer)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_name.isEmpty ? 'You' : _name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        [if (_ch != null) 'CH $_ch', if (_tee.isNotEmpty) _tee]
                            .join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                SectionCard(
                  title: 'Handicap',
                  trailing: Text('$_pct%',
                      style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Slider(
                        value: _pct.toDouble(),
                        min: 25,
                        max: 150,
                        divisions: 25,          // 5% steps
                        label: '$_pct%',
                        onChanged: (v) =>
                            setState(() => _pct = (v / 5).round() * 5),
                      ),
                      // Says what the slider just did, in strokes and in
                      // holes — a percentage on its own is not something a
                      // golfer can picture on the 1st tee.
                      SoloAllowanceLine(
                        courseHandicap: _ch ?? 0,
                        netPercent: _pct,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                SectionCard(
                  title: 'How it works',
                  child: Text(_howItWorks[widget.variant] ?? '',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(height: 1.45)),
                ),

                if (_error != null && !_saving) ...[
                  const SizedBox(height: 16),
                  ErrorView(message: _error!, onRetry: _load),
                ],

                const SizedBox(height: 24),
                Center(
                  child: Text('For fun. No stakes.',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: _saving ? null : _start,
                    child: _saving
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Start Round'),
                  ),
                ),
              ],
            ),
    );
  }
}


/// The sentence under the allowance slider.
///
/// Its own widget because it is the one part of this screen with a decision
/// in it, and the decision is easy to get wrong. The handoff writes the
/// sentence for a 12 handicap — "12 strokes, on the holes with a stroke index
/// of 12 or lower" — which stops making sense the moment the number passes
/// 18, and a high handicapper is exactly who slides above 100%. At 150% a 30
/// handicap is 45 strokes: one on every hole and a second on 27 of them,
/// which no sentence about "index 45 or lower" can say.
class SoloAllowanceLine extends StatelessWidget {
  final int courseHandicap;
  final int netPercent;
  const SoloAllowanceLine({
    super.key,
    required this.courseHandicap,
    required this.netPercent,
  });

  /// Rounded the way the server allocates (`effective_hcp_for`), so the screen
  /// cannot promise 13 and the card give 12.
  int get strokes => ((courseHandicap * netPercent) / 100).round();

  String get text {
    final n = strokes;
    final tail = ' Slide below or above 100% to give fewer or more.';
    if (n <= 0) {
      return 'Always Net. No strokes — you play par straight up.$tail';
    }
    if (n < 18) {
      return 'Always Net. $n strokes, on the holes with a stroke index of '
          '$n or lower.$tail';
    }
    if (n == 18) return 'Always Net. 18 strokes — one on every hole.$tail';
    return 'Always Net. $n strokes — one on every hole, and a second on the '
        '${n - 18} hardest.$tail';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text,
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant, height: 1.45));
  }
}
