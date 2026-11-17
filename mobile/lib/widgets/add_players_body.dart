/// The Add players screen's body (`handoff-add-players`): the seats, your
/// regulars, an always-open search, and the dark Add a new golfer card.
///
/// It owns nothing about the ROUND — the screen that hosts it holds who is
/// seated and decides what a tap means — so the same body serves casual setup
/// today and Select players and the cup's side later.
///
/// Rules live in `utils/add_players.dart`; this draws them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/add_players.dart';
import 'golfer_avatar.dart';
import 'halved_mark.dart';
import 'pool_sheet.dart';

/// A Halved member found by name or phone who is not in your golfers yet.
class HalvedHit {
  /// Name-search handle for `add-to-roster`, or null for a phone hit.
  final int? id;
  final String name;
  final String shortName;
  final String sex;
  final String handicapIndex;
  final String location;

  /// The number typed, for a phone hit — the key that ties the new roster row
  /// to the account.
  final String phone;

  const HalvedHit({
    this.id,
    required this.name,
    this.shortName = '',
    this.sex = 'M',
    this.handicapIndex = '0.0',
    this.location = '',
    this.phone = '',
  });
}

const Duration _halvedDebounce = Duration(milliseconds: 450);

class AddPlayersBody extends StatefulWidget {
  /// You — always seated first and never removable.
  final PlayerProfile? me;

  /// Everyone seated, in seat order (you first).
  final List<PlayerProfile> seated;

  /// Seats in this round, you included — or null for an OPEN-ENDED round
  /// (Multi-Group Skins), which has as many golfers as turn up: no empty seats
  /// are drawn, there is no "Full", and one open seat is always on offer.
  final int? seats;

  /// Golfers needed before Next (5–6 plays at either size; a pool needs two).
  final int minSeated;

  final String gameLabel;
  final List<PlayerProfile> roster;
  final RoundCounts counts;

  final ValueChanged<PlayerProfile> onAdd;
  final ValueChanged<PlayerProfile> onRemove;

  /// A Halved member was copied into your golfers; the host seats them.
  final ValueChanged<PlayerProfile> onHalvedAdded;

  /// The dark card: open the New golfer sheet, carrying what was typed.
  final ValueChanged<String> onNewGolfer;

  /// The eighth tile: open the All golfers sheet.
  final VoidCallback onAllGolfers;

  /// Tapping an index chip: open the index sheet for that golfer.
  final ValueChanged<PlayerProfile>? onEditIndex;

  /// The dark card: step through the seated golfers' indexes.
  final VoidCallback? onCheckIndexes;

  const AddPlayersBody({
    super.key,
    required this.me,
    required this.seated,
    required this.seats,
    int? minSeated,
    required this.gameLabel,
    required this.roster,
    required this.counts,
    required this.onAdd,
    required this.onRemove,
    required this.onHalvedAdded,
    required this.onNewGolfer,
    required this.onAllGolfers,
    this.onEditIndex,
    this.onCheckIndexes,
  }) : minSeated = minSeated ?? seats ?? 2;

  @override
  State<AddPlayersBody> createState() => _AddPlayersBodyState();
}

