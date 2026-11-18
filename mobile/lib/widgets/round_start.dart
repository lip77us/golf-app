/// The round view's pieces (`handoff-round-tournament-start`): the status
/// strip, the hero card for your group, the compact row for another group, and
/// the single Round settings row. Pure drawing — the screen owns the actions.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/halved_brand.dart';

TextStyle _head(double size, {Color color = Colors.white}) =>
    GoogleFonts.schibstedGrotesk(
        fontSize: size, fontWeight: FontWeight.w700, color: color);

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mons = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

/// `2026-11-17` → `Tue Nov 17`.
String dayLong(String date) {
  final d = DateTime.tryParse(date.length >= 10 ? date.substring(0, 10) : date);
  if (d == null) return date;
  return '${_days[d.weekday - 1]} ${_mons[d.month - 1]} ${d.day}';
}

/// `09:10:00` → `9:10`. Null/empty stays null.
String? teeShort(String? t) {
  if (t == null || t.isEmpty) return null;
  final p = t.split(':');
  if (p.length < 2) return t;
  final h = int.tryParse(p[0]);
  if (h == null) return t;
  return '$h:${p[1]}';
}

/// The dot beside a golfer's tee on the dark card.
Color teeDot(String? teeName) {
  final n = (teeName ?? '').toLowerCase();
  if (n.contains('black')) return const Color(0xFF111111);
  if (n.contains('blue')) return const Color(0xFF5B8FE0);
  if (n.contains('white')) return Colors.white;
  if (n.contains('gold') || n.contains('yellow')) return const Color(0xFFE8C14A);
  if (n.contains('red')) return const Color(0xFFE05B4B);
  if (n.contains('green')) return const Color(0xFF3BD89A);
  return const Color(0xFFBFD6CB);
}

class RoundStatusStrip extends StatelessWidget {
  final String text;
  final bool live;
  final String? chip;
  const RoundStatusStrip(
      {super.key, required this.text, required this.live, this.chip});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 12),
        child: Row(children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: live ? Halved.brightMint : const Color(0xFFF0B429)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Halved.body(color: Halved.muted, weight: FontWeight.w700)),
          ),
          if (chip != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Halved.cardBorder)),
              child: Text(chip!,
                  style: Halved.body(
                      color: Halved.deepPine, weight: FontWeight.w700)),
            ),
        ]),
      );
}

class HeroGolfer {
  final String name, initials, ch;
  final String? teeName;
  final bool me;
  const HeroGolfer(
      {required this.name,
      required this.initials,
      required this.ch,
      required this.teeName,
      required this.me});
}

/// Your group: the dark gradient card.
class RoundHero extends StatelessWidget {
  final String title;
  final bool yourGroupTag;
  final String? teeTime;
  final String gameLine;
  final List<HeroGolfer> golfers;

  /// The one big button: `Start round`, `Continue round ›`, `View scorecard`.
  final String? startLabel;
  final VoidCallback? onStart;

  /// The small link line (`Played it already?` / `Type in the card`).
  final VoidCallback? onTypeCard;

