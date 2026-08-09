/// screens/cup_tee_times_screen.dart
/// Edit each group's tee time on an already-set-up cup round.
///
/// Reached from the round hub's "Round setup" section.  Each change persists
/// IMMEDIATELY via `setTeeTimes` — a non-destructive PATCH that only updates
/// `foursome.tee_time` (no re-setup, no effect on scores).  This is the live
/// counterpart to the tee-time pencil in the initial group builder, which only
/// saves as part of a full setup submit.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';

class CupTeeTimesScreen extends StatefulWidget {
  final int roundId;
  const CupTeeTimesScreen({super.key, required this.roundId});

  @override
  State<CupTeeTimesScreen> createState() => _CupTeeTimesScreenState();
}

class _CupTeeTimesScreenState extends State<CupTeeTimesScreen> {
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
        _foursomes = [...round.foursomes]
          ..sort((a, b) => a.groupNumber.compareTo(b.groupNumber));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
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
      _foursomes =
          _foursomes.map((f) => byGroup[f.groupNumber] ?? f).toList();
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

    // Offer to shift every later group by the same amount, so the TD doesn't
    // have to move each remaining group by hand (only when the time actually
    // moved and there are later groups with a time to shift).
    if (oldTod == null || !mounted) return;
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
                        'immediately.',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _foursomes.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final fs = _foursomes[i];
                          final saving = _savingGroup == fs.groupNumber;
                          return ListTile(
                            leading: const Icon(Icons.schedule),
                            title: Text('Group ${fs.groupNumber}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
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
                                          style: theme.textTheme.titleMedium),
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
