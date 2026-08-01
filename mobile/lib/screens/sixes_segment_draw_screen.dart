/// screens/sixes_segment_draw_screen.dart
/// ---------------------------------------
/// A one-shot slot-machine REVEAL of the Sixes Segment-2 pairing.  The pairing
/// is already decided (randomised + stored at setup); the reel is pure reveal of
/// a value that already exists — never the source of randomness.  Fires once,
/// when Segment 1 completes (which can be an early close-out on hole 4/5, not
/// necessarily hole 6).
///
/// Parameterised (candidate pairings + which one is Segment 2) so the same
/// screen can later reveal a Segment-1 / extra-round draw if the group opts out
/// of picking those teams in setup.

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class SixesDrawPair {
  final List<String> blue;
  final List<String> orange;
  const SixesDrawPair({required this.blue, required this.orange});
  String get blueLabel => blue.join(' / ');
  String get orangeLabel => orange.join(' / ');
}

class SixesSegmentDrawScreen extends StatefulWidget {
  final String courseName;
  final String seg1Label;      // e.g. "holes 1–6"
  final SixesDrawPair seg1Blue1; // Segment 1 pairing (for the context line)
  final String seg1Status;     // e.g. "2 UP" / "Halved"
  final SixesDrawPair winner;  // the drawn Segment-2 pairing
  final SixesDrawPair other;   // the remaining pairing (becomes Segment 3)
  final int nextHole;          // Segment 2's first hole (early-finish aware)
  final String drawnAtLabel;   // e.g. "9:41 AM"

