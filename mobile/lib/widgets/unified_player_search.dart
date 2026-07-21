/// unified_player_search.dart
///
/// One way into adding a golfer, not three.
///
/// The screens used to offer "My golfers", "Add Golfer" and "Halved search" as
/// three affordances at the same level, so you had to know which one would work
/// before you started typing.  This is the same three sources arranged as a
/// fallback ladder behind a single field: search your own golfers, then find
/// them on Halved, then create a guest.  You type a name; the answer appears
/// wherever it happens to live.
///
/// Design reference: turn 8a, "Unified smart add".
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/tokens.dart';

/// Local filtering is free, so it only waits long enough to not thrash the
/// widget tree mid-keystroke.
const _localDebounce = Duration(milliseconds: 300);

/// The Halved lookup is a network call against other people's data, so it waits
/// longer — long enough that typing a full name is one request, not six.
const _halvedDebounce = Duration(milliseconds: 500);

/// Shortest fragment the server will search on; below this it returns nothing
/// and says why, so there is no point asking.
const _minHalvedChars = 3;

/// Digits before we treat what's typed as a phone number rather than a name.
/// Seven is a local number without the area code — short enough to catch a
/// paste mid-typing, long enough that "5 iron" isn't a phone call.
const _minPhoneDigits = 7;

