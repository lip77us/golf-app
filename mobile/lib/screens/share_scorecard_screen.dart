/// screens/share_scorecard_screen.dart
/// ------------------------------------
/// Preview + share a portrait scorecard as an image. Loads the foursome's
/// scorecard, renders the two-nines [ShareableScorecard] inside a
/// RepaintBoundary, and the app-bar Share action captures it to a PNG and opens
/// the native share sheet (Messages, etc.) so the user can text a copy.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  Future<void> _share() async {
    if (_sharing) return;
    // Capture what we need from context BEFORE any await.
    final course = context.read<RoundProvider>().round?.course.name ?? 'Golf';
    setState(() => _sharing = true);
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final bytes = byteData.buffer.asUint8List();

      // Dart's built-in temp dir (NSTemporaryDirectory on iOS) — no plugin.
      final file = File('${Directory.systemTemp.path}'
          '/scorecard_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes);

      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: '$course scorecard',
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
