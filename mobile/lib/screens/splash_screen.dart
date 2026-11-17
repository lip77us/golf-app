import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The launch screen Flutter holds while the home is decided: deep pine with
/// the mark centred, identical to the native launch screen so the hand-off is
/// invisible (one launch screen, no second splash). It does not animate and
/// does not time anything; [onComplete] fires after the first frame and the
/// caller decides how long the screen is held.
class SplashScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const SplashScreen({super.key, required this.onComplete});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1F1A),
      body: Center(
        child: SvgPicture.asset('assets/icon/halved_mark.svg',
            width: 120, height: 120),
      ),
    );
  }
}