  const SixesSegmentDrawScreen({
    super.key,
    required this.courseName,
    required this.seg1Label,
    required this.seg1Blue1,
    required this.seg1Status,
    required this.winner,
    required this.other,
    required this.nextHole,
    required this.drawnAtLabel,
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
  late final AnimationController _reel = AnimationController(vsync: this, duration: _spinDur);
  late final AnimationController _bulbs =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));
  late final AnimationController _thunk =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 340));

  // Cosmetic display order — winner shown as "Side A" (top) or "Side B" so the
  // landing slot varies and the top row doesn't always win.  Fixed per open.
  late final bool _winnerIsA = Random().nextBool();

  bool _spinning = false;
  bool _landed = false;
  bool _blur = false;

  late final Animation<double> _offset;

  SixesDrawPair get _sideA => _winnerIsA ? widget.winner : widget.other;
  SixesDrawPair get _sideB => _winnerIsA ? widget.other : widget.winner;

  @override
  void dispose() {
    _reel.dispose();
    _bulbs.dispose();
    _thunk.dispose();
    super.dispose();
  }

  double get _landY {
    // Land on row (REPS-2)*2 + (winner slot: A=0, B=1).
    final winOffset = _winnerIsA ? 0 : 1;
    return -(((_reps - 2) * 2 + winOffset) * _rowH);
  }

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
    // Un-blur near the end so the last rows read as they pass.
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
            Text('SEGMENT 1 COMPLETE · ${widget.seg1Label.toUpperCase()}',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                    color: _muted, letterSpacing: 0.5)),
            const SizedBox(height: 3),
            Text('Who plays together next?',
                style: TextStyle(fontFamily: 'Schibsted Grotesk',
                    fontWeight: FontWeight.w700, fontSize: 21,
                    color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 3),
            const Text('Two pairings are left. Spin to draw Segment 2.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: _muted, height: 1.5)),
            const SizedBox(height: 10),
            _seg1Line(),
            const SizedBox(height: 9),
            _candidate(_sideA, 'A', _winnerIsA),
            const SizedBox(height: 7),
            _candidate(_sideB, 'B', !_winnerIsA),
            Expanded(child: Center(child: _machine())),
            _calling(),
            const SizedBox(height: 10),
            _footer(),
          ]),
        ),
      ),
    );
  }

  Widget _seg1Line() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _cardBorder)),
        child: Row(children: [
          const Text('SEG 1', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
              color: _muted, letterSpacing: 0.3)),
          const SizedBox(width: 8),
          Text(widget.seg1Blue1.blueLabel, style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 12, color: _blue)),
          const Text(' v. ', style: TextStyle(color: _muted, fontSize: 11)),
          Text(widget.seg1Blue1.orangeLabel, style: const TextStyle(
              fontWeight: FontWeight.w600, fontSize: 12, color: _orange)),
          const Spacer(),
          Text(widget.seg1Status, style: const TextStyle(
              fontWeight: FontWeight.w700, fontSize: 12, color: _pine)),
        ]),
      );

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
          Container(width: 21, height: 21,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: won ? _pine : const Color(0xFFEEF3EE),
              shape: BoxShape.circle,
              border: Border.all(color: won ? _pine : _cardBorder)),
            child: Text(tag, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                color: won ? Colors.white : _muted))),
          const SizedBox(width: 9),
          Flexible(child: RichText(overflow: TextOverflow.ellipsis, text: TextSpan(
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            children: [
              TextSpan(text: p.blueLabel, style: const TextStyle(color: _blue)),
              const TextSpan(text: '  v.  ', style: TextStyle(color: _muted,
                  fontWeight: FontWeight.w500, fontSize: 11)),
              TextSpan(text: p.orangeLabel, style: const TextStyle(color: _orange)),
            ]))),
          if (won) ...[
            const SizedBox(width: 6),
            const Text('Segment 2', style: TextStyle(fontSize: 11,
                fontWeight: FontWeight.w700, color: _pine)),
          ],
        ]),
      ),
    );
  }

  Widget _machine() {
    return AnimatedBuilder(
      animation: _thunk,
      builder: (_, child) {
        final t = _thunk.value;
        // small "thunk" bounce (down then back).
        final dy = _landed ? (sin(t * pi) * 3) : 0.0;
        return Transform.translate(offset: Offset(0, dy), child: child);
      },
      child: Container(
        width: 308,
        padding: const EdgeInsets.all(13),
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
            const Text('SEGMENT 2 DRAW', style: TextStyle(fontSize: 9.5,
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
  }

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
    final rows = <Widget>[];
    for (var i = 0; i < _reps; i++) {
      rows.add(_slot(_sideA, 'A'));
      rows.add(_slot(_sideB, 'B'));
    }
    return AnimatedBuilder(
      animation: _reel,
      builder: (_, __) {
        final y = _spinning || _landed
            ? (_reel.isAnimating || _landed ? _offset.value : 0.0) : 0.0;
        Widget strip = OverflowBox(
          minHeight: 0, maxHeight: double.infinity,
          alignment: Alignment.topCenter,
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
          RichText(text: TextSpan(
            style: const TextStyle(fontFamily: 'Schibsted Grotesk',
                fontWeight: FontWeight.w700, fontSize: 16),
            children: [
              TextSpan(text: p.blueLabel, style: const TextStyle(color: _blue)),
              const TextSpan(text: ' v. ', style: TextStyle(color: _muted,
                  fontWeight: FontWeight.w600, fontSize: 12)),
              TextSpan(text: p.orangeLabel, style: const TextStyle(color: _orange)),
            ])),
        ]),
      );

  Widget _calling() {
    if (_landed) {
      return RichText(textAlign: TextAlign.center, text: TextSpan(
        style: const TextStyle(fontSize: 12.5, color: _muted, fontWeight: FontWeight.w600),
        children: [
          const TextSpan(text: 'Segment 2 — '),
          TextSpan(text: widget.winner.blueLabel,
              style: const TextStyle(color: _pine, fontWeight: FontWeight.w700)),
          const TextSpan(text: ' v. '),
          TextSpan(text: widget.winner.orangeLabel,
              style: const TextStyle(color: _pine, fontWeight: FontWeight.w700)),
        ]));
    }
    return Text(_spinning ? 'Spinning…' : 'Two pairings left — spin for Segment 2.',
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
            child: Text(_landed ? 'Start hole ${widget.nextHole}' : 'Spin the reel',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
        const SizedBox(height: 8),
        Text(_landed
            ? 'Drawn ${widget.drawnAtLabel} · Segment 3 is the last pairing'
            : 'Result is drawn before it animates · logged to the round',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10.5, color: _muted, height: 1.4)),
      ]);
}