String _digitsOf(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// A query is a phone number when it is mostly digits and there are enough of
/// them.  Names don't survive this test; "+1 (415) 555-0101" does.
bool _looksLikePhone(String q) {
  final digits = _digitsOf(q);
  if (digits.length < _minPhoneDigits) return false;
  final letters = RegExp(r'[A-Za-z]').allMatches(q).length;
  return letters == 0;
}

class UnifiedPlayerSearch extends StatefulWidget {
  const UnifiedPlayerSearch({
    super.key,
    required this.roster,
    required this.selectedIds,
    required this.onToggle,
    required this.onGolferAdded,
    required this.onCreateGuest,
    this.requiredCount,
    this.gameLabel = '',
  });

  /// My Golfers — already loaded by the host screen.
  final List<PlayerProfile> roster;

  /// Ids currently in the round, so results can show their state.
  final Set<int> selectedIds;

  /// Select/deselect an existing roster golfer.
  final void Function(int playerId, bool selected) onToggle;

  /// A golfer joined the roster (pulled off Halved). The host adds them to its
  /// own list and selects them.
  final void Function(PlayerProfile added) onGolferAdded;

  /// "Create a guest golfer" — the bottom rung, when they aren't on Halved.
  final VoidCallback onCreateGuest;

  /// How many players the chosen game wants, when it is fixed. Drives the
  /// progress row; null hides it.
  final int? requiredCount;

  /// e.g. "FOURBALL" — the eyebrow above the progress row.
  final String gameLabel;

  @override
  State<UnifiedPlayerSearch> createState() => _UnifiedPlayerSearchState();
}

class _UnifiedPlayerSearchState extends State<UnifiedPlayerSearch> {
  final _ctrl = TextEditingController();
  Timer? _localTimer;
  Timer? _halvedTimer;

  String _query = '';
  List<Map<String, dynamic>> _halved = const [];
  bool _searchingHalved = false;
  /// Ids being added right now, so a double-tap can't add twice.
  final Set<int> _adding = {};

  @override
  void dispose() {
    _localTimer?.cancel();
    _halvedTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _localTimer?.cancel();
    _localTimer = Timer(_localDebounce, () {
      if (mounted) setState(() => _query = v.trim());
    });

    _halvedTimer?.cancel();
    final q = v.trim();
    if (_looksLikePhone(q)) {
      setState(() => _searchingHalved = true);
      _halvedTimer = Timer(_halvedDebounce, () => _lookupByPhone(q));
      return;
    }
    if (q.length < _minHalvedChars) {
      // Drop stale results immediately rather than leaving someone else's
      // match sitting under a query that no longer produced it.
      if (_halved.isNotEmpty || _searchingHalved) {
        setState(() {
          _halved = const [];
          _searchingHalved = false;
        });
      }
      return;
    }
    setState(() => _searchingHalved = true);
    _halvedTimer = Timer(_halvedDebounce, () => _searchHalved(q));
  }

  Future<void> _searchHalved(String q) async {
    final client = context.read<AuthProvider>().client;
    try {
      final rows = await client.searchHalvedUsersByName(q);
      // The field may have moved on while we were waiting.
      if (!mounted || _ctrl.text.trim() != q) return;
      setState(() {
        _halved = rows;
        _searchingHalved = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _halved = const [];
        _searchingHalved = false;
      });
    }
  }

  /// Phone lookup is an exact match on a full number, and it reaches members
  /// who have switched name search off — knowing the number is its own proof of
  /// connection. Results carry no `id`, which is how the Add button knows to
  /// create the golfer locally (we have the number) rather than asking the
  /// server to copy one across.
  Future<void> _lookupByPhone(String q) async {
    final client = context.read<AuthProvider>().client;
    try {
      final res = await client.lookupHalvedUser(q);
      if (!mounted || _ctrl.text.trim() != q) return;
      setState(() {
        _halved = res['found'] == true
            ? [
                {
                  'name': res['name'],
                  'short_name': res['short_name'],
                  'sex': res['sex'],
                  'handicap_index': res['handicap_index'],
                  'location': '',
                  'phone': q,
                }
              ]
            : const [];
        _searchingHalved = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _halved = const [];
        _searchingHalved = false;
      });
    }
  }

  /// Add a golfer we found by phone. The number is ours to keep — the owner
  /// typed it — so this is an ordinary roster create, not the server-side copy
  /// that name matches need.
  Future<void> _addFromPhone(Map<String, dynamic> row) async {
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<AuthProvider>().client;
    setState(() => _adding.add(-1)); // sentinel: phone rows have no id
    try {
      final added = await client.createPlayer(
        name: (row['name'] as String?) ?? 'Golfer',
        handicapIndex: (row['handicap_index'] as String?) ?? '0.0',
        phone: (row['phone'] as String?) ?? '',
        sex: (row['sex'] as String?) ?? 'M',
        shortName: row['short_name'] as String?,
      );
      if (!mounted) return;
      widget.onGolferAdded(added);
      setState(() {
        _halved = const [];
        _adding.remove(-1);
      });
      messenger.showSnackBar(
          SnackBar(content: Text('${added.name} added to My Golfers.')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _adding.remove(-1));
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not add that golfer.')));
    }
  }

  Future<void> _addFromHalved(Map<String, dynamic> row) async {
    final id = row['id'] as int?;
    if (id == null || _adding.contains(id)) return;
    final messenger = ScaffoldMessenger.of(context);
    final client = context.read<AuthProvider>().client;
    setState(() => _adding.add(id));
    try {
      final added = await client.addHalvedUserToRoster(id);
      if (!mounted) return;
      widget.onGolferAdded(added);
      setState(() {
        // They're in the roster now, so they belong under "Your golfers" —
        // leaving them in the Halved group would show them twice.
        _halved = _halved.where((r) => r['id'] != id).toList();
        _adding.remove(id);
      });
      messenger.showSnackBar(
          SnackBar(content: Text('${added.name} added to My Golfers.')));
    } catch (_) {
      if (!mounted) return;
      setState(() => _adding.remove(id));
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not add that golfer.')));
    }
  }

  List<PlayerProfile> get _localMatches {
    if (_query.isEmpty) return const [];
    final q = _query.toLowerCase();
    return widget.roster
        .where((p) => p.name.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final showResults = _query.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _RosterProgress(
          roster: widget.roster,
          selectedIds: widget.selectedIds,
          requiredCount: widget.requiredCount,
          gameLabel: widget.gameLabel,
        ),
        const SizedBox(height: GolfTokens.s12),
        TextField(
          controller: _ctrl,
          onChanged: _onChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'name or phone',
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear',
                    onPressed: () {
                      _ctrl.clear();
                      _onChanged('');
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
        if (showResults) ...[
          const SizedBox(height: GolfTokens.s12),
          _localGroup(),
          _halvedGroup(),
          _newGolferGroup(),
        ],
      ],
    );
  }

  Widget _localGroup() {
    final matches = _localMatches;
    if (matches.isEmpty) return const SizedBox.shrink();
    return _Group(
      label: 'YOUR GOLFERS',
      children: [
        for (final p in matches)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            value: widget.selectedIds.contains(p.id),
            onChanged: (v) => widget.onToggle(p.id, v ?? false),
            secondary: _Monogram(name: p.name, short: p.shortName),
            title: Text(p.name),
            subtitle: Text('Index ${p.handicapIndex}'),
          ),
      ],
    );
  }

  Widget _halvedGroup() {
    if (_searchingHalved) {
      return const _Group(
        label: 'ON HALVED',
        children: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: GolfTokens.s12),
            child: Row(children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: GolfTokens.s12),
              Text('Searching Halved…'),
            ]),
          ),
        ],
      );
    }
    if (_halved.isEmpty) return const SizedBox.shrink();
    return _Group(
      label: 'ON HALVED',
      children: [
        for (final row in _halved)
          Builder(builder: (context) {
            final id = row['id'] as int?;
            // A row from phone lookup has no id — we hold the number, so it is
            // added like any golfer the owner typed in themselves.
            final byPhone = id == null;
            final busy = _adding.contains(byPhone ? -1 : id);
            final loc = (row['location'] as String?) ?? '';
            final idx = (row['handicap_index'] as String?) ?? '';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: _Monogram(
                  name: (row['name'] as String?) ?? '',
                  short: (row['short_name'] as String?) ?? ''),
              title: Text((row['name'] as String?) ?? ''),
              subtitle: Text(
                  [if (idx.isNotEmpty) 'Index $idx', if (loc.isNotEmpty) loc]
                      .join(' · ')),
              trailing: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: () =>
                          byPhone ? _addFromPhone(row) : _addFromHalved(row),
                      child: const Text('Add')),
            );
          }),
      ],
    );
  }

  Widget _newGolferGroup() {
    return _Group(
      label: 'NEW GOLFER',
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_add_alt_1_outlined),
          title: const Text('Create a guest golfer'),
          subtitle: const Text('Not on Halved — you keep their handicap'),
          onTap: widget.onCreateGuest,
        ),
      ],
    );
  }
}

