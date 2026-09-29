/// widgets/road_trip_board.dart
/// ---------------------------
/// The trip board: **best m of n, to par, with a Net and a Gross title.**
///
/// A golfer's row opens to a strip of every round, and the strip is the point
/// of the screen — a total tells you where you stand, and the strip tells you
/// what you are carrying and what you are throwing away. Four cell states,
/// drawn apart rather than shaded:
///
///   * **counted** — filled mint, the rounds making up the total
///   * **dropped** — struck through, outlined dashed. Shown, never hidden: a
///     golfer is entitled to see the round he is discarding
///   * **missed** — an em dash. He did not play a round that is finished
///   * **pending** — an empty dashed box. Nobody has played it yet, or he has
///     not finished it
///
/// The board has three sections and shows all three, because a trip's field
/// splits three ways: ranked, still qualifying, and not eligible. A golfer who
/// can no longer reach m is not removed — his rounds were real and his side
/// games still count — he simply has no claim on the title.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
import '../utils/stroke_play_standing.dart';

class RoadTripBoard extends StatefulWidget {
  final Map<String, dynamic> data;
  /// The signed-in golfer, whose row is marked.
  final int? readerId;

  const RoadTripBoard({super.key, required this.data, this.readerId});

  @override
  State<RoadTripBoard> createState() => _RoadTripBoardState();
}

class _RoadTripBoardState extends State<RoadTripBoard> {
  String _title = '';
  /// Which row is open. **One at a time** — the strip is wide and two open at
  /// once turns the board into a scroll with no board in it.
  int? _openPid;

  List<String> get _titles =>
      ((widget.data['titles'] as List?) ?? const []).cast<String>();

  Map<String, dynamic>? get _board {
    final b = widget.data[_title];
    return b is Map ? Map<String, dynamic>.from(b) : null;
  }

  List<Map<String, dynamic>> _rows(String key) =>
      ((_board?[key] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  @override
  void initState() {
    super.initState();
    _title = _titles.isNotEmpty ? _titles.first : 'net';
  }

  @override
  void didUpdateWidget(covariant RoadTripBoard old) {
    super.didUpdateWidget(old);
    // A silent refresh must not snap the reader back to the first title under
    // his thumb.
    if (!_titles.contains(_title) && _titles.isNotEmpty) {
      _title = _titles.first;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_titles.isEmpty || _board == null) {
      return const Center(child: Text('No scores yet.'));
    }
    final rounds = ((widget.data['rounds'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final played = rounds.where((r) => r['is_complete'] == true).length;
    final n = (widget.data['n_rounds'] as num?)?.toInt() ?? rounds.length;
    final m = (widget.data['counts'] as num?)?.toInt() ?? n;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        // **The switch appears only when both titles are on.** One title
        // needs no choosing, and a single-segment control is a control with
        // nothing to do.
        if (_titles.length > 1) ...[
          _TitleSwitch(
            titles: _titles,
            value : _title,
            onPick: (t) => setState(() {
              _title = t;
              // Switching resets the open row to the leader: the rounds a
              // golfer drops differ between the titles, so a strip left open
              // across the switch would be showing the other board's answer.
              _openPid = null;
            }),
          ),
          const SizedBox(height: 12),
        ],
        Row(children: [
          Text(m >= n ? 'All $n rounds · to par' : 'Best $m of $n · to par',
              style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(played >= n && n > 0 ? 'Final' : 'After round $played',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
        if (_board?['provisional'] == true) ...[
          const SizedBox(height: 10),
          _Note(m >= n
              ? 'Provisional until every golfer has finished all $n rounds.'
              : 'Every round counts until round $m. Rounds start dropping '
                'after that.'),
        ],
        const SizedBox(height: 12),
        _section(context, rounds, _rows('ranked'), header: true),
        _group(context, rounds, _rows('qualifying'),
            title: 'Still qualifying',
            note : 'Short of $m rounds, with enough left to get there.'),
        _group(context, rounds, _rows('ineligible'),
            title: 'Not eligible',
            note : "Can't finish $m rounds. Side games still count.",
            dim  : true),
        const SizedBox(height: 14),
        _legend(context),
      ],
    );
  }

  Widget _group(BuildContext context, List<Map<String, dynamic>> rounds,
      List<Map<String, dynamic>> rows,
      {required String title, required String note, bool dim = false}) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Text(title, style: theme.textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.bold)),
      Text(note, style: theme.textTheme.bodySmall
          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 6),
      _section(context, rounds, rows, dim: dim),
    ]);
  }

  Widget _section(BuildContext context, List<Map<String, dynamic>> rounds,
      List<Map<String, dynamic>> rows,
      {bool header = false, bool dim = false}) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final m = (widget.data['counts'] as num?)?.toInt() ?? rounds.length;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(children: [
          if (header)
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
              child: Row(children: [
                SizedBox(width: 34, child: Text('POS', style: _head(theme))),
                Expanded(child: Text('GOLFER', style: _head(theme))),
                Text('TO PAR', style: _head(theme)),
              ]),
            ),
          for (final r in rows)
            _Row(
              row     : r,
              rounds  : rounds,
              counts  : m,
              dim     : dim,
              isReader: r['player_id'] == widget.readerId,
              open    : _openPid == r['player_id'],
              onTap   : () => setState(() => _openPid =
                  _openPid == r['player_id'] ? null : r['player_id'] as int?),
            ),
        ]),
      ),
    );
  }

  TextStyle? _head(ThemeData theme) => theme.textTheme.labelSmall?.copyWith(
      fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.7,
      color: theme.colorScheme.onSurfaceVariant);

  Widget _legend(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget swatch(Widget box, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [box, const SizedBox(width: 5), Text(label, style: style)],
        );
    return Wrap(spacing: 14, runSpacing: 6, children: [
      swatch(
        Container(width: 10, height: 10,
            decoration: BoxDecoration(
                color: Halved.pine, borderRadius: BorderRadius.circular(3))),
        'Counts',
      ),
      swatch(
        Container(width: 10, height: 10,
            decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(3))),
        'Dropped',
      ),
      Text('– Missed', style: style),
      Text('Tap a golfer for rounds', style: style),
    ]);
  }
}

