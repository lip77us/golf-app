/// widgets/field_progress_bar.dart
///
/// In `widgets/` rather than private to the leaderboard so the real thing
/// can be tested. The first version of its test reimplemented the widget's
/// own logic in the test file, which proves nothing — the copy agrees with
/// itself whatever the screen does.
library;

import 'package:flutter/material.dart';

import '../theme/halved_brand.dart';
/// How much of the field is actually on the board.
///
/// Paul, 3 Nov 2026: *"we can note on the Leaderboard how many foursomes are
/// manual."* Two facts, reported separately on purpose — a group on PAPER
/// will never enter its own scores, so it is the TD's job; a group that is
/// merely behind will catch up on its own. "No scores yet" cannot tell them
/// apart, and a reader wants to know which.
///
/// Silent once the field is in, which is the common case and the state a
/// reader should not have to scroll past a banner to reach.
class FieldProgressBar extends StatelessWidget {
  final Object? data;
  const FieldProgressBar({required this.data});

  @override
  Widget build(BuildContext context) {
    final m = data is Map<String, dynamic>
        ? data as Map<String, dynamic>
        : null;
    if (m == null) return const SizedBox.shrink();
    final awaiting = (m['awaiting'] as List?) ?? const [];
    if (awaiting.isEmpty) return const SizedBox.shrink();

    final paper = awaiting
        .where((r) => (r as Map)['paper_card'] == true)
        .toList();
    final theme = Theme.of(context);

    // Paper first, because it is the half somebody has to act on.
    final bits = <String>[];
    if (paper.isNotEmpty) {
      bits.add(paper.length == 1
          ? '1 group on paper'
          : '${paper.length} groups on paper');
    }
    final behind = awaiting.length - paper.length;
    if (behind > 0) {
      bits.add(behind == 1 ? '1 still out' : '$behind still out');
    }

    // Names the groups while there are few enough to be useful. A list of
    // eleven is not something anybody reads, and the count already said it.
    final named = awaiting.length <= 4
        ? awaiting
            .map((r) => '${(r as Map)['name']} (thru ${r['thru']})')
            .join(' · ')
        : null;

    return Material(
      color: Halved.cautionGround,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.hourglass_bottom, size: 16, color: Halved.caution),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text(
                '${bits.join(' · ')} of ${m['groups']} — '
                'the board is not final.',
                style: theme.textTheme.bodySmall?.copyWith(
                    color: Halved.caution, fontWeight: FontWeight.w600),
              ),
              if (named != null)
                Text(named,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: Halved.caution)),
            ]),
          ),
        ]),
      ),
    );
  }
}
