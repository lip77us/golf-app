/// screens/tee_times_screen.dart
/// The tee sheet — edit each group's tee time on an already-set-up round.
///
/// Reached from the round hub's "Round setup" section.  Each change persists
/// IMMEDIATELY via `setTeeTimes` — a non-destructive PATCH that only updates
/// `foursome.tee_time` (no re-setup, no effect on scores).  This is the live
/// counterpart to the tee-time pencil in the initial group builder, which only
/// saves as part of a full setup submit.
///
/// Nothing here is cup-specific — a Foursome Play round needs a tee sheet for
/// exactly the reason a cup does — so it serves both.
///
/// Three things a tee sheet has to do, all of which this screen used to skip:
///
///   * **Fill forward.**  Setting the first group's time should offer to lay
///     the rest out behind it at the standard interval.  Typing eighteen times
///     by hand when they are ten minutes apart is the app not listening.
///   * **Flag a collision.**  Two groups on the same time is a real mistake
///     with a real consequence at the first tee, and it is invisible until
///     somebody reads all six rows.  Warned, never blocked — a shotgun start
///     puts everybody out at once on purpose.
///   * **Read in play order.**  A tee sheet entered out of order is still a
///     tee sheet; it sorts by time so the row order is the order they go out.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';

/// Minutes between consecutive groups.  Matches the group builder's own
/// constant — a course property in the full design, a constant for now, so the
/// two screens propose the same spacing.
const int kTeeInterval = 10;

class TeeTimesScreen extends StatefulWidget {
  final int roundId;
  const TeeTimesScreen({super.key, required this.roundId});

  @override
  State<TeeTimesScreen> createState() => _TeeTimesScreenState();
}

class _TeeTimesScreenState extends State<TeeTimesScreen> {
  ApiClient get _client => context.read<AuthProvider>().client;

