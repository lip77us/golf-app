import 'package:flutter/material.dart';

import '../api/models.dart';

/// Tees at a course that a given player can play — matching sex plus any
/// unisex tees — sorted by (sort_priority, tee_name) so the "house default"
/// lands first.  Shared by the casual round setup tee step and the Edit Tee
/// Boxes screen so both order tees identically.
List<TeeInfo> teesForPlayer(List<TeeInfo> all, PlayerProfile p) {
  final tees = all.where((t) => t.sex == null || t.sex == p.sex).toList()
    ..sort((a, b) {
      final pc = a.sortPriority.compareTo(b.sortPriority);
      if (pc != 0) return pc;
      return a.teeName.compareTo(b.teeName);
    });
  return tees;
}

/// Shared tee-assignment UI: the given golfers grouped by sex, each group with
/// a prominent "Set all" bulk picker plus per-player overrides.  Used by both
/// casual round setup (step 3) and the Edit Tee Boxes hub screen so the picker
/// looks and behaves the same everywhere.
///
/// [picks] maps player id → tee id (0 / absent = unassigned).  [onChanged] is
/// called for each player whose tee changes (individually, or once per member
/// of a group when "Set all" is used).  [subtitle] renders an optional second
/// line under each name (e.g. "Index 12" or "Course Hcp 14 · Playing 15").
class TeeAssignmentList extends StatelessWidget {
  final List<PlayerProfile>            players;
  final List<TeeInfo>                  tees;
  final Map<int, int>                  picks;
  final void Function(int playerId, int teeId) onChanged;
  final String Function(PlayerProfile)? subtitle;

  const TeeAssignmentList({
    super.key,
    required this.players,
    required this.tees,
    required this.picks,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = [...players]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final byGroup = <String, List<PlayerProfile>>{};
    for (final p in selected) {
      byGroup.putIfAbsent(p.sex, () => []).add(p);
    }
    // Men, then Women, then anything else.  Sex codes are 'M' / 'W' (see
    // core.models.PlayerSex — Female is 'W', not 'F').
    final order = <String>[
      if (byGroup.containsKey('M')) 'M',
      if (byGroup.containsKey('W')) 'W',
      ...byGroup.keys.where((k) => k != 'M' && k != 'W'),
    ];
    String title(String sex) =>
        sex == 'M' ? 'Men' : sex == 'W' ? 'Women' : 'Other';

    Widget playerRow(PlayerProfile p) {
      final pt    = teesForPlayer(tees, p);
      final teeId = picks[p.id];
      final value = pt.any((t) => t.id == teeId) ? teeId : null;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                if (subtitle != null)
                  Text(subtitle!(p),
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          TeePicker(
            tees: pt,
            value: value,
            onChanged: (id) => onChanged(p.id, id),
          ),
        ]),
      );
    }

    final widgets = <Widget>[];
    for (final sex in order) {
      final group     = byGroup[sex]!;
      final groupTees = teesForPlayer(tees, group.first);
      final ids       = group.map((p) => picks[p.id]).toSet();
      final commonId  =
          ids.length == 1 && groupTees.any((t) => t.id == ids.first)
              ? ids.first
              : null;
      widgets.add(Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(title(sex),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (group.length > 1) ...[
                  Text('Set all',
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  // Flexible + isExpanded so a wide tee name ellipsizes
                  // instead of overflowing the header on a narrow phone.
                  Flexible(
                    child: TeePicker(
                      tees: groupTees,
                      value: commonId,
                      hint: 'Choose',
                      warn: false, // null here = "mixed", not an error
                      isExpanded: true,
                      onChanged: (id) {
                        for (final p in group) {
                          onChanged(p.id, id);
                        }
                      },
                    ),
                  ),
                ],
              ]),
              const Divider(),
              ...group.map(playerRow),
            ],
          ),
        ),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }
}

/// Prominent tee selector: a loud red "⚠ Pick tee" chip while a golfer has no
/// valid tee (so it can't be missed), or a normal chip showing the tee name +
/// yardage once set.  [warn] is off for the per-group "Set all" picker, where
/// an empty value just means the group's tees are mixed (not an error).
class TeePicker extends StatelessWidget {
  final List<TeeInfo>     tees;
  final int?              value; // null = unassigned / mixed
  final String            hint;
  final bool              warn;
  /// When true the dropdown fills its parent's width and the collapsed chip
  /// ellipsizes — used inside a Flexible so a wide tee name can't overflow a
  /// narrow row (e.g. the group "Set all" header).
  final bool              isExpanded;
  final ValueChanged<int> onChanged;

  const TeePicker({
    super.key,
    required this.tees,
    required this.value,
    required this.onChanged,
    this.hint = 'Pick tee',
    this.warn = true,
    this.isExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loud = value == null && warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: loud ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: loud ? scheme.error : scheme.outlineVariant,
          width: loud ? 1.5 : 1,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: value,
          isDense: true,
          isExpanded: isExpanded,
          borderRadius: BorderRadius.circular(8),
          hint: Row(mainAxisSize: MainAxisSize.min, children: [
            if (loud) ...[
              Icon(Icons.warning_amber_rounded,
                  size: 17, color: scheme.onErrorContainer),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(hint,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      color: loud
                          ? scheme.onErrorContainer
                          : scheme.onSurfaceVariant,
                      fontWeight: loud ? FontWeight.bold : FontWeight.w500)),
            ),
          ]),
          // Collapsed chip: compact (name + yardage).  The open menu shows the
          // full line with rating/slope so you can compare tees.
          selectedItemBuilder: (context) => tees
              .map((t) => Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      // Keep the collapsed chip compact (name + yardage) so the
                      // group-header row doesn't overflow on a narrow phone;
                      // par + rating/slope show in the open menu.
                      t.totalYards > 0
                          ? '${t.teeName} · ${t.totalYards}y'
                          : t.teeName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ))
              .toList(),
          items: tees
              .map((t) => DropdownMenuItem(
                    value: t.id,
                    child: Text(_teeLabel(t),
                        style: const TextStyle(fontSize: 14)),
                  ))
              .toList(),
          onChanged: (id) {
            if (id != null) onChanged(id);
          },
        ),
      ),
    );
  }

  /// Full tee label for the open menu: "White · 6412 yds · 71.7/125/par 72"
  /// — the rating/slope/par cluster is joined with slashes and the separators
  /// are single-spaced so the row fits on a narrow phone.  (Yardage is dropped
  /// when the tee has no per-hole data.)
  static String _teeLabel(TeeInfo t) {
    final rr =
        '${t.courseRating.toStringAsFixed(1)}/${t.slope}/par ${t.par}';
    return t.totalYards > 0
        ? '${t.teeName} · ${t.totalYards} yds · $rr'
        : '${t.teeName} · $rr';
  }
}