/// "FOURBALL · 2 of 4 added" plus a chip per seat. Progress rather than an
/// error banner: the old screen only spoke up once the count was wrong, which
/// made a half-filled round feel like a mistake instead of a work in progress.
class _RosterProgress extends StatelessWidget {
  const _RosterProgress({
    required this.roster,
    required this.selectedIds,
    required this.requiredCount,
    required this.gameLabel,
  });

  final List<PlayerProfile> roster;
  final Set<int> selectedIds;
  final int? requiredCount;
  final String gameLabel;

  @override
  Widget build(BuildContext context) {
    final chosen = roster.where((p) => selectedIds.contains(p.id)).toList();
    final need = requiredCount;
    final theme = Theme.of(context);
    final eyebrow = [
      if (gameLabel.isNotEmpty) gameLabel.toUpperCase(),
      need == null
          ? '${chosen.length} added'
          : '${chosen.length} of $need added',
    ].join(' · ');
    final remaining = need == null ? 0 : need - chosen.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(eyebrow,
                style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2, color: GolfTokens.inkMute)),
            if (remaining > 0)
              Text('Add $remaining more',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: GolfTokens.inkMute)),
          ],
        ),
        const SizedBox(height: GolfTokens.s8),
        Wrap(
          spacing: GolfTokens.s8,
          runSpacing: GolfTokens.s8,
          children: [
            for (final p in chosen)
              _SeatChip(label: p.shortName.isNotEmpty ? p.shortName : p.name),
            // Only draw empty seats for a fixed-size game; an open-ended round
            // has no "missing" players to imply.
            if (need != null)
              for (var i = 0; i < remaining; i++)
                const _SeatChip(label: 'Open', empty: true),
          ],
        ),
      ],
    );
  }
}

class _SeatChip extends StatelessWidget {
  const _SeatChip({required this.label, this.empty = false});

  final String label;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: GolfTokens.s12, vertical: GolfTokens.s8),
      decoration: BoxDecoration(
        color: empty ? Colors.transparent : GolfTokens.brandGreenSoft,
        border: Border.all(
            color: empty ? GolfTokens.lineSoft : GolfTokens.brandGreenSoft),
        borderRadius: BorderRadius.circular(GolfTokens.rPill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: empty ? GolfTokens.inkMute : GolfTokens.ink,
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: GolfTokens.s8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2, color: GolfTokens.inkMute),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, required this.short});

  final String name;
  final String short;

  @override
  Widget build(BuildContext context) {
    var label = short.trim();
    if (label.isEmpty) {
      final parts =
          name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
      label = parts.isEmpty
          ? '?'
          : parts.take(2).map((s) => s[0]).join().toUpperCase();
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: GolfTokens.brandGreenSoft,
      child: Text(label,
          style: const TextStyle(fontSize: 12, color: GolfTokens.ink)),
    );
  }
}
