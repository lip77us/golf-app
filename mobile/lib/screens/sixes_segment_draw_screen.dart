/// screens/sixes_segment_draw_screen.dart
/// ---------------------------------------
/// A one-shot slot-machine REVEAL of a Sixes pairing.  The pairing is already
/// decided (randomised + stored at setup); the reel is pure reveal of a value
/// that already exists — never the source of randomness.
///
/// Reused for every Sixes draw:
///   • Segment 1 — before hole 1, when the group opts to DRAW teams (3 pairings).
///   • Segment 2 — when Segment 1 completes (an early close-out can fire it on
///     hole 4/5).  Two pairings remain.
///   • Extra match — when an early finish leaves holes for a bonus match and the
///     group draws (rather than "loser picks") the teams.
///
/// The caller supplies the candidates, which one is the winner, and the copy;
/// the screen shuffles the DISPLAY order (cosmetic) so the winning row isn't
/// always in the same slot, then reveals it.

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class SixesDrawPair {
  final List<String> blue;
  final List<String> orange;
  const SixesDrawPair({required this.blue, required this.orange});
  String get blueLabel => blue.join(' / ');
  String get orangeLabel => orange.join(' / ');
  // Compact labels — first names only, so two-player pairings fit the reel /
  // rows without overflowing. A long single first name is caught by FittedBox.
  static String _first(String n) {
    final w = n.trim().split(RegExp(r'\s+'));
    return w.isEmpty ? n : w.first;
  }
  String get blueShort => blue.map(_first).join(' / ');
  String get orangeShort => orange.map(_first).join(' / ');
}

class SixesSegmentDrawScreen extends StatefulWidget {
  final String courseName;
  final String eyebrow;        // e.g. "SEGMENT 1 COMPLETE · HOLES 1–6" / "STARTING THE ROUND"
  final String title;          // "Who plays together next?" / "…first?"
  final String lede;
  final Widget? contextLine;   // optional prior-segment status row (seg 2 only)
  final String machineTitle;   // "SEGMENT 2 DRAW"
  final List<SixesDrawPair> candidates;  // 2 (seg 2 / extra) or 3 (seg 1)
  final int winnerIndex;       // index into [candidates] that is the drawn pairing
  final String ctaLabel;       // "Start hole 7"
  final String landedFootnote; // audit line shown after landing
  /// When true the candidate pairs are NOT listed before the spin (the idle
  /// screen just prompts "spin to pick partners"); they're revealed only once
  /// the reel lands.  Keeps the outcome a surprise.
  final bool hideCandidatesUntilDrawn;

  const SixesSegmentDrawScreen({
    super.key,
    required this.courseName,
    required this.eyebrow,
    required this.title,
    required this.lede,
    required this.machineTitle,
    required this.candidates,
    required this.winnerIndex,
    required this.ctaLabel,
    required this.landedFootnote,
    this.contextLine,
    this.hideCandidatesUntilDrawn = false,
  });

  @override
  State<SixesSegmentDrawScreen> createState() => _SixesSegmentDrawScreenState();
}

// Tokens (self-contained — the machine has its own dark palette).
const _pine = Color(0xFF0F6E56);
const _brightMint = Color(0xFF3BD89A);
const _muted = Color(0xFF5C6B62);
const _blue = Color(0xFF1976D2);
const _orange = Color(0xFFEF6C00);
const _cardBorder = Color(0xFFD3DED6);

const double _rowH = 92;
const int _reps = 9;
const Duration _spinDur = Duration(milliseconds: 2550);