// ---------------------------------------------------------------------------

class _TitleSwitch extends StatelessWidget {
  final List<String> titles;
  final String value;
  final ValueChanged<String> onPick;
  const _TitleSwitch(
      {required this.titles, required this.value, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<String>(
      segments: [
        for (final t in titles)
          ButtonSegment(
            value: t,
            label: Text('${t == 'net' ? 'Net' : 'Gross'} Championship'),
          ),
      ],
      selected: {value},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onPick(s.first),
    );
  }
}

class _Row extends StatelessWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> rounds;
  final int counts;
  final bool dim;
  final bool isReader;
  final bool open;
  final VoidCallback onTap;

  const _Row({
    required this.row, required this.rounds, required this.counts,
    required this.dim, required this.isReader,
    required this.open, required this.onTap,
  });

  List<Map<String, dynamic>> get _cells =>
      ((row['cells'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  /// `5 played · 2 dropped`, or what is still needed.
  String _sub() {
    final played = (row['played'] as num?)?.toInt() ?? 0;
    final needs  = (row['needs'] as num?)?.toInt() ?? 0;
    if (needs > 0) {
      return row['rank'] == null && (row['total'] == null)
          ? '$played played · needs $needs more'
          : '$played played';
    }
    final counted =
        _cells.where((c) => c['state'] == 'counted').length;
    final dropped = played - counted;
    return '$played played · $dropped dropped';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rank  = row['rank'] as int?;
    final total = (row['total'] as num?)?.toInt();
    final lead  = rank == 1;
    return Opacity(
      opacity: dim ? 0.62 : 1,
      child: Column(children: [
        Divider(height: 1, color: theme.colorScheme.outlineVariant),
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
            child: Row(children: [
              SizedBox(
                width: 34,
                child: Text(
                  rank == null ? '' : '${row['tied'] == true ? 'T' : ''}$rank',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(row['name']?.toString() ?? '',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight:
                                    lead ? FontWeight.w700 : FontWeight.w500)),
                      ),
                      if (isReader) ...[
                        const SizedBox(width: 6),
                        _Tag(text: 'YOU', colour: theme.colorScheme.primary),
                      ],
                    ]),
                    Text(_sub(),
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Text(
                total == null ? '–' : toParLabel(total),
                style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: lead ? Halved.pine : theme.colorScheme.onSurface),
              ),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _RoundStrip(cells: _cells),
                if (row['tie_note'] != null) ...[
                  const SizedBox(height: 8),
                  Text('Tie decided on ${row['tie_note']}',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: Halved.pine, fontWeight: FontWeight.w600)),
                ],
              ],
            ),
          ),
      ]),
    );
  }
}

/// Every round, in order, as its own cell.
///
/// **A row per round, not a scroller.** Ten cells across a phone is 30pt each
/// — tight but readable — and the whole point is seeing the counted set at a
/// glance. A strip you have to scroll answers a different question.
class _RoundStrip extends StatelessWidget {
  final List<Map<String, dynamic>> cells;
  const _RoundStrip({required this.cells});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      for (final c in cells)
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: Column(children: [
              Text('R${c['round']}',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 9.5,
                      color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 3),
              _cell(context, c),
            ]),
          ),
        ),
    ]);
  }

  Widget _cell(BuildContext context, Map<String, dynamic> c) {
    final theme = Theme.of(context);
    final state = c['state']?.toString() ?? 'pending';
    final v = (c['to_par'] as num?)?.toInt();

    late final BoxDecoration deco;
    late final TextStyle? style;
    String text = v == null ? '' : toParLabel(v);

    switch (state) {
      case 'counted':
        deco = BoxDecoration(
            color: Halved.pine, borderRadius: BorderRadius.circular(6));
        style = theme.textTheme.labelSmall
            ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700);
        break;
      case 'dropped':
        deco = BoxDecoration(
            border: Border.all(color: theme.colorScheme.outline),
            borderRadius: BorderRadius.circular(6));
        style = theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            decoration: TextDecoration.lineThrough);
        break;
      case 'missed':
        deco = BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(6));
        style = theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        text = '–';
        break;
      default: // pending
        deco = BoxDecoration(
            border: Border.all(
                color: theme.colorScheme.outlineVariant,
                style: BorderStyle.solid),
            borderRadius: BorderRadius.circular(6));
        style = theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
        // A part-played round says how far, rather than a figure that reads
        // as a finished score.
        final holes = (c['holes'] as num?)?.toInt() ?? 0;
        text = holes > 0 ? '$holes' : '';
    }

    return Container(
      height: 26,
      alignment: Alignment.center,
      decoration: deco,
      child: Text(text, style: style),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color colour;
  const _Tag({required this.text, required this.colour});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: colour),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.w700, color: colour)),
      );
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: theme.textTheme.bodySmall?.copyWith(height: 1.45)),
    );
  }
}
