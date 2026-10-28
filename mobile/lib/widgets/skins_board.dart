import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/skin_rules_display.dart';
import '../utils/skins_board_model.dart';

/// The skins board — ONE widget for every skins leaderboard.
///
/// Built from `~/Downloads/handoff-skins-leaderboard`, whose first instruction
/// is the important one: *"one widget used by every Skins leaderboard (casual,
/// multi-group, side game tabs). Do not draw a second skins table anywhere."*
/// Both summaries reach it through `SkinsBoardData`, so neither this widget
/// nor the callers have to know which produced it.
///
/// Three cards, top to bottom: what the next hole is worth, where the skins
/// went, and what everyone is owed.
class SkinsBoard extends StatelessWidget {
  const SkinsBoard({super.key, required this.data});

  final SkinsBoardData data;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data.showNext) ...[
          _UpNext(data: data),
          const SizedBox(height: 12),
        ],
        _HolesCard(data: data),
        const SizedBox(height: 12),
        _Ledger(data: data),
      ],
    );
  }
}

// ── money ───────────────────────────────────────────────────────────────────

/// `+$14`, `−$6`, `$0`. A true minus sign (U+2212), not a hyphen: at this size
/// beside a `+` the hyphen is visibly the wrong length, which the Nassau money
/// line already had to be fixed for.
String _money(double v) {
  final a = v.abs();
  final n = a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
  if (v == 0) return '\$0';
  return '${v > 0 ? '+' : '−'}\$$n';
}

String _plain(double v) {
  final a = v.abs();
  return a % 1 == 0 ? a.toStringAsFixed(0) : a.toStringAsFixed(2);
}

// ── 1 · up next ─────────────────────────────────────────────────────────────

class _UpNext extends StatelessWidget {
  const _UpNext({required this.data});
  final SkinsBoardData data;

  /// `Hole 4 carried in` · `11 and 12 carried in` · `No carry`.
  String _carriedLine() {
    final c = data.carriedInHoles;
    if (c.isEmpty) return 'No carry';
    if (c.length == 1) return 'Hole ${c.first} carried in';
    return '${c.take(c.length - 1).join(', ')} and ${c.last} carried in';
  }

  @override
  Widget build(BuildContext context) {
    final over = data.roundOver;
    final next = data.nextHole;
    // A finished round has no hole in play, so the tile shows the last one
    // rather than inventing a 19th — the same rule the lock screens follow.
    final tileNo = over
        ? (data.holes.isEmpty ? '' : '${data.holes.last.hole}')
        : '${next?.hole ?? ''}';
    final par = over ? null : next?.par;

    final riding = data.skinsRiding;
    final unclaimed = data.unclaimedAtEnd;

    final headline = over ? '${data.totalSkinsWon}' : '$riding';
    final sub = over
        ? 'skins won'
        : 'skin${riding == 1 ? '' : 's'} · '
          '\$${_plain(riding * data.stake * (data.golfers.length - 1))}';

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(
            color: over ? Halved.cardBorder : Halved.deepPine, width: over ? 1.5 : 2),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Container(
          width: 46, height: 46,
          decoration: BoxDecoration(
            color: Halved.deepPine,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tileNo,
                style: const TextStyle(
                    color: Colors.white, fontSize: 20,
                    fontWeight: FontWeight.w700, height: 1)),
            if (par != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Par $par',
                    style: const TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w600,
                        color: Color(0xFFB9CCC3), height: 1)),
              ),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(over ? 'Round over' : 'Up next',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                over
                    ? (unclaimed > 0
                        ? '$unclaimed skin${unclaimed == 1 ? '' : 's'} unclaimed '
                          'on the last hole${unclaimed == 1 ? '' : 's'}'
                        : 'Every skin was won')
                    : _carriedLine(),
                style: const TextStyle(fontSize: 12.5, color: Halved.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(headline,
                style: TextStyle(
                    fontSize: 30, fontWeight: FontWeight.w700, height: 1,
                    color: over ? Halved.muted : Halved.pine)),
            const SizedBox(height: 3),
            Text(sub,
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600,
                    color: Halved.muted)),
          ],
        ),
      ]),
    );
  }
}

// ── 2 · the holes ───────────────────────────────────────────────────────────

class _HolesCard extends StatelessWidget {
  const _HolesCard({required this.data});
  final SkinsBoardData data;

  @override
  Widget build(BuildContext context) {
    // The GRID reads by hole number — a scorecard is a scorecard, whatever
    // order the group played it in. Only the walk follows play order.
    final byNumber = [...data.holes]..sort((a, b) => a.hole.compareTo(b.hole));
    final rows = <List<SkinsBoardHole>>[];
    for (var i = 0; i < byNumber.length; i += 9) {
      rows.add(byNumber.sublist(i, (i + 9).clamp(0, byNumber.length)));
    }
    final nextHole = data.nextHole?.hole;

    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const _Label('HOLES'),
          _Label(data.carry
              ? '${data.basis.toUpperCase()} · CARRIES ON'
              : data.basis.toUpperCase()),
        ]),
        const SizedBox(height: 8),
        for (final row in rows) ...[
          Row(children: [
            for (final h in row)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _HoleTile(
                    hole: h,
                    isNext: h.hole == nextHole,
                    riding: data.skinsRiding,
                  ),
                ),
              ),
          ]),
          if (row != rows.last) const SizedBox(height: 4),
        ],
        // The validation rules live here, under the grid, because they are a
        // footnote ON the grid: they decide what it takes for one of these
        // tiles to be won at all, which is why a hole can end up carried with
        // nobody tied.
        if (data.rulesLine.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(skinRuleChips(data.rulesLine).join(' · '),
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600,
                  color: Halved.pine)),
          const SizedBox(height: 2),
          const Text('A hole where nobody qualifies goes unwon.',
              style: TextStyle(fontSize: 11.5, color: Halved.muted)),
        ],
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text,
      style: const TextStyle(
          fontSize: 11.5, fontWeight: FontWeight.w700,
          letterSpacing: .4, color: Halved.muted));
}

