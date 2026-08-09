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

  Future<void> _edit(Foursome fs) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _parse(fs.teeTime) ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null || !mounted) return;
    final hhmm = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';

    setState(() => _savingGroup = fs.groupNumber);
    try {
      final updated = await _client.setTeeTimes(widget.roundId, [
        {'group_number': fs.groupNumber, 'tee_time': hhmm},
      ]);
      if (!mounted) return;
      // Merge the server's echo back by group number (it may return the full
      // set or just the changed one — either way this is correct).
      final byGroup = {for (final f in updated) f.groupNumber: f};
      setState(() {
        _foursomes =
            _foursomes.map((f) => byGroup[f.groupNumber] ?? f).toList();
        _savingGroup = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Group ${fs.groupNumber} · ${_friendly(hhmm)} saved'),
        duration: const Duration(seconds: 1),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingGroup = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save tee time: $e')),
      );
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
                            onTap: _savingGroup == null
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
