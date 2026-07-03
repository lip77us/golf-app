import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import 'net_score_button.dart' show scoreCellWithDots;

/// Shared UI for the Irish Rumble **borrowed-4th phantom** — the threesome
/// leveling design (docs/irish-rumble.md).  A true threesome (3 real players in
/// a field that also has a foursome) is given a phantom 4th whose per-hole score
/// is borrowed from a fixed donor rotation over the whole field.  These widgets
/// surface that on the leaderboard and the threesome's score-entry screen.
///
/// The donor-by-hole block has the same JSON shape `build_phantom_info` emits
/// for Nassau / Triple Cup, so we reuse [NassauPhantomInfo] as the parsed model.

/// Parse an Irish Rumble overall row's `phantom` block, or null when the group
/// has no borrowed 4th (full foursomes, or a malformed block).
NassauPhantomInfo? borrowedFourthFromJson(dynamic raw) {
  if (raw is! Map) return null;
  try {
    return NassauPhantomInfo.fromJson(Map<String, dynamic>.from(raw));
  } catch (_) {
    return null;
  }
}

/// Number of holes whose donor has not yet posted (the provisional-total lag).
int pendingDonorHoles(NassauPhantomInfo info) =>
    info.byHole.values.where((h) => !h.hasScore).length;

/// A compact one-line explainer of the borrowed-4th mechanic.  Use on the
/// leaderboard (once, when any group has one) and on score entry.
class BorrowedFourthNote extends StatelessWidget {
  /// When set, names the holes still waiting on a donor.
  final int? pending;
  const BorrowedFourthNote({super.key, this.pending});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = (pending ?? 0) > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.groups_2_outlined,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(
                  text: 'Borrowed 4th. ',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const TextSpan(
                  text: 'A true threesome plays a 4th ball borrowed from the '
                      'rest of the field, so every group counts the same number '
                      'of balls.',
                ),
                if (waiting)
                  TextSpan(
                    text: ' $pending hole${pending == 1 ? '' : 's'} still '
                        'firming up as donors post.',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ]),
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-hole donor chips: which field player feeds each hole and whether they've
/// posted yet (posted = check, pending = clock).  Optionally highlights the
/// group's current hole.
class DonorByHoleStrip extends StatelessWidget {
  final NassauPhantomInfo info;
  final int? currentHole;
  const DonorByHoleStrip({super.key, required this.info, this.currentHole});

  @override
  Widget build(BuildContext context) {
    final holes = info.byHole.keys.toList()..sort();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final h in holes)
          _DonorChip(
            hole: h,
            donor: info.byHole[h]!,
            isCurrent: h == currentHole,
          ),
      ],
    );
  }
}

class _DonorChip extends StatelessWidget {
  final int hole;
  final NassauPhantomDonorHole donor;
  final bool isCurrent;
  const _DonorChip({
    required this.hole,
    required this.donor,
    required this.isCurrent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final posted = donor.hasScore;
    final fg = posted
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isCurrent
            ? theme.colorScheme.primaryContainer.withOpacity(0.4)
            : theme.colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isCurrent
              ? theme.colorScheme.primary.withOpacity(0.5)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$hole',
              style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold, color: fg)),
          const SizedBox(width: 4),
          Text(donor.shortName,
              style: theme.textTheme.labelSmall?.copyWith(color: fg)),
          const SizedBox(width: 3),
          Icon(
            posted ? Icons.check_circle : Icons.schedule,
            size: 12,
            color: posted
                ? Colors.green.shade600
                : theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// A compact 4th player row for a leveled threesome's score-entry screen: shows
/// the CURRENT hole's borrowed donor + their score (or a waiting clock until the
/// donor posts).  Fetches the Irish Rumble standings and reads this foursome's
/// donor-by-hole; renders nothing when the foursome has no borrowed-4th.
/// Re-fetches as the player advances holes.  Shared by the generic score-entry
/// and Pink Ball screens.
class BorrowedFourthRow extends StatefulWidget {
  final int roundId;
  final int foursomeId;
  final int currentHole;
  const BorrowedFourthRow({
    super.key,
    required this.roundId,
    required this.foursomeId,
    required this.currentHole,
  });

  @override
  State<BorrowedFourthRow> createState() => _BorrowedFourthRowState();
}

class _BorrowedFourthRowState extends State<BorrowedFourthRow> {
  NassauPhantomInfo? _info;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(covariant BorrowedFourthRow old) {
    super.didUpdateWidget(old);
    // Refresh as the player moves through holes (donors may have posted since).
    if (old.currentHole != widget.currentHole) _fetch();
  }

  Future<void> _fetch() async {
    try {
      final client = context.read<AuthProvider>().client;
      final data = await client.getIrishRumbleResult(widget.roundId);
      final overall = (data['overall'] as List? ?? []);
      Map<String, dynamic>? row;
      for (final r in overall) {
        if (r is Map && r['foursome_id'] == widget.foursomeId) {
          row = Map<String, dynamic>.from(r);
          break;
        }
      }
      final info = row == null ? null : borrowedFourthFromJson(row['phantom']);
      if (!mounted) return;
      setState(() { _info = info; _loaded = true; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (!_loaded || info == null) return const SizedBox.shrink();
    final donor = info.byHole[widget.currentHole];
    if (donor == null) return const SizedBox.shrink();
    return _BorrowedFourthRowTile(donor: donor);
  }
}

/// The single read-only row for the borrowed 4th: the current hole's donor
/// (full name, italic) + an Hcp bubble + the donor's gross (or a clock while
/// waiting).  Styled to read like a real player row, just italicised.
class _BorrowedFourthRowTile extends StatelessWidget {
  final NassauPhantomDonorHole donor;
  const _BorrowedFourthRowTile({required this.donor});

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final posted = donor.hasScore && donor.gross != null;
    final name   = donor.playerName.isNotEmpty ? donor.playerName : donor.shortName;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(children: [
        Icon(Icons.groups_2_outlined,
            size: 18, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Row(children: [
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            if (donor.hcp != null) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Text('Course ${donor.hcp}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSecondaryContainer,
                    )),
              ),
            ],
          ]),
        ),
        // Donor's stroke dots in a strip below the box (same as the real rows).
        scoreCellWithDots(
          Container(
            width: 40,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: posted
                ? Text('${donor.gross}',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontStyle: FontStyle.italic))
                : Icon(Icons.schedule,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
          ),
          posted ? donor.strokes : 0,
          theme.colorScheme.primary,
        ),
      ]),
    );
  }
}