class _AddPlayersBodyState extends State<AddPlayersBody> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  String _query = '';
  List<HalvedHit> _halved = const [];
  bool _searching = false;

  /// A search that has returned for the CURRENT query. Without it a slow reply
  /// to "pe" would land under "pete" and offer the wrong golfers.
  String _answeredFor = '';
  final Set<String> _adding = {};

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Set<int> get _seatedIds => {for (final p in widget.seated) p.id};

  /// Whether another golfer can be seated: always, in an open-ended round.
  bool get _hasRoom =>
      widget.seats == null || widget.seated.length < widget.seats!;
  int? get _meId => widget.me?.id;

  /// The grid: the seven most played who are NOT seated yet. Choosing one
  /// takes him off the grid and the next most played takes his tile.
  List<PlayerProfile> get _regulars => regularsOf(
      widget.roster, widget.counts,
      meId: _meId, exclude: _seatedIds);

  void _onChanged(String v) {
    setState(() => _query = v);
    _debounce?.cancel();
    final q = v.trim();
    final byPhone = looksLikePhone(q);
    // A name needs three letters before it is worth a request; a number only
    // when it is complete, because a partial one cannot match an account.
    final worth = byPhone ? mobileComplete(q) : q.length >= 3;
    if (!worth) {
      setState(() {
        _halved = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(_halvedDebounce, () => _searchHalved(q, byPhone));
  }

  Future<void> _searchHalved(String q, bool byPhone) async {
    final client = context.read<AuthProvider>().client;
    try {
      final hits = <HalvedHit>[];
      if (byPhone) {
        final res = await client.lookupHalvedUser(q);
        if (res['found'] == true) {
          // A number you already have is a golfer of yours, found above.
          final mine = widget.roster.any((p) =>
              digitsOf(p.phone).isNotEmpty &&
              digitsOf(p.phone).endsWith(digitsOf(q).substring(
                  digitsOf(q).length >= 10 ? digitsOf(q).length - 10 : 0)));
          if (!mine) {
            hits.add(HalvedHit(
              name: (res['name'] as String?) ?? 'Golfer',
              shortName: (res['short_name'] as String?) ?? '',
              sex: (res['sex'] as String?) ?? 'M',
              handicapIndex: (res['handicap_index'] as String?) ?? '0.0',
              phone: q,
            ));
          }
        }
      } else {
        for (final r in await client.searchHalvedUsersByName(q)) {
          hits.add(HalvedHit(
            id: r['id'] as int?,
            name: (r['name'] as String?) ?? 'Golfer',
            shortName: (r['short_name'] as String?) ?? '',
            sex: (r['sex'] as String?) ?? 'M',
            handicapIndex: (r['handicap_index'] as String?) ?? '0.0',
            location: (r['location'] as String?) ?? '',
          ));
        }
      }
      if (!mounted || _query.trim() != q) return;
      setState(() {
        _halved = hits;
        _searching = false;
        _answeredFor = q;
      });
    } catch (_) {
      if (!mounted || _query.trim() != q) return;
      // The Halved half failing leaves your own golfers, which is the part
      // that was never going to be slow.
      setState(() {
        _halved = const [];
        _searching = false;
        _answeredFor = q;
      });
    }
  }

  Future<void> _addHalved(HalvedHit hit) async {
    final key = hit.id?.toString() ?? hit.phone;
    if (_adding.contains(key)) return;
    final client = context.read<AuthProvider>().client;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _adding.add(key));
    try {
      final PlayerProfile added = hit.id != null
          ? await client.addHalvedUserToRoster(hit.id!)
          : await client.createPlayer(
              name: hit.name,
              handicapIndex: hit.handicapIndex,
              phone: hit.phone,
              sex: hit.sex,
              shortName: hit.shortName,
            );
      if (!mounted) return;
      setState(() {
        _adding.remove(key);
        _halved = [for (final h in _halved) if (h != hit) h];
      });
      widget.onHalvedAdded(added);
    } catch (_) {
      if (!mounted) return;
      setState(() => _adding.remove(key));
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not add that golfer.')));
    }
  }

  /// After ticking a name, leave the query up but SELECTED, so the next
  /// keystroke replaces it.
  ///
  /// Clearing would be wrong: one search often matches two people worth taking,
  /// and the list has to stay narrowed while both get added. Focus comes back
  /// only when the keyboard is already up — someone who scrolled to read the
  /// results is not typing, and the keyboard springing back would be worse than
  /// the thing this fixes. (Every other picker does this; see
  /// `test/picker_reselect_search_test.dart`.)
  void _reselectSearch() {
    if (_ctrl.text.isEmpty) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0 && !_focus.hasFocus) {
      _focus.requestFocus();
    }
    _ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
  }

  void _toggle(PlayerProfile p) {
    if (_seatedIds.contains(p.id)) {
      if (p.id != _meId) widget.onRemove(p);
    } else if (_hasRoom) {
      widget.onAdd(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final regulars = _regulars;
    final q = _query.trim();
    final yours = searchYourGolfers(widget.roster, q,
        meId: _meId, counts: widget.counts);
    final everyone =
        allGolfersOf(widget.roster, widget.counts, meId: _meId).length;
    final showHalved = _halved.isNotEmpty && _answeredFor == q;
    final noMatch =
        q.isNotEmpty && yours.isEmpty && !showHalved && !_searching;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _seats(),
      if (widget.seated.isNotEmpty && widget.onCheckIndexes != null) ...[
        const SizedBox(height: 14),
        _checkCard(),
      ],
      const SizedBox(height: 22),
      _label('Your regulars', trailing: 'tap to add'),
      const SizedBox(height: 8),
      _regularsCard(regulars, everyone),
      const SizedBox(height: 22),
      _label('Search', trailing: 'your golfers + Halved'),
      const SizedBox(height: 8),
      _searchField(),
      const SizedBox(height: 10),
      if (q.isEmpty)
        Text('Your golfers first, then everyone on Halved. By name or phone.',
            style: Halved.body(color: Halved.muted).copyWith(fontSize: 12.5))
      else ...[
        if (yours.isNotEmpty) ...[
          _groupLabel('Your golfers'),
          for (final p in yours) _golferRow(p),
        ],
        if (showHalved) ...[
          _groupLabel('On Halved'),
          for (final h in _halved) _halvedRow(h),
        ],
        if (_searching && !showHalved)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(children: [
              const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('Looking on Halved…',
                  style: Halved.body(color: Halved.muted)
                      .copyWith(fontSize: 12.5)),
            ]),
          ),
        if (noMatch)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
                'Nobody in your golfers or on Halved by that name. '
                'Add them as a new golfer below.',
                style:
                    Halved.body(color: Halved.muted).copyWith(fontSize: 13)),
          ),
      ],
      const SizedBox(height: 14),
      _newGolferCard(q),
    ]);
  }

  // ── Seats ────────────────────────────────────────────────────────────────

  Widget _seats() {
    final seated = widget.seated;
    final seats = widget.seats;
    // Open-ended: one open seat, always — the pool is as many as turn up.
    final open = seats == null ? 1 : (seats - seated.length).clamp(0, seats);
    final header = seats == null
        ? openSeatsHeader(widget.gameLabel, seated.length)
        : seatsHeader(widget.gameLabel, seated.length, seats);
    final status = seats == null
        ? openSeatsStatus(seated.length, widget.minSeated)
        : seatsStatus(seated.length, seats);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(
            header,
            style: Halved.label(color: Halved.muted, weight: FontWeight.w700)
                .copyWith(fontSize: 11, letterSpacing: 0.7),
          ),
        ),
        if (status.isNotEmpty)
          Text(
            status,
            style: Halved.body(color: Halved.pine, weight: FontWeight.w600)
                .copyWith(fontSize: 13),
          ),
      ]),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, box) {
        // Seats are 56 wide with 14 between them.
        final perRow = ((box.maxWidth + 14) / 70).floor();
        // An open-ended round holds the seats to two lines; a fixed one has
        // at most six and never collapses.
        final lay = seats == null
            ? seatLayout(seated.length, perRow)
            : (visible: seated.length, hidden: 0);
        final shown = lay.hidden == 0
            ? seated
            : visibleSeated(seated, lay.visible, meId: _meId);
        return Wrap(spacing: 14, runSpacing: 12, children: [
          for (final p in shown) _seat(p),
          if (lay.hidden > 0) _moreSeat(lay.hidden),
          for (var i = 0; i < open; i++) _openSeat(),
        ]);
      }),
    ]);
  }

  Widget _checkCard() => Material(
        color: Halved.deepPine,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onCheckIndexes,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              const Icon(Icons.check, color: Halved.brightMint),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Check today’s indexes',
                      style: Halved.body(color: Colors.white, weight: FontWeight.w700)
                          .copyWith(fontSize: 16)),
                  Text(
                      'Step through ${widget.seated.length} golfer'
                      '${widget.seated.length == 1 ? '' : 's'}, one tap each',
                      style: Halved.body(color: Halved.cream.withOpacity(0.7))),
                ]),
              ),
              const Icon(Icons.chevron_right, color: Halved.brightMint),
            ]),
          ),
        ),
      );

  Widget _seat(PlayerProfile p) {
    final isMe = p.id == _meId;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: isMe ? null : () => widget.onRemove(p),
      child: SizedBox(
        width: 56,
        child: Column(children: [
          GolferAvatar(
              name: p.name,
              onHalved: p.isOnApp,
              index: p.handicapIndex,
              onIndexTap: () => widget.onEditIndex?.call(p)),
          const SizedBox(height: 10),
          Text(isMe ? 'You' : p.name.split(' ').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Halved.body(
                      color: Halved.deepPine, weight: FontWeight.w600)
                  .copyWith(fontSize: 12)),
        ]),
      ),
    );
  }

  /// The **+N more** tile: the golfers the two-line row had no room for, and
  /// the way into the sheet that lists and removes them.
  Widget _moreSeat(int hidden) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showPoolSheet(
          context,
          seated: () => widget.seated,
          meId: _meId,
          onRemove: widget.onRemove,
        ),
        child: SizedBox(
          width: 56,
          child: Column(children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                  shape: BoxShape.circle, color: Halved.deepPine),
              child: Text('+$hidden',
                  style: Halved.body(
                          color: Halved.brightMint, weight: FontWeight.w800)
                      .copyWith(fontSize: 14)),
            ),
            const SizedBox(height: 4),
            Text('more',
                style: Halved.body(
                        color: Halved.deepPine, weight: FontWeight.w600)
                    .copyWith(fontSize: 12)),
          ]),
        ),
      );

  Widget _openSeat() => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _focus.requestFocus(),
        child: SizedBox(
          width: 56,
          child: Column(children: [
            CustomPaint(
              painter: _DashedCircle(color: const Color(0xFFBFD6CB)),
              child: const SizedBox(
                width: 42,
                height: 42,
                child: Icon(Icons.add, size: 20, color: Halved.pine),
              ),
            ),
            const SizedBox(height: 4),
            Text('Open',
                style: Halved.body(color: Halved.muted).copyWith(fontSize: 12)),
          ]),
        ),
      );

  // ── Regulars ─────────────────────────────────────────────────────────────

  Widget _regularsCard(List<PlayerProfile> regulars, int everyone) {
    final tiles = <Widget>[
      for (final p in regulars) _regularTile(p),
      _allGolfersTile(everyone),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE7EDE8)),
      ),
      child: Column(children: [
        if (regulars.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                  'The golfers you play with most show up here after a few '
                  'finished rounds.',
                  style:
                      Halved.body(color: Halved.muted).copyWith(fontSize: 12.5)),
            ),
          ),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4, mainAxisExtent: 90, mainAxisSpacing: 4),
          children: tiles,
        ),
      ]),
    );
  }

  Widget _regularTile(PlayerProfile p) {
    // Never seated: a seated regular is no longer in the grid at all.
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _toggle(p),
      child: Column(mainAxisAlignment: MainAxisAlignment.start, children: [
        const SizedBox(height: 2),
        GolferAvatar(
            name: p.name,
            onHalved: p.isOnApp,
            size: 44,
            index: p.handicapIndex,
            onIndexTap: () => widget.onEditIndex?.call(p)),
        const SizedBox(height: 10),
        Text(p.name.split(' ').first,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Halved.body(color: Halved.deepPine, weight: FontWeight.w600)
                .copyWith(fontSize: 12)),
      ]),
    );
  }

  Widget _allGolfersTile(int count) => InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onAllGolfers,
        child: Column(children: [
          const SizedBox(height: 2),
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: Halved.deepPine),
            child: const Icon(Icons.chevron_right,
                color: Halved.brightMint, size: 24),
          ),
          const SizedBox(height: 4),
          Text('All golfers',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  Halved.body(color: Halved.deepPine, weight: FontWeight.w600)
                      .copyWith(fontSize: 12)),
          Text('$count',
              style: Halved.body(color: Halved.muted).copyWith(fontSize: 11)),
        ]),
      );

  // ── Search ───────────────────────────────────────────────────────────────

  Widget _searchField() => Container(
        height: 54,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Halved.pine, width: 1.5),
          boxShadow: const [
            BoxShadow(
                color: Color(0x1A0F6E56), blurRadius: 12, offset: Offset(0, 3)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
                color: Halved.deepPine,
                borderRadius: BorderRadius.circular(9)),
            alignment: Alignment.center,
            child: const HalvedMark(size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Find a golfer',
                hintStyle: Halved.body(color: Halved.muted),
                border: InputBorder.none,
                isCollapsed: true,
              ),
              style: Halved.body(color: Halved.deepPine)
                  .copyWith(fontSize: 16),
            ),
          ),
          if (_query.isNotEmpty)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                _ctrl.clear();
                _onChanged('');
              },
            ),
        ]),
      );

  Widget _golferRow(PlayerProfile p) {
    final seated = _seatedIds.contains(p.id);
    final played = widget.counts[p.id]?.rounds ?? 0;
    return _ResultRow(
      avatar: GolferAvatar(
          name: p.name,
          onHalved: p.isOnApp,
          size: 34,
          index: p.handicapIndex,
          onIndexTap: () => widget.onEditIndex?.call(p)),
      name: p.name,
      sub: playedLabel(played),
      added: seated,
      onTap: () {
        _toggle(p);
        // Only on the way IN: unseating by mistake should not disturb the
        // search that found them.
        if (!seated) _reselectSearch();
      },
    );
  }

  Widget _halvedRow(HalvedHit h) {
    final key = h.id?.toString() ?? h.phone;
    return _ResultRow(
      avatar: GolferAvatar(name: h.name, onHalved: true, size: 34),
      name: h.name,
      sub: h.location.isEmpty
          ? 'Index ${h.handicapIndex}'
          : 'Index ${h.handicapIndex} · ${h.location}',
      added: false,
      busy: _adding.contains(key),
      onTap: _hasRoom ? () => _addHalved(h) : null,
    );
  }

  // ── The dark card ────────────────────────────────────────────────────────

  Widget _newGolferCard(String q) => Material(
        color: Halved.deepPine,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => widget.onNewGolfer(q),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: const BoxDecoration(
                    shape: BoxShape.circle, color: Halved.brightMint),
                child: const Icon(Icons.add, color: Halved.deepPine, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(newGolferCardTitle(q),
                          style: Halved.sectionHead()
                              .copyWith(fontSize: 16, color: Colors.white)),
                      const SizedBox(height: 2),
                      Text('Not on Halved yet: name, index and mobile',
                          style: Halved.body(
                                  color: Colors.white.withValues(alpha: 0.65))
                              .copyWith(fontSize: 12.5)),
                    ]),
              ),
            ]),
          ),
        ),
      );

  // ── Small pieces ─────────────────────────────────────────────────────────

  Widget _label(String text, {String? trailing}) => Row(children: [
        Expanded(
          child: Text(text.toUpperCase(),
              style: Halved.label(color: Halved.muted, weight: FontWeight.w700)
                  .copyWith(fontSize: 11, letterSpacing: 0.7)),
        ),
        if (trailing != null)
          Text(trailing,
              style: Halved.body(color: Halved.muted).copyWith(fontSize: 12)),
      ]);

  Widget _groupLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Text(text.toUpperCase(),
            style: Halved.label(color: Halved.muted, weight: FontWeight.w700)
                .copyWith(fontSize: 10.5, letterSpacing: 0.8)),
      );
}

