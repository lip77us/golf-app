import 'package:flutter/material.dart';

/// Branded splash screen shown on desktop (Windows/macOS/Linux) while the
/// app initialises.  On iOS the native LaunchImage handles the very first
/// frame; this widget provides a consistent look on all platforms and gives
/// a brief moment for any async startup work to complete before routing.
class SplashScreen extends StatefulWidget {
  /// Called once the splash animation has finished.  The callback should
  /// push the appropriate first route (login or tournaments).
  final VoidCallback onComplete;

  const SplashScreen({super.key, required this.onComplete});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<double> _fadeOut;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    // Fade in over first 600 ms, hold, fade out over last 500 ms.
    _fadeIn = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.27, curve: Curves.easeIn),
    );
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.77, 1.0, curve: Curves.easeOut),
      ),
    );

    _controller.forward().then((_) => widget.onComplete());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (_, __) {
          final opacity = _fadeIn.value * _fadeOut.value;
          return Center(
            child: Opacity(
              opacity: opacity,
              child: SizedBox(
                width: 260,
                height: 260,
                child: Image.asset(
                  'assets/images/bandon_cup_logo.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
