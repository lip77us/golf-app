/// screens/banker_draw_screen.dart
/// -------------------------------
/// A one-shot slot-machine REVEAL of the first banker.
///
/// Modelled on the Sixes segment draw and holding to its one hard rule: **the
/// reel is never the source of randomness.** The winner is drawn before this
/// screen opens and passed in; the machine only reveals a name that already
/// exists. A spinner that decided the outcome would be a spinner nobody could
/// audit, and this one hands somebody the exposure for the first hole.
///
/// It is its own screen rather than a parameter on the Sixes one because that
/// draw is two-sided by construction — blue pairing against orange, two names
/// a row, team colours throughout. Banker draws one man, in gold.
library;

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Gold is the ROLE, here as everywhere else in the game.
const _gold      = Color(0xFFB8860B);
const _goldLight = Color(0xFFE8C46A);
const _muted     = Color(0xFF5C6B62);

const double _rowH   = 84;
const int    _reps   = 9;
const Duration _spin = Duration(milliseconds: 2400);

class BankerDrawScreen extends StatefulWidget {
  const BankerDrawScreen({
    super.key,
    required this.names,
    required this.winnerIndex,
  });

  /// One label per golfer, in roster order.
  final List<String> names;

  /// Which of them the draw already picked.
  final int winnerIndex;

  @override
  State<BankerDrawScreen> createState() => _BankerDrawScreenState();
}

class _BankerDrawScreenState extends State<BankerDrawScreen>
    with TickerProviderStateMixin {
  late final AnimationController _reel =
      AnimationController(vsync: this, duration: _spin);
  late final AnimationController _bulbs = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 450));
  late final AnimationController _thunk = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 340));

  /// Cosmetic shuffle of the display order, so the winner is not always in the
  /// same slot of the strip.
  late final List<int> _display;
  late final int _displayWinner;

  bool _spinning = false;
  bool _landed   = false;
  bool _blur     = false;
  Animation<double>? _offset;

  @override
  void initState() {
    super.initState();
    _display = List<int>.generate(widget.names.length, (i) => i)
      ..shuffle(Random());
    _displayWinner = _display.indexOf(widget.winnerIndex);
  }

  @override
  void dispose() {
    _reel.dispose();
    _bulbs.dispose();
    _thunk.dispose();
    super.dispose();
  }

  int get _n => widget.names.length;
  String _atSlot(int slot) => widget.names[_display[slot]];
  String get _winner => widget.names[widget.winnerIndex];

  double get _landY => -(((_reps - 2) * _n + _displayWinner) * _rowH);

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  void _start() {
    if (_spinning || _landed) return;
    _offset = Tween<double>(begin: 0, end: _landY).animate(CurvedAnimation(
        parent: _reel, curve: const Cubic(0.12, 0.62, 0.15, 1.0)));
    setState(() {
      _spinning = true;
      _blur = !_reduceMotion;
    });
    // Honour the platform's reduce-motion setting: the draw is information,
    // and it must not be gated behind two and a half seconds of animation for
    // somebody who has asked for none.
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

  /// Tapping the window mid-spin lands it immediately — nobody on a tee box
  /// should have to watch an animation finish.
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
    setState(() {
      _spinning = false;
      _landed = true;
      _blur = false;
    });
  }

  /// **A landed draw is a fact, and leaving the screen does not unmake it.**
  ///
  /// The result used to be returned only by the call-to-action, so a golfer
  /// who watched the reel stop on Tyler and then swiped back got Paul — the
  /// untouched default — while believing he had drawn. The reveal is not the
  /// decision; the draw already happened before this screen opened, and every
  /// way out of it has to carry the same answer.
  ///
  /// Backing out BEFORE spinning still returns nothing, which is right:
  /// nothing was drawn.
  void _leave() => Navigator.of(context).pop(_landed ? widget.winnerIndex : null);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEEF3EE),
      appBar: AppBar(
        title: const Text('First banker'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _leave,
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: _landed
                ? FilledButton(
                    onPressed: _leave,
                    child: Text('$_winner banks the 1st',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  )
                : FilledButton(
                    onPressed: _spinning ? null : _start,
                    child: Text(_spinning ? 'Drawing…' : 'Flip for it',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
          ),
        ),
      ),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Text('WHO BANKS THE 1ST',
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700,
                  letterSpacing: 0.8, color: _gold)),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
                'Traditionally a flipped tee on the first box. One of you '
                'faces three bets before anybody has swung.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, height: 1.5, color: _muted)),
          ),
          const SizedBox(height: 22),
          _machine(),
          const SizedBox(height: 18),
          if (_landed)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text('Drawn at random. The reel only shows it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: _muted)),
            ),
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
          width: 300,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF3B2E0C), Color(0xFF1A1405)]),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x4D06120E), blurRadius: 26,
                  offset: Offset(0, 12)),
            ],
          ),
          child: Column(children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('THE DRAW',
                  style: TextStyle(
                      fontSize: 9.5, fontWeight: FontWeight.w700,
                      letterSpacing: 0.6, color: Color(0xA8FFFFFF))),
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
                    color: const Color(0xFFFDF8EC),
                    border: Border.all(
                        color: _landed ? _goldLight : const Color(0x241F1805),
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
        builder: (_, __) => Row(
          children: List.generate(3, (i) {
            final phase = (_bulbs.value + i * 0.15) % 1.0;
            final on = _spinning && phase > 0.5;
            return Container(
              width: 7, height: 7,
              margin: const EdgeInsets.only(left: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: on ? _goldLight : const Color(0x4DFFFFFF),
                boxShadow: on
                    ? const [BoxShadow(color: _goldLight, blurRadius: 8)]
                    : null,
              ),
            );
          }),
        ),
      );

  Widget _reelStrip() {
    if (!_spinning && !_landed) {
      return const SizedBox(
        height: _rowH,
        child: Center(
          child: Text('Spin to pick the first banker',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15, color: _muted)),
        ),
      );
    }
    final strip = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < _reps; r++)
          for (var slot = 0; slot < _n; slot++) _row(_atSlot(slot)),
      ],
    );
    return AnimatedBuilder(
      animation: _reel,
      builder: (_, __) {
        final dy = _offset?.value ?? 0;
        final child = Transform.translate(offset: Offset(0, dy), child: strip);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: double.infinity,
            child: _blur
                ? ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaY: 3.2),
                    child: child)
                : child,
          ),
        );
      },
    );
  }

  Widget _row(String name) => SizedBox(
        height: _rowH,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(name,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w700,
                      color: Color(0xFF0B1F1A))),
            ),
          ),
        ),
      );
}