/// One golfer row with an **Add** pill that turns solid pine reading **Added**.
class AddPlayersResultRow extends StatelessWidget {
  final Widget avatar;
  final String name;
  final String sub;
  final bool added;
  final bool busy;
  final VoidCallback? onTap;

  const AddPlayersResultRow({
    super.key,
    required this.avatar,
    required this.name,
    required this.sub,
    required this.added,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => _ResultRow(
      avatar: avatar,
      name: name,
      sub: sub,
      added: added,
      busy: busy,
      onTap: onTap);
}

class _ResultRow extends StatelessWidget {
  final Widget avatar;
  final String name;
  final String sub;
  final bool added;
  final bool busy;
  final VoidCallback? onTap;

  const _ResultRow({
    required this.avatar,
    required this.name,
    required this.sub,
    required this.added,
    this.busy = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: busy ? null : onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE7EDE8)),
              ),
              child: Row(children: [
                avatar,
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Halved.body(
                                    color: Halved.deepPine,
                                    weight: FontWeight.w600)
                                .copyWith(fontSize: 15)),
                        Text(sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Halved.body(color: Halved.muted)
                                .copyWith(fontSize: 12)),
                      ]),
                ),
                const SizedBox(width: 8),
                busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _pill(),
              ]),
            ),
          ),
        ),
      );

  Widget _pill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: added ? Halved.pine : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Halved.pine),
        ),
        child: Text(added ? 'Added' : 'Add',
            style: Halved.body(
                    color: added ? Colors.white : Halved.pine,
                    weight: FontWeight.w700)
                .copyWith(fontSize: 13)),
      );
}

class _DashedCircle extends CustomPainter {
  final Color color;
  const _DashedCircle({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()..addOval(Offset.zero & size);
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, d + 4), paint);
        d += 7;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedCircle old) => old.color != color;
}
