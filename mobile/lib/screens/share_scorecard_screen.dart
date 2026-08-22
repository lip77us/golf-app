/// screens/share_scorecard_screen.dart
/// ------------------------------------
/// Preview the group's scorecard, then share it.
///
/// Share sends a LINK to the public scorecard page, not a PNG. The image it
/// used to send froze at the moment it was sent, titled itself with the
/// course, called one golfer two different names, and carried no Halved
/// anywhere — so a stranger who received it had nothing to tap and no idea
/// what the product was. The link opens a live page, arrives in the thread
/// with a proper preview card, and ends in "Get Halved free".
///
/// The on-screen preview stays: it is what the sender is choosing to share,
/// and seeing it is how they decide the round is worth sending.


import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../game_catalog.dart';
import '../providers/round_provider.dart';
import '../widgets/golf_app_bar.dart';
import '../widgets/shareable_scorecard.dart';

class ShareScorecardScreen extends StatefulWidget {
  final int foursomeId;
  const ShareScorecardScreen({super.key, required this.foursomeId});

  @override
  State<ShareScorecardScreen> createState() => _ShareScorecardScreenState();
}

class _ShareScorecardScreenState extends State<ShareScorecardScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rp = context.read<RoundProvider>();
      if (rp.scorecard == null || rp.activeFoursomeId != widget.foursomeId) {
        rp.loadScorecard(widget.foursomeId);
      }
    });
  }

  String _dateLabel(String raw) {
    final d = DateTime.tryParse(raw);
    if (d == null) return raw;
    const m = [
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _roundLabel(List<String> games) {
    final names = games
        .map((g) => gameMeta(g)?.displayName ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    return names.isEmpty ? 'Scorecard' : names.join(' + ');
  }

  /// Share the LINK, not a picture of the scorecard.
  ///
  /// The PNG titled itself with the course, called one golfer two different
  /// names, printed the same result three times and carried no Halved
  /// anywhere -- and being an image, it froze the moment it was sent. The
  /// link opens a live page, gets a proper preview card in the thread, and
  /// gives someone who has never heard of Halved somewhere to go.
  Future<void> _share() async {
    if (_sharing) return;
    // Capture what we need from context BEFORE any await.
    final rp     = context.read<RoundProvider>();
    final course = rp.round?.course.name ?? 'Golf';
    final url    = rp.scorecard?.shareUrl ?? '';
    // iOS requires a non-zero source rect for the share sheet (and the iPad
    // popover anchor); without it shareXFiles throws sharePositionOrigin errors.
    final box = context.findRenderObject() as RenderBox?;
    final Rect? origin = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    setState(() => _sharing = true);
    try {
      if (url.isEmpty) {
        // No watch token means no public page. Say so rather than silently
        // sending a bare sentence with nothing to tap.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('This round has no share link yet.')));
        }
        return;
      }
      await Share.share(
        'Scorecard from $course $url',
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share scorecard: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rp = context.watch<RoundProvider>();
    final sc = rp.scorecard;
    final ready = sc != null && rp.activeFoursomeId == widget.foursomeId;

    return Scaffold(
      appBar: GolfAppBar(
        title: 'Share Scorecard',
        actions: [
          IconButton(
            tooltip: 'Share',
            icon: _sharing
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share),
            onPressed: ready && !_sharing ? _share : null,
          ),
        ],
      ),
      body: !ready
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              // Scale the fixed-width card DOWN to fit narrow phones (e.g. the
              // 13 mini) for the preview, while the RepaintBoundary still
              // captures it at full 380pt resolution.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: RepaintBoundary(
                  key: _boundaryKey,
                  child: ShareableScorecard(
                    courseName: rp.round?.course.name ?? 'Golf',
                    dateLabel:  _dateLabel(rp.round?.date ?? ''),
                    roundLabel: _roundLabel(rp.round?.activeGames ?? const []),
                    holes:      sc.holes,
                    totals:     sc.totals,
                  ),
                ),
              ),
            ),
      bottomNavigationBar: !ready
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _sharing ? null : _share,
                    icon: const Icon(Icons.ios_share),
                    label: Text(_sharing ? 'Preparing…' : 'Share / Text scorecard'),
                  ),
                ),
              ),
            ),
    );
  }
}
