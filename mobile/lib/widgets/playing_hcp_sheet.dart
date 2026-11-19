/// A whole-number pad for a golfer's forced playing handicap (Tees &
/// Handicaps). The system number pad has no Done key, and on this screen a
/// keyboard left up covers the rest of the group; this pad has Save, Cancel
/// and "Use auto" and nothing else to get stuck on.
///
/// Returns the digits typed, `''` for "use the computed handicap" and null
/// when cancelled.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/halved_brand.dart';

/// The most digits a playing handicap can have.
const int kPlayingHcpDigits = 2;

/// One key on the pad. Pure so it can be tested: a digit appends (up to
/// [kPlayingHcpDigits], and a leading zero is dropped), `back` removes one.
String playingHcpKey(String typed, String key) {
  if (key == 'back') {
    return typed.isEmpty ? typed : typed.substring(0, typed.length - 1);
  }
  if (typed.length >= kPlayingHcpDigits) return typed;
  if (typed == '0') return key;
  return '$typed$key';
}

Future<String?> showPlayingHcpSheet(
  BuildContext context, {
  required String name,
  required String current,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Halved.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => PlayingHcpSheet(name: name, current: current),
    );

class PlayingHcpSheet extends StatefulWidget {
  final String name;
  final String current;
  const PlayingHcpSheet({super.key, required this.name, required this.current});

  @override
  State<PlayingHcpSheet> createState() => _PlayingHcpSheetState();
}

class _PlayingHcpSheetState extends State<PlayingHcpSheet> {
  late String _typed = widget.current.trim();

  void _press(String k) => setState(() => _typed = playingHcpKey(_typed, k));

  @override
  Widget build(BuildContext context) {
    final first = widget.name.trim().split(' ').first;
    Widget key(String label, String k, {Widget? child}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _press(k),
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Halved.cardBorder)),
                  child: child ??
                      Text(label,
                          style: GoogleFonts.schibstedGrotesk(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: Halved.deepPine)),
                ),
              ),
            ),
          ),
        );
    Widget row(List<Widget> c) => Row(children: c);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(first,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.schibstedGrotesk(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: Halved.deepPine)),
                    Text('Playing handicap for this round',
                        style: Halved.body(color: Halved.muted)),
                  ]),
            ),
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cancel',
                    style: Halved.body(
                        color: Halved.pine, weight: FontWeight.w800))),
          ]),
          const SizedBox(height: 14),
          Text(_typed.isEmpty ? '—' : _typed,
              key: const Key('playing-hcp-shown'),
              style: GoogleFonts.schibstedGrotesk(
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  color: _typed.isEmpty ? Halved.muted : Halved.deepPine)),
          const SizedBox(height: 4),
          Text('The final number. No allowance is applied on top.',
              textAlign: TextAlign.center,
              style: Halved.body(color: Halved.muted)),
          const SizedBox(height: 10),
          row([key('1', '1'), key('2', '2'), key('3', '3')]),
          row([key('4', '4'), key('5', '5'), key('6', '6')]),
          row([key('7', '7'), key('8', '8'), key('9', '9')]),
          row([
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    key: const Key('playing-hcp-auto'),
                    onPressed: () => Navigator.of(context).pop(''),
                    child: const Text('Auto'),
                  ),
                ),
              ),
            ),
            key('0', '0'),
            key('', 'back',
                child: const Icon(Icons.backspace_outlined,
                    color: Halved.deepPine)),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              key: const Key('playing-hcp-save'),
              onPressed: _typed.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_typed),
              child: Text(_typed.isEmpty ? 'Save' : 'Save $_typed for $first'),
            ),
          ),
        ]),
      ),
    );
  }
}
