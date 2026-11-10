import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';

const Color _secondary = Color(0xFFB9CCC3);
const Color _trayMuted = Color(0xFF7F968C);

/// `Paul + Gil v Larry + Jim   net 5 v 4  [Won]` — a dark tray's result row.
///
/// **The names, then why, then the result**, on one line (Paul, 10 Nov
/// 2026, on the Nassau tray: *"net 5 v 4 and the Won badge on the same row
/// as the names … with net 5 v 4 first"*; then *"change the sixes scoring
/// summary to match"*). It was written into the Nassau tray and Sixes drew
/// its own chip — `Won hole 1  net 5 v 4` in 13pt and 11pt on a filled
/// lozenge — so this is the one place the row lives now. The second caller
/// is what earns a module; a third tray should take it rather than draw a
/// fourth.
///
/// Three things keep one row honest:
/// - **The names yield, the result does not.** Each name is flexible with an
///   ellipsis; the reason and the badge take their natural width, because
///   the result is what the tray exists to say.
/// - **Nothing in the names run is rigid.** The ` v ` rides inside the second
///   name's run — a fixed `v` between two flexible names is the one piece
///   that overflows once the names can be squeezed hard.
/// - **The result is capped at two thirds of the row and scales down** past
///   that, so a narrow screen or large type shrinks it rather than spilling.
///
/// **The result follows the names; it is not right-justified.** Pushed to
/// the right edge it sat under the tray label's trailing text on a large
/// phone and read as belonging to that.
class TrayResultRow extends StatelessWidget {
  const TrayResultRow({
    super.key,
    required this.name1,
    required this.name2,
    required this.colour1,
    required this.colour2,
    required this.decided,
    this.winner,
    this.reasonLabel,
    this.figure1,
    this.figure2,
    this.flatReason = '',
    this.joiner = ' v ',
  });

  /// The two sides' names, and the colour each is drawn in — ON DARK.
  final String name1;
  final String name2;
  final Color colour1;
  final Color colour2;

  /// The hole has a result. False draws the names alone.
  final bool decided;

  /// 1 or 2, or null for a halved hole.
  final int? winner;

  /// `net` / `2nd ball`, and each side's figure — drawn with **each figure
  /// in its own side's colour**, so which 5 is whose needs no reading
  /// across. All three or none.
  final String? reasonLabel;
  final int? figure1;
  final int? figure2;

  /// The reason as one sentence, for a payload that sends no parts. Drawn
  /// flat — bigger, but uncoloured, rather than guessing which digit is
  /// whose.
  final String flatReason;

  /// What sits between the two names.
  final String joiner;

  bool get _hasParts =>
      reasonLabel != null && figure1 != null && figure2 != null;

  static const _words = TextStyle(
      color: _secondary, fontSize: 14, fontWeight: FontWeight.w600);

  Widget? _reason() {
    if (!_hasParts) {
      if (flatReason.isEmpty) return null;
      return Text(flatReason,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: _words);
    }
    TextSpan figure(int v, Color c) => TextSpan(
        text: '$v',
        style: TextStyle(
            color: c, fontSize: 16, fontWeight: FontWeight.w800));
    return Text.rich(
      TextSpan(style: _words, children: [
        TextSpan(text: '$reasonLabel '),
        figure(figure1!, colour1),
        const TextSpan(text: ' v '),
        figure(figure2!, colour2),
      ]),
      maxLines: 1, overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final reason = _reason();
    return LayoutBuilder(builder: (context, box) =>
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      // Loose, not `Expanded`: the result follows the names directly.
      Flexible(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(name1,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: colour1,
                    fontSize: 14, fontWeight: FontWeight.w700)),
          ),
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: joiner,
                    style: const TextStyle(
                        color: _trayMuted, fontSize: 12)),
                TextSpan(text: name2),
              ]),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: colour2,
                  fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ]),
      ),
      if (decided) ...[
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box.maxWidth * 0.66),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (reason != null) ...[
                reason,
                const SizedBox(width: 8),
              ],
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: winner == null
                      ? Colors.white.withValues(alpha: 0.14)
                      : (winner == 1 ? colour1 : colour2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(winner == null ? 'Halved' : 'Won',
                    style: TextStyle(
                        color:
                            winner == null ? Colors.white : Halved.deepPine,
                        fontSize: 14, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ),
      ],
    ]));
  }
}