  bool           _loading = true;
  String?        _error;
  List<Foursome> _foursomes = [];
  int?           _savingGroup;   // group_number currently being saved
  bool           _busy = false;  // a batch (cascade) shift is in flight

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final round = await _client.getRound(widget.roundId);
      if (!mounted) return;
      setState(() {
        _foursomes = _inPlayOrder(round.foursomes);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  /// The order they actually go out: by tee time, then group number.
  ///
  /// Groups with no time yet sit at the BOTTOM rather than at midnight — an
  /// unset group has not been placed on the sheet, and floating it to the top
  /// would read as the first tee time of the day.
  List<Foursome> _inPlayOrder(List<Foursome> rows) {
    final out = [...rows];
    out.sort((a, b) {
      final ta = _parse(a.teeTime);
      final tb = _parse(b.teeTime);
      if (ta == null && tb == null) {
        return a.groupNumber.compareTo(b.groupNumber);
      }
      if (ta == null) return 1;
      if (tb == null) return -1;
      final byTime = _toMin(ta).compareTo(_toMin(tb));
      return byTime != 0 ? byTime : a.groupNumber.compareTo(b.groupNumber);
    });
    return out;
  }

  /// Group numbers sharing a tee time with at least one other group.
  ///
  /// Warned, never blocked: a shotgun start puts everybody out at once on
  /// purpose, and the app has no way to tell that from a slip.
  Set<int> get _clashing {
    final byTime = <String, List<int>>{};
    for (final f in _foursomes) {
      if (f.teeTime == null) continue;
      byTime.putIfAbsent(f.teeTime!, () => []).add(f.groupNumber);
    }
    return {
      for (final entry in byTime.entries)
        if (entry.value.length > 1) ...entry.value,
    };
  }

  TimeOfDay? _parse(String? hhmm) {
    if (hhmm == null) return null;
    final parts = hhmm.split(':');
    if (parts.length < 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _friendly(String? hhmm) {
    final t = _parse(hhmm);
    if (t == null) return 'Set time';
    final period = t.hour < 12 ? 'AM' : 'PM';
    final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h12:${t.minute.toString().padLeft(2, '0')} $period';
  }

  int _toMin(TimeOfDay t) => t.hour * 60 + t.minute;

  String _hhmm(int minutes) {
    final m = minutes.clamp(0, 24 * 60 - 1);
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  String _deltaLabel(int deltaMin) {
    final a = deltaMin.abs();
    final mag = a >= 60
        ? '${a ~/ 60}h${a % 60 == 0 ? '' : ' ${a % 60}m'}'
        : '$a min';
    return '$mag ${deltaMin > 0 ? 'later' : 'earlier'}';
  }

  /// PATCH [entries] ({group_number, tee_time}) and merge the echo back.
  Future<void> _persist(List<Map<String, dynamic>> entries) async {
    final updated = await _client.setTeeTimes(widget.roundId, entries);
    if (!mounted) return;
    final byGroup = {for (final f in updated) f.groupNumber: f};
    setState(() {
      // Re-sorted on every save, so a row moving IS the confirmation that the
      // running order changed.
      _foursomes = _inPlayOrder(
          _foursomes.map((f) => byGroup[f.groupNumber] ?? f).toList());
    });
  }

  Future<void> _edit(Foursome fs) async {
    final oldTod = _parse(fs.teeTime);
    final picked = await showTimePicker(
      context: context,
      initialTime: oldTod ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null || !mounted) return;
    final hhmm = _hhmm(_toMin(picked));

    setState(() => _savingGroup = fs.groupNumber);
    try {
      await _persist([{'group_number': fs.groupNumber, 'tee_time': hhmm}]);
      if (!mounted) return;
      setState(() => _savingGroup = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Group ${fs.groupNumber} · ${_friendly(hhmm)} saved'),
        duration: const Duration(seconds: 1),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingGroup = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save tee time: $e')));
      return;
    }

    if (!mounted) return;

    // Two different offers, and the old screen only made the second one —
    // which is why setting the FIRST time on a fresh round did nothing helpful.
    //
    //   fill  — later groups have no time yet. Lay them out behind this one at
    //           the standard interval, which is what a TD wants every time he
    //           sets group 1 on a new sheet.
    //   shift — later groups already have times. Move them by the same delta,
    //           keeping the spacing he already chose.
    final unset = _foursomes
        .where((f) => f.groupNumber > fs.groupNumber && f.teeTime == null)
        .toList()
      ..sort((a, b) => a.groupNumber.compareTo(b.groupNumber));

    if (unset.isNotEmpty) {
      await _offerFill(from: picked, groups: unset);
      return;
    }

    if (oldTod == null) return;
    final deltaMin = _toMin(picked) - _toMin(oldTod);
    final later = _foursomes
        .where((f) => f.groupNumber > fs.groupNumber && f.teeTime != null)
        .toList();
    if (deltaMin == 0 || later.isEmpty) return;

    final shift = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Shift later groups?'),
        content: Text(
          'Move the ${later.length} later group'
          '${later.length == 1 ? '' : 's'} ${_deltaLabel(deltaMin)} too, '
          'keeping the same spacing?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Just this group')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Shift the rest')),
        ],
      ),
    );
    if (shift != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final entries = <Map<String, dynamic>>[];
      for (final f in later) {
        final t = _parse(f.teeTime);
        if (t == null) continue;
        entries.add({
          'group_number': f.groupNumber,
          'tee_time'    : _hhmm(_toMin(t) + deltaMin),
        });
      }
      await _persist(entries);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${entries.length} later '
            'group${entries.length == 1 ? '' : 's'} shifted'),
        duration: const Duration(seconds: 1)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not shift later groups: $e')));
    }
  }

  /// Offer to lay the still-unset groups out behind [from] at a chosen
  /// interval. The TD picks the spacing on the dialog rather than getting a
  /// silent 10 — courses run 8, 9, 10 and 12 and he knows which is his.
  Future<void> _offerFill({
    required TimeOfDay from,
    required List<Foursome> groups,
  }) async {
    var interval = kTeeInterval;

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Set the rest?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${groups.length} group'
                   '${groups.length == 1 ? '' : 's'} still '
                   '${groups.length == 1 ? 'has' : 'have'} no tee time. Lay '
                   '${groups.length == 1 ? 'it' : 'them'} out behind this one?'),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('Every'),
                  const SizedBox(width: 10),
                  for (final m in const [8, 9, 10, 12])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text('$m'),
                        selected: interval == m,
                        onSelected: (_) => setLocal(() => interval = m),
                      ),
                    ),
                  const Text('min'),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                // Say what it will do, in the times themselves — the whole
                // point is that he does not have to work them out.
                _fillPreview(from, groups.length, interval),
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Just this group')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Set the rest')),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final entries = <Map<String, dynamic>>[];
      for (var i = 0; i < groups.length; i++) {
        entries.add({
          'group_number': groups[i].groupNumber,
          'tee_time'    : _hhmm(_toMin(from) + interval * (i + 1)),
        });
      }
      await _persist(entries);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${entries.length} group'
            '${entries.length == 1 ? '' : 's'} set, $interval min apart'),
        duration: const Duration(seconds: 1)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set the later groups: $e')));
    }
  }

  /// Names the groups that share a time, because "two groups clash" sends the
  /// TD back through every row to find out which.
  String _clashLabel() {
    final byTime = <String, List<int>>{};
    for (final f in _foursomes) {
      if (f.teeTime == null) continue;
      byTime.putIfAbsent(f.teeTime!, () => []).add(f.groupNumber);
    }
    final parts = [
      for (final e in byTime.entries)
        if (e.value.length > 1)
          'Groups ${e.value.join(' and ')} both go out at '
          '${_friendly(e.key)}',
    ];
    return '${parts.join('; ')}. Fine for a shotgun start — otherwise one of '
           'them needs moving.';
  }

  /// "8:10 AM, 8:20 AM, then 8:30 AM" — the first two and the last, because
  /// eighteen times in a dialog is not a preview.
  String _fillPreview(TimeOfDay from, int count, int interval) {
    String at(int n) => _friendly(_hhmm(_toMin(from) + interval * n));
    if (count == 1) return at(1);
    if (count == 2) return '${at(1)} and ${at(2)}';
    return '${at(1)}, ${at(2)} … ${at(count)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Edit tee times')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                      FilledButton(
                          onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        'Tap a group to change its start time. Changes save '
                        'immediately, and the sheet re-sorts into play order.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    if (_clashing.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                 size: 18, color: theme.colorScheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _clashLabel(),
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: theme.colorScheme.error),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _foursomes.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final fs = _foursomes[i];
                          final saving = _savingGroup == fs.groupNumber;
                          final clash  = _clashing.contains(fs.groupNumber);
                          return ListTile(
                            leading: Icon(
                              clash ? Icons.warning_amber_rounded
                                    : Icons.schedule,
                              color: clash ? theme.colorScheme.error : null,
                            ),
                            title: Text('Group ${fs.groupNumber}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            subtitle: clash
                                ? Text('Same time as another group',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme.colorScheme.error))
                                : (fs.teeTime == null
                                    ? Text('No time yet',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme.colorScheme
                                                  .onSurfaceVariant,
                                            ))
                                    : null),
                            trailing: saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(_friendly(fs.teeTime),
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            color: clash
                                                ? theme.colorScheme.error
                                                : null,
                                          )),
                                      const SizedBox(width: 6),
                                      Icon(Icons.edit,
                                          size: 16,
                                          color: theme
                                              .colorScheme.onSurfaceVariant),
                                    ],
                                  ),
                            onTap: (_savingGroup == null && !_busy)
                                ? () => _edit(fs)
                                : null,
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
