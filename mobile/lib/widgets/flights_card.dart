/// widgets/flights_card.dart
///
/// The TD's Set-flights control: how many boards, who gets counted, and the
/// cut itself.
///
/// **Why the cut is an action and not a setting.** Flights are equal-sized, so
/// their sizing is a function of the whole field — every late entry and every
/// withdrawal resizes them. A flight frozen when each golfer enters cannot also
/// be equal-sized; the two rules contradict each other. So the freeze happens
/// once, when the field is final, and re-running it is a fresh cut rather than
/// a patch.
///
/// That is also why this lives on the championship screen rather than in the
/// new-round wizard, which the original plan suggested: the wizard runs before
/// the tournament exists and before pairings are set, so it has neither an id
/// to cut nor a field to cut.
///
/// **The preview is the point.** A cut is frozen once taken, so seeing the
/// split before committing is the difference between a decision and a
/// discovery. The server previews without writing.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import 'section_card.dart';

class FlightsCard extends StatefulWidget {
  final int tournamentId;
  /// Called after a cut or a clear, so the screen can reload anything that
  /// reads `flight_count`.
  final VoidCallback? onChanged;

  const FlightsCard({
    super.key,
    required this.tournamentId,
    this.onChanged,
  });

  @override
  State<FlightsCard> createState() => _FlightsCardState();
}

