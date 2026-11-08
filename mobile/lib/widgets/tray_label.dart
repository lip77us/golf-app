import 'package:flutter/material.dart';

/// `HOLE 7 · NASSAU` with `FRONT NINE` on the right — the heading of a
/// section inside a dark hole tray.
///
/// **One label, four trays.** Wolf, Las Vegas, Fourball and Nassau each drew
/// this row themselves, and by the fourth copy the uppercase fix had to be
/// made twice in one sitting: the design system puts
/// `text-transform: uppercase` on the whole row, so `25¢ A POINT` and
/// `1 PT EACH` are headings rather than values, and a row that was
/// half-capitalised read as two different kinds of thing. Same reason
/// [TrayEditHeader] was extracted, learnt the same way.
///
/// **The LABEL yields, never the figure beside it:** `$10 a bet` and
/// `target 21` are facts a reader needs, and the heading above them is one
/// they can infer from the rows.
///
/// Points' tray keeps a copy of its own — a different packet, already
/// shipped, whose trailing text is deliberately not uppercased.
class TrayLabel extends StatelessWidget {
  final String text;
  final String? trailing;

  const TrayLabel(this.text, {super.key, this.trailing});

  static const Color secondary = Color(0xFFB9CCC3);

  @override
  Widget build(BuildContext context) => Row(children: [
        Flexible(
          child: Text(text.toUpperCase(),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: secondary, fontSize: 10.5,
                  letterSpacing: 1.0, fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 10),
        if (trailing != null && trailing!.isNotEmpty)
          Flexible(
            child: Text(trailing!.toUpperCase(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                    color: secondary, fontSize: 11.5,
                    letterSpacing: 0.4, fontWeight: FontWeight.w700)),
          ),
      ]);
}