class _HoleTile extends StatelessWidget {
  const _HoleTile(
      {required this.hole, required this.isNext, required this.riding});
  final SkinsBoardHole hole;
  final bool isNext;
  final int riding;

  @override
  Widget build(BuildContext context) {
    final won = hole.isWon;
    final colour = won ? Halved.golfer(hole.colourOf ?? 0) : null;

    // `×N` says what a tile PAID, and on the next hole what is riding on it.
    final multiplier = won
        ? (hole.value > 1 ? '×${hole.value}' : null)
        : (isNext && riding > 1 ? '×$riding' : null);

    late final BoxDecoration deco;
    late final Color fg;
    if (won) {
      deco = BoxDecoration(color: colour, borderRadius: BorderRadius.circular(6));
      fg = Colors.white;
    } else if (isNext) {
      deco = BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.deepPine, width: 2),
        borderRadius: BorderRadius.circular(6),
      );
      fg = Halved.deepPine;
    } else if (hole.played) {
      // Tied — carried, or killed when carry is off. Either way nobody took it.
      deco = BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.muted, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      );
      fg = Halved.muted;
    } else {
      deco = BoxDecoration(
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      );
      fg = Halved.cardBorder;
    }

    return Container(
      height: 34,
      decoration: deco,
      alignment: Alignment.center,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${hole.hole}',
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: fg, height: 1.1)),
        if (multiplier != null)
          Text(multiplier,
              style: TextStyle(
                  fontSize: 9.5, fontWeight: FontWeight.w600,
                  color: fg, height: 1.1)),
      ]),
    );
  }
}

// ── 3 · the ledger ──────────────────────────────────────────────────────────

class _Ledger extends StatelessWidget {
  const _Ledger({required this.data});
  final SkinsBoardData data;

  @override
  Widget build(BuildContext context) {
    final over = data.roundOver;
    return Container(
      decoration: BoxDecoration(
        color: Halved.card,
        border: Border.all(color: Halved.cardBorder, width: 1.5),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          color: Halved.deepPine,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(over ? 'Final, each' : 'Each · now',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFFB9CCC3))),
              const Spacer(),
              Text('\$${_plain(data.stake)} a skin',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w700,
                      color: Colors.white)),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Row(children: [
            Expanded(child: _Label('PLAYER')),
            _Label('SKINS'),
            SizedBox(width: 72, child: Align(
                alignment: Alignment.centerRight, child: _Label('\$'))),
          ]),
        ),
        for (final g in data.ledger) _LedgerRow(golfer: g),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          color: Halved.deepPine,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(children: [
            Text.rich(TextSpan(children: [
              const TextSpan(text: 'Won '),
              TextSpan(
                  text: '${data.totalSkinsWon} of ${data.holesPlayed}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ]), style: const TextStyle(
                fontSize: 12.5, color: Color(0xFFB9CCC3))),
            const SizedBox(width: 14),
            if (over)
              const Text('Final',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFFB9CCC3)))
            else
              Text.rich(TextSpan(children: [
                const TextSpan(text: 'Left '),
                TextSpan(
                    text: '${data.holesLeft} holes',
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
              ]), style: const TextStyle(
                  fontSize: 12.5, color: Color(0xFFB9CCC3))),
          ]),
        ),
      ]),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.golfer});
  final SkinsBoardGolfer golfer;

  @override
  Widget build(BuildContext context) {
    final colour = Halved.golfer(golfer.colourIndex);
    final up = golfer.net > 0;

    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                    color: colour, borderRadius: BorderRadius.circular(3)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(golfer.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
          // One tick per skin he is PAID ON — hole skins filled, junk
          // outlined. Junk is one share of the same pot, so leaving it out
          // would print a count that does not match the money beside it.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: golfer.totalSkins == 0
                ? const Text('0',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: Halved.muted))
                : Wrap(
                    spacing: 3, runSpacing: 3,
                    alignment: WrapAlignment.end,
                    children: [
                      for (var i = 0; i < golfer.skinsWon; i++)
                        _Tick(colour: colour, filled: true),
                      for (var i = 0; i < golfer.junkSkins; i++)
                        _Tick(colour: colour, filled: false),
                    ],
                  ),
          ),
          SizedBox(
            width: 72,
            child: Align(
              alignment: Alignment.centerRight,
              child: up
                  ? Container(
                      decoration: BoxDecoration(
                        color: Halved.brightMint,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      child: Text(_money(golfer.net),
                          style: const TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w700,
                              color: Halved.deepPine)),
                    )
                  : Text(_money(golfer.net),
                      style: const TextStyle(
                          fontSize: 19, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Tick extends StatelessWidget {
  const _Tick({required this.colour, required this.filled});
  final Color colour;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
        width: 10, height: 18,
        decoration: BoxDecoration(
          color: filled ? colour : Colors.transparent,
          border: filled ? null : Border.all(color: colour, width: 1.5),
          borderRadius: BorderRadius.circular(3),
        ),
      );
}