  const RoundHero({
    super.key,
    required this.title,
    required this.yourGroupTag,
    required this.teeTime,
    required this.gameLine,
    required this.golfers,
    this.startLabel,
    this.onStart,
    this.onTypeCard,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
            begin: Alignment(-0.3, -1),
            end: Alignment(0.3, 1),
            colors: [Color(0xFF0F6E56), Color(0xFF0B1F1A)]),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // The name and its tag shrink together as one unit: the name never
          // breaks across lines and the tee time keeps its place on the right.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(title, maxLines: 1, softWrap: false, style: _head(24)),
                if (yourGroupTag) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: Halved.brightMint,
                        borderRadius: BorderRadius.circular(14)),
                    child: Text('YOUR GROUP',
                        maxLines: 1,
                        style: Halved.body(
                                color: Halved.deepPine,
                                weight: FontWeight.w800)
                            .copyWith(fontSize: 11, letterSpacing: 0.6)),
                  ),
                ],
              ]),
            ),
          ),
          if (teeTime != null) ...[
            const SizedBox(width: 10),
            Text.rich(TextSpan(children: [
              TextSpan(text: 'tee ', style: Halved.body(color: Colors.white70)),
              TextSpan(text: teeTime, style: _head(20)),
            ])),
          ],
        ]),
        if (gameLine.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(gameLine, style: Halved.body(color: Colors.white70)),
        ],
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(16)),
          child: Column(children: [
            for (var i = 0; i < golfers.length; i++) ...[
              if (i > 0) Divider(height: 1, color: Colors.white.withOpacity(0.12)),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor: golfers[i].me
                        ? Halved.brightMint
                        : Colors.white.withOpacity(0.12),
                    child: Text(golfers[i].initials,
                        style: Halved.body(
                                color: golfers[i].me
                                    ? Halved.deepPine
                                    : Colors.white,
                                weight: FontWeight.w800)
                            .copyWith(fontSize: 12)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(golfers[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Halved.body(
                                color: Colors.white, weight: FontWeight.w700)
                            .copyWith(fontSize: 16)),
                  ),
                  if (golfers[i].teeName != null &&
                      golfers[i].teeName!.isNotEmpty) ...[
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: teeDot(golfers[i].teeName)),
                    ),
                    const SizedBox(width: 6),
                    Text(golfers[i].teeName!,
                        style: Halved.body(color: Colors.white70)),
                    const SizedBox(width: 12),
                  ],
                  Text(golfers[i].ch,
                      style: Halved.body(
                              color: Colors.white, weight: FontWeight.w700)
                          .copyWith(fontSize: 15)),
                ]),
              ),
            ],
          ]),
        ),
        if (startLabel != null) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                  backgroundColor: Halved.brightMint,
                  foregroundColor: Halved.deepPine,
                  shape: const StadiumBorder()),
              onPressed: onStart,
              icon: startLabel!.startsWith('Start')
                  ? const Icon(Icons.play_arrow_rounded, size: 28)
                  : const SizedBox.shrink(),
              label: Text(startLabel!,
                  style: Halved.body(weight: FontWeight.w800)
                      .copyWith(fontSize: 18)),
            ),
          ),
        ],
        if (onTypeCard != null) ...[
          const SizedBox(height: 12),
          Row(children: [
            Text('Played it already?',
                style: Halved.body(color: Colors.white70)),
            const Spacer(),
            InkWell(
              onTap: onTypeCard,
              child: Text('Type in the card',
                  style: Halved.body(
                          color: Colors.white, weight: FontWeight.w700)
                      .copyWith(decoration: TextDecoration.underline)),
            ),
          ]),
        ],
      ]),
    );
  }
}

/// Another group in a tournament round: one compact row.
class OtherGroupRow extends StatelessWidget {
  final String teeTime, groupTag, names, sub;
  final String? trailing;
  final bool live;
  final VoidCallback? onTap;
  const OtherGroupRow({
    super.key,
    required this.teeTime,
    required this.groupTag,
    required this.names,
    required this.sub,
    this.trailing,
    this.live = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Halved.cardBorder)),
              child: Row(children: [
                Container(
                  width: 58,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                      color: live ? Halved.deepPine : Halved.surface,
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(children: [
                    Text(teeTime,
                        style: _head(18,
                            color: live ? Colors.white : Halved.deepPine)),
                    Text(groupTag,
                        style: Halved.body(
                            color: live ? Colors.white70 : Halved.muted)),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(names,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _head(16, color: Halved.deepPine)),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Halved.body(color: Halved.muted)),
                  ]),
                ),
                if (trailing != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                        color: live ? const Color(0xFFE3F1E8) : Halved.surface,
                        borderRadius: BorderRadius.circular(18)),
                    child: Text(trailing!,
                        style: Halved.body(
                            color: live ? Halved.pine : Halved.muted,
                            weight: FontWeight.w700)),
                  ),
              ]),
            ),
          ),
        ),
      );
}

/// The one Round settings row.
class RoundSettingsRow extends StatelessWidget {
  final String summary;
  final VoidCallback onTap;
  const RoundSettingsRow({super.key, required this.summary, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Halved.cardBorder)),
              child: Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      color: const Color(0xFFE3F1E8),
                      borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.settings_outlined, color: Halved.pine),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Round settings', style: _head(17, color: Halved.deepPine)),
                    Text(summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Halved.body(color: Halved.muted)),
                  ]),
                ),
                const Icon(Icons.chevron_right, color: Halved.muted),
              ]),
            ),
          ),
        ),
      );
}
