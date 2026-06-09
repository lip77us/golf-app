/// screens/support_lookup_screen.dart
/// -----------------------------------
/// Support-staff tool (gated on AuthProvider.isSupport): paste a watch link,
/// watch code, or round id to open ANY round's leaderboard READ-ONLY for
/// diagnosing a reported issue. The lookup is audited server-side.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../providers/auth_provider.dart';

class SupportLookupScreen extends StatefulWidget {
  const SupportLookupScreen({super.key});

  @override
  State<SupportLookupScreen> createState() => _SupportLookupScreenState();
}

class _SupportLookupScreenState extends State<SupportLookupScreen> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;
  Map<String, dynamic>? _result;

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty (no plain text).')));
      }
      return;
    }
    setState(() => _ctrl.text = text);
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
  }

  Future<void> _lookup() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() { _loading = true; _error = null; _result = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final r = await client.supportLookupRound(q);
      if (!mounted) return;
      setState(() { _result = r; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _loading = false; });
    } catch (_) {
      if (mounted) {
        setState(() { _error = 'Lookup failed — check the link or id.'; _loading = false; });
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Support — Open Round')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(
          'Read-only. Paste a watch link, watch code, or round ID. '
          'Every lookup is logged.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _ctrl,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Watch link / code / round ID',
            hintText: 'OA3R5LZS  ·  /watch/OA3R5LZS/  ·  495',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Paste',
              icon: const Icon(Icons.content_paste),
              onPressed: _paste,
            ),
          ),
          onSubmitted: (_) => _lookup(),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _loading ? null : _lookup,
          icon: _loading
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.search),
          label: const Text('Look up'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (r != null) ...[
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r['account_name']?.toString() ?? '—',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('${r['course_name'] ?? '—'} · ${r['date'] ?? ''}'),
                  Text('Status: ${r['status']} · '
                      '${r['num_foursomes']} foursome(s) · round #${r['round_id']}'),
                  if ((r['is_tournament'] ?? false) == true)
                    Text('Tournament: ${r['tournament_name'] ?? ''}'),
                  if ((r['active_games'] as List?)?.isNotEmpty == true)
                    Text('Games: ${(r['active_games'] as List).join(', ')}'),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed(
                        '/leaderboard', arguments: r['round_id'] as int),
                    icon: const Icon(Icons.leaderboard_outlined),
                    label: const Text('Open leaderboard (read-only)'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ]),
    );
  }
}