class _SixesSegmentDrawScreenState extends State<SixesSegmentDrawScreen>
    with TickerProviderStateMixin {
  late final AnimationController _reel =
      AnimationController(vsync: this, duration: _spinDur);
  late final AnimationController _bulbs =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final AnimationController _thunk =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 340));

  // Cosmetic shuffle of the display order so the winner isn't always in slot A.
  late final List<int> _display;   // display slot -> candidate index
  late final int _displayWinner;   // display slot of the winner

  bool _spinning = false;
  bool _landed = false;
  bool _blur = false;
  Animation<double>? _offset;

  static const _tags = ['A', 'B', 'C', 'D'];

  @override
  void initState() {
    super.initState();
    _display = List<int>.generate(widget.candidates.length, (i) => i)..shuffle(Random());
    _displayWinner = _display.indexOf(widget.winnerIndex);
  }

  @override
  void dispose() {
    _reel.dispose();
    _bulbs.dispose();
    _thunk.dispose();
    super.dispose();
  }

  int get _n => widget.candidates.length;
  SixesDrawPair _atSlot(int slot) => widget.candidates[_display[slot]];
  SixesDrawPair get _winner => widget.candidates[widget.winnerIndex];

  double get _landY =>
      -(((_reps - 2) * _n + _displayWinner) * _rowH);

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  void _spin() {
    if (_spinning || _landed) return;
    _offset = Tween<double>(begin: 0, end: _landY).animate(
        CurvedAnimation(parent: _reel, curve: const Cubic(0.12, 0.62, 0.15, 1.0)));
    setState(() { _spinning = true; _blur = !_reduceMotion; });
    if (_reduceMotion) {
      _reel.value = 1.0;
      _finish();
      return;
    }
    _bulbs.repeat(reverse: true);
    _reel.addListener(() {
      if (_blur && _reel.value >= 0.686) setState(() => _blur = false);
    });
    _reel.forward().whenComplete(_finish);
  }

  void _skip() {
    if (!_spinning || _landed) return;
    _reel.stop();
    _reel.value = 1.0;
    _finish();
  }

  void _finish() {
    if (_landed) return;
    _bulbs.stop();
    _thunk.forward(from: 0);
    setState(() { _spinning = false; _landed = true; _blur = false; });
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      backgroundColor: const Color(0xFFEEF3EE),
      appBar: AppBar(
        title: Text('Sixes · ${widget.courseName}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
        centerTitle: true,
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
          child: Column(children: [
            const SizedBox(height: 4),
            Text(widget.eyebrow.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: _muted, letterSpacing: 0.5)),
            const SizedBox(height: 3),
            Text(widget.title,
                textAlign: TextAlign.center,
                style: TextStyle(fontFamily: 'Schibsted Grotesk',
                    fontWeight: FontWeight.w700, fontSize: 21, color: onSurface)),
            const SizedBox(height: 3),
            Text(widget.lede, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12.5, color: _muted, height: 1.5)),
            const SizedBox(height: 10),
            if (widget.contextLine != null) ...[
              widget.contextLine!,
              const SizedBox(height: 9),
            ],
            // Candidate rows: always shown when revealing upfront; when hidden,
            // they only appear once the reel has landed (the reveal).
            if (!widget.hideCandidatesUntilDrawn || _landed)
              for (var slot = 0; slot < _n; slot++) ...[
                _candidate(_atSlot(slot), _tags[slot], slot == _displayWinner),
                if (slot < _n - 1) const SizedBox(height: 7),
              ],
            Expanded(child: Center(child: _machine())),
            _calling(),
            const SizedBox(height: 10),
            _footer(),
          ]),
        ),
      ),
    );
  }

  Widget _candidate(SixesDrawPair p, String tag, bool isWinner) {
    final won = _landed && isWinner;
    final dim = _landed && !isWinner;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 450),
      opacity: dim ? 0.32 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: won ? const Color(0x123BD89A) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: won ? _pine : _cardBorder, width: won ? 2 : 1),
        ),
        child: Row(children: [
          Container(width: 21, height: 21, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: won ? _pine : const Color(0xFFEEF3EE), shape: BoxShape.circle,
              border: Border.all(color: won ? _pine : _cardBorder)),
            child: Text(tag, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                color: won ? Colors.white : _muted))),
          const SizedBox(width: 9),
          Flexible(child: RichText(overflow: TextOverflow.ellipsis, text: TextSpan(
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            children: [
              TextSpan(text: p.blueShort, style: const TextStyle(color: _blue)),
              const TextSpan(text: '  v.  ', style: TextStyle(color: _muted,
                  fontWeight: FontWeight.w500, fontSize: 11)),
              TextSpan(text: p.orangeShort, style: const TextStyle(color: _orange)),
            ]))),
          if (won) ...[
            const SizedBox(width: 6),
            Text(widget.machineTitle.split(' ').take(2).join(' ').replaceAll(' DRAW', ''),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _pine)),
          ],
        ]),
      ),
    );
  }

  Widget _machine() => AnimatedBuilder(
        animation: _thunk,
        builder: (_, child) {
          final dy = _landed ? (sin(_thunk.value * pi) * 3) : 0.0;
          return Transform.translate(offset: Offset(0, dy), child: child);
        },
        child: Container(
          width: 308, padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF15866A), Color(0xFF0B4A38)]),
            boxShadow: const [BoxShadow(color: Color(0x4D06120E), blurRadius: 26,
                offset: Offset(0, 12))],
          ),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(widget.machineTitle, style: const TextStyle(fontSize: 9.5,
                  fontWeight: FontWeight.w700, letterSpacing: 0.6, color: Color(0xA8FFFFFF))),
              _bulbRow(),
            ]),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _skip,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: _rowH,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF7FAF7),
                    border: Border.all(
                        color: _landed ? _brightMint : const Color(0x24071F1A),
                        width: _landed ? 2.5 : 2),
                  ),
                  child: _reelStrip(),
                ),
              ),
            ),
          ]),
        ),
      );

  Widget _bulbRow() => AnimatedBuilder(
        animation: _bulbs,
        builder: (_, __) => Row(children: List.generate(3, (i) {
          final phase = (_bulbs.value + i * 0.15) % 1.0;
          final on = _spinning && phase > 0.5;
          return Container(width: 7, height: 7,
            margin: const EdgeInsets.only(left: 5),
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: on ? _brightMint : const Color(0x4DFFFFFF),
              boxShadow: on ? const [BoxShadow(color: _brightMint, blurRadius: 8)] : null));
        })),
      );

  Widget _reelStrip() {
    // When the pairings are concealed, the idle window shows only a prompt —
    // neither candidate pair is revealed until the reel is spun.
    if (widget.hideCandidatesUntilDrawn && !_spinning && !_landed) {
      return SizedBox(
        height: _rowH,
        child: const Center(child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Text('Spin to select next partners', textAlign: TextAlign.center,
              style: TextStyle(fontFamily: 'Schibsted Grotesk',
                  fontWeight: FontWeight.w700, fontSize: 15, color: _muted)),
        )),
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < _reps; i++) {
      for (var slot = 0; slot < _n; slot++) {
        rows.add(_slot(_atSlot(slot), _tags[slot]));
      }
    }
    return AnimatedBuilder(
      animation: _reel,
      builder: (_, __) {
        final y = (_spinning || _landed) ? (_offset?.value ?? 0.0) : 0.0;
        Widget strip = OverflowBox(
          minHeight: 0, maxHeight: double.infinity, alignment: Alignment.topCenter,
          child: Transform.translate(offset: Offset(0, y),
              child: Column(mainAxisSize: MainAxisSize.min, children: rows)),
        );
        if (_blur) {
          strip = ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 1.7, sigmaY: 1.7), child: strip);
        }
        return ClipRect(child: strip);
      },
    );
  }

  Widget _slot(SixesDrawPair p, String side) => SizedBox(
        height: _rowH,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('SIDE $side', style: const TextStyle(fontSize: 9,
              fontWeight: FontWeight.w700, letterSpacing: 0.6, color: _muted)),
          const SizedBox(height: 3),
          // FittedBox: shrink to fit if a first-name pairing is still too wide.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: FittedBox(fit: BoxFit.scaleDown, child: RichText(text: TextSpan(
              style: const TextStyle(fontFamily: 'Schibsted Grotesk',
                  fontWeight: FontWeight.w700, fontSize: 16),
              children: [
                TextSpan(text: p.blueShort, style: const TextStyle(color: _blue)),
                const TextSpan(text: ' v. ', style: TextStyle(color: _muted,
                    fontWeight: FontWeight.w600, fontSize: 12)),
                TextSpan(text: p.orangeShort, style: const TextStyle(color: _orange)),
              ]))),
          ),
        ]),
      );

  Widget _calling() {
    if (_landed) {
      return RichText(textAlign: TextAlign.center, text: TextSpan(
        style: const TextStyle(fontSize: 12.5, color: _muted, fontWeight: FontWeight.w600),
        children: [
          TextSpan(text: _winner.blueLabel,
              style: const TextStyle(color: _pine, fontWeight: FontWeight.w700)),
          const TextSpan(text: ' v. '),
          TextSpan(text: _winner.orangeLabel,
              style: const TextStyle(color: _pine, fontWeight: FontWeight.w700)),
        ]));
    }
    return Text(_spinning ? 'Spinning…' : 'Tap Spin to draw.',
        style: const TextStyle(fontSize: 12.5, color: _muted, fontWeight: FontWeight.w600));
  }

  Widget _footer() => Column(children: [
        SizedBox(
          width: double.infinity, height: 50,
          child: FilledButton(
            onPressed: _landed
                ? () => Navigator.of(context).pop(true)
                : (_spinning ? null : _spin),
            style: FilledButton.styleFrom(
                backgroundColor: _pine,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999))),
            child: Text(_landed ? widget.ctaLabel : 'Spin the reel',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
        const SizedBox(height: 8),
        Text(_landed ? widget.landedFootnote
                     : 'Result is drawn before it animates · logged to the round',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10.5, color: _muted, height: 1.4)),
      ]);
}