class _FlightsCardState extends State<FlightsCard> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy    = false;
  Object? _error;

  /// The count being previewed. 1 means one board.
  int _n = 2;
  /// Golfers the TD has named as holding a guessed index.
  final Set<int> _unindexed = {};

  /// Whether the cut is frozen because the field has started scoring. The
  /// SERVER decides this; see the note on the banner below.
  bool get _locked => _data?['locked'] == true;
  bool _namingOpen = false;

  @override
  void initState() {
    super.initState();
    _load(first: true);
  }

  Future<void> _load({bool first = false}) async {
    final api = context.read<AuthProvider>().client;
    try {
      final d = await api.getFlights(widget.tournamentId,
          nFlights: _n, unindexed: _unindexed.toList());
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
        if (first) {
          final cut = (d['flight_count'] as int?) ?? 0;
          _n = cut >= 2 ? cut : 2;
          _unindexed
            ..clear()
            ..addAll(((d['unindexed_at_cut'] as List?) ?? []).cast<int>());
        }
        _loading = false;
      });
      // The first load seeds `_n` from the stored cut, so the preview it just
      // fetched was for the wrong count. One more, and only ever one.
      if (first && ((d['flight_count'] as int?) ?? 0) >= 2) _load();
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _cut() async {
    final api = context.read<AuthProvider>().client;
    setState(() => _busy = true);
    try {
      await api.setFlights(widget.tournamentId,
          nFlights: _n, unindexed: _unindexed.toList());
      widget.onChanged?.call();
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_n == 1
              ? 'One board for everyone.'
              : 'Flights set — $_n boards, each paying its own places.'),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not set flights: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final api = context.read<AuthProvider>().client;
    setState(() => _busy = true);
    try {
      await api.clearFlights(widget.tournamentId);
      widget.onChanged?.call();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not clear flights: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    if (_loading) {
      return const SectionCard(
        title: 'Flights',
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(
              child: SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
      );
    }
    if (_error != null) {
      return SectionCard(
        title: 'Flights',
        child: Text('Could not load the field. $_error',
            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      );
    }

    final d          = _data!;
    final cut        = (d['flight_count'] as int?) ?? 0;
    final fieldSize  = (d['field_size'] as int?) ?? 0;
    final sizes      = ((d['preview_sizes'] as List?) ?? []).cast<int>();
    final field      = ((d['field'] as List?) ?? []).cast<Map>();
    final isCut      = cut >= 2;

    return SectionCard(
      title: 'Flights',
      trailing: isCut
          ? Chip(
              label: Text('$cut BOARDS',
                  style: const TextStyle(fontSize: 9.5)),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            )
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Splitting the field gives each flight its own board and its own '
          'payout — every flight pays the same table, so the event costs the '
          'table times the number of flights.',
          style: theme.textTheme.bodySmall?.copyWith(color: muted, height: 1.4),
        ),
        const SizedBox(height: 12),

        // ── How many boards ────────────────────────────────────────────────
        Wrap(spacing: 8, children: [
          for (final n in const [1, 2, 3])
            ChoiceChip(
              label: Text(n == 1 ? 'One board' : '$n flights'),
              selected: _n == n,
              onSelected: _busy ? null : (_) {
                setState(() => _n = n);
                _load();
              },
            ),
        ]),

        if (_n > 1) ...[
          const SizedBox(height: 12),
          // ── The preview ──────────────────────────────────────────────────
          // Cutting is frozen, so the split is shown BEFORE it is taken.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(isCut ? 'This cut would be' : 'The cut would be',
                  style: theme.textTheme.labelSmall?.copyWith(color: muted)),
              const SizedBox(height: 4),
              Text(
                [
                  for (var i = 0; i < sizes.length; i++)
                    '${String.fromCharCode(65 + i)} ${sizes[i]}'
                ].join('   ·   '),
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15),
              ),
              const SizedBox(height: 2),
              Text(
                '$fieldSize in the field'
                '${_unindexed.isEmpty ? '' : ' · ${_unindexed.length} not counted'}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ]),
          ),

          const SizedBox(height: 10),
          // ── Naming the guesses ───────────────────────────────────────────
          // The TD is the only one who knows whose number is invented; the
          // database cannot tell an entered index from an estimated one. A
          // named golfer drops out of the SIZING and goes to the bottom
          // flight, while the index he holds keeps giving him strokes.
          InkWell(
            onTap: () => setState(() => _namingOpen = !_namingOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(_namingOpen ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: muted),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _unindexed.isEmpty
                        ? 'Whose index is a guess?'
                        : '${_unindexed.length} named as a guess',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
          ),
          if (_namingOpen) ...[
            Text(
              'A named golfer is not counted in the split and goes to the '
              'bottom flight. He keeps the strokes his entered index gives '
              'him — this is only about where he is ranked.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: muted, height: 1.4),
            ),
            const SizedBox(height: 6),
            ...field.map((row) {
              final pid  = row['player_id'] as int;
              final name = row['name']?.toString() ?? '—';
              final idx  = row['index']?.toString();
              return CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _unindexed.contains(pid),
                onChanged: _busy ? null : (v) {
                  setState(() {
                    if (v == true) {
                      _unindexed.add(pid);
                    } else {
                      _unindexed.remove(pid);
                    }
                  });
                  _load();
                },
                title: Text(name, style: theme.textTheme.bodyMedium),
                secondary: Text(idx ?? '—',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              );
            }),
          ],
        ],

        const SizedBox(height: 12),
        // **Locked once the field has posted a score.** The server refuses it
        // either way; this is so a TD reads the reason instead of pressing a
        // button and being told no. Told by the server rather than counted
        // here — a client deriving it would be a second copy of the rule, and
        // would not know that a phantom's score does not lock a cut.
        if (_locked) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.lock_outline, size: 16, color: muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCut
                      ? 'The field has started playing under this cut, so it '
                        'cannot change. Re-cutting now would re-rank both '
                        'boards and move prize money under golfers who are '
                        'still on the course.'
                      : 'The field has started playing, so it can no longer '
                        'be cut. Flights have to be set before the first '
                        'score.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ]),
          ),
        ] else
          Row(children: [
            FilledButton(
              onPressed: _busy ? null : _cut,
              child: Text(isCut
                  ? (_n == 1 ? 'Back to one board' : 'Re-cut')
                  : (_n == 1 ? 'One board' : 'Set flights')),
            ),
            if (isCut) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _busy ? null : _clear,
                child: const Text('Clear'),
              ),
            ],
          ]),

        if (isCut && !_locked) ...[
          const SizedBox(height: 6),
          Text(
            'Set once pairings are final. Re-cutting is a fresh cut, not a '
            'patch — the sizing depends on the whole field.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ]),
    );
  }
}
