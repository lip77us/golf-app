/// The New golfer sheet (`handoff-add-players`).
///
/// One sheet for every way a golfer is created — the Add players screen's dark
/// card and My Golfers' add — so the rules cannot differ between them.
///
/// **It creates the golfer itself** and pops the result, rather than returning
/// a draft for the caller to save: the New golfer sheet has to be able to say
/// "that number is already on Halved" before anything is written, and what it
/// writes then depends on the answer (a guest, or the real account's golfer).
///
/// Removed in review, and not to be added back: the tee choice, an index
/// slider, a message preview, and *Add without a number*.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart' show ApiException;
import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../theme/halved_brand.dart';
import '../utils/add_players.dart';
import 'golfer_avatar.dart';

class NewGolferResult {
  final PlayerProfile player;

  /// A number was entered, so the game is texted at Start round.
  final bool hasNumber;

  /// The real Halved account was used instead of creating a guest.
  final bool viaAccount;

  /// **No golfer was created**: he was already in your list and the sheet's
  /// warning sent you to him instead. [player] is the existing golfer.
  final bool existing;

  const NewGolferResult(this.player,
      {required this.hasNumber, required this.viaAccount, this.existing = false});
}

/// Opens the sheet. [myIndex] and [slope] drive the strokes line against YOUR
/// index at this round's tees; with no [myIndex] the line is not shown (My
/// Golfers has no round to measure against).
///
/// [roster] is who you already have: the sheet warns when the name or mobile
/// being added matches one of them. [counts] only adds *played 5 times* to that
/// warning. [allowUseExisting] is false where there is nothing to seat him in
/// (My Golfers), so the warning has no button.
Future<NewGolferResult?> showNewGolferSheet(
  BuildContext context, {
  String seed = '',
  double? myIndex,
  int slope = 113,
  List<PlayerProfile> roster = const [],
  RoundCounts counts = const {},
  bool allowUseExisting = true,
}) {
  return showModalBottomSheet<NewGolferResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x730B1F1A),
    builder: (_) => NewGolferSheet(
      seed: seed,
      myIndex: myIndex,
      slope: slope,
      roster: roster,
      counts: counts,
      allowUseExisting: allowUseExisting,
    ),
  );
}

class NewGolferSheet extends StatefulWidget {
  final String seed;
  final double? myIndex;
  final int slope;
  final List<PlayerProfile> roster;
  final RoundCounts counts;
  final bool allowUseExisting;

  const NewGolferSheet({
    super.key,
    this.seed = '',
    this.myIndex,
    this.slope = 113,
    this.roster = const [],
    this.counts = const {},
    this.allowUseExisting = true,
  });

  @override
  State<NewGolferSheet> createState() => _NewGolferSheetState();
}

class _NewGolferSheetState extends State<NewGolferSheet> {
  late final TextEditingController _name;
  late final TextEditingController _index = TextEditingController();
  late final TextEditingController _mobile;

  /// The Halved account whose number was typed, once looked up.
  Map<String, dynamic>? _account;
  String _lookedUp = '';
  bool _busy = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final seed = newGolferSeed(widget.seed);
    _name = TextEditingController(text: seed.name);
    _mobile = TextEditingController(text: seed.mobile);
    if (mobileComplete(seed.mobile)) _lookup();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _index.dispose();
    _mobile.dispose();
    super.dispose();
  }

  bool get _nameOk => capitalizeName(_name.text).isNotEmpty;

  List<DuplicateGolfer> get _dupes => findDuplicateGolfers(widget.roster,
      name: _name.text, mobile: _mobile.text);

  /// **A number belongs to one golfer** (Paul, 14 Nov 2026), so a mobile that
  /// is already on someone in your list stops the add outright — unlike a
  /// matching NAME, which only warns, because two golfers can share one. The
  /// server refuses it too; this says so before the round trip.
  bool get _numberTaken => _dupes.any((d) => d.byPhone);

  Future<void> _lookup() async {
    final number = _mobile.text;
    if (!mobileComplete(number) || _lookedUp == number) return;
    _lookedUp = number;
    try {
      final res =
          await context.read<AuthProvider>().client.lookupHalvedUser(number);
      if (!mounted || _mobile.text != number) return;
      setState(() => _account = res['found'] == true ? res : null);
    } catch (_) {
      if (mounted) setState(() => _account = null);
    }
  }

  String _indexForServer() {
    final v = parseIndexTyped(_index.text);
    return v == null ? '0.0' : v.toString();
  }

  Future<void> _save({required bool useAccount}) async {
    if (_busy || !_nameOk) return;
    final client = context.read<AuthProvider>().client;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      final PlayerProfile created;
      if (useAccount && _account != null) {
        created = await client.createPlayer(
          name: (_account!['name'] as String?) ?? capitalizeName(_name.text),
          handicapIndex: (_account!['handicap_index'] as String?) ?? '0.0',
          phone: _mobile.text,
          sex: (_account!['sex'] as String?) ?? 'M',
          shortName: _account!['short_name'] as String?,
        );
      } else {
        created = await client.createPlayer(
          name: savedGuestName(_name.text),
          handicapIndex: _indexForServer(),
          phone: mobileComplete(_mobile.text) ? _mobile.text : '',
        );
      }
      if (!mounted) return;
      navigator.pop(NewGolferResult(created,
          hasNumber: mobileComplete(_mobile.text),
          viaAccount: useAccount && _account != null));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // The server's own words when it has them — "That number is already
      // Bill Sinn's" says what to do, "Could not add" does not.
      final detail = e is ApiException ? e.message : '';
      messenger.showSnackBar(SnackBar(
          content: Text(detail.isNotEmpty
              ? detail
              : 'Could not add that golfer.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = capitalizeName(_name.text);
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.94),
      decoration: const BoxDecoration(
        color: Halved.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      // The fields scroll; the button does not. On a short phone with the
      // keyboard up the one thing that finishes the sheet must stay reachable.
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Halved.cardBorder,
                          borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text('Cancel',
                          style: Halved.body(
                                  color: Halved.pine, weight: FontWeight.w600)
                              .copyWith(fontSize: 14)),
                    ),
                  ),
                  _header(name),
                  const SizedBox(height: 18),
                  _field('Full name', _name,
                      caps: TextCapitalization.words,
                      onChanged: (_) => setState(() {})),
                  _duplicates(),
                  const SizedBox(height: 16),
                  _field('Handicap index', _index,
                      keyboard: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      formatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.+\-]')),
                      ],
                      onChanged: (_) => setState(() {})),
                  const SizedBox(height: 6),
                  _strokes(),
                  const SizedBox(height: 16),
                  _textCard(name),
                ]),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(18, 8, 18, inset + 18),
          child: _button(name),
        ),
      ]),
    );
  }

  Widget _header(String name) => Row(children: [
        AnimatedScale(
          scale: 1,
          duration: const Duration(milliseconds: 150),
          child: GolferAvatar(
              key: ValueKey(initialsOf(name)),
              name: name.isEmpty ? '?' : name,
              onHalved: false,
              size: 44),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? 'New golfer' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Halved.sectionHead()
                    .copyWith(fontSize: 20, fontWeight: FontWeight.w700)),
            Text('Not on Halved yet. Joins your golfers for next time.',
                style:
                    Halved.body(color: Halved.muted).copyWith(fontSize: 12.5)),
          ]),
        ),
      ]);

  Widget _field(String label, TextEditingController c,
          {TextInputType? keyboard,
          TextCapitalization caps = TextCapitalization.none,
          List<TextInputFormatter>? formatters,
          ValueChanged<String>? onChanged}) =>
      TextField(
        controller: c,
        keyboardType: keyboard,
        textCapitalization: caps,
        inputFormatters: formatters,
        onChanged: onChanged,
        style: Halved.body(color: Halved.deepPine).copyWith(fontSize: 16),
        decoration: InputDecoration(
          labelText: label.toUpperCase(),
          labelStyle: Halved.label(color: Halved.muted, weight: FontWeight.w700)
              .copyWith(fontSize: 11, letterSpacing: 0.7),
          floatingLabelBehavior: FloatingLabelBehavior.always,
          filled: true,
          fillColor: Colors.white,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Halved.cardBorder, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Halved.pine, width: 1.5),
          ),
        ),
      );

  /// The warning: this name or number is already in your list. It names them,
  /// says how often you have played, and offers to use him instead — but never
  /// blocks, because two golfers can share a name.
  Widget _duplicates() {
    final dupes = _dupes;
    if (dupes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(children: [
        for (final d in dupes.take(2)) _duplicateBox(d),
      ]),
    );
  }

  Widget _duplicateBox(DuplicateGolfer d) {
    final p = d.player;
    final played = widget.counts[p.id]?.rounds ?? 0;
    final why = d.byPhone && !d.byName
        ? 'That number is already '
        : 'You already have ';
    final tail = d.byPhone && !d.byName
        ? "'s. A number can belong to one golfer."
        : '.';
    final base = Halved.body(color: Halved.caution).copyWith(fontSize: 13);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: Halved.cautionGround,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Halved.caution.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 18, color: Halved.caution),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(TextSpan(style: base, children: [
            TextSpan(text: why),
            TextSpan(
                text: p.name,
                style: base.copyWith(fontWeight: FontWeight.w800)),
            TextSpan(text: tail),
            TextSpan(
                text: ' Index ${p.handicapIndex} · ${playedLabel(played)}.'),
          ])),
        ),
        if (widget.allowUseExisting)
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).pop(NewGolferResult(p,
                    hasNumber: false, viaAccount: false, existing: true)),
            child: Text('Use ${p.name.split(' ').first}',
                style: Halved.body(
                        color: Halved.caution, weight: FontWeight.w800)
                    .copyWith(fontSize: 13)),
          ),
      ]),
    );
  }

  /// *Gets **6** strokes from you.* — worked out live against YOUR index.
  Widget _strokes() {
    final blank = parseIndexTyped(_index.text) == null;
    // With no round to measure against only the blank-state sentence applies.
    if (widget.myIndex == null && !blank) return const SizedBox.shrink();
    final l = strokesLine(
        yours: widget.myIndex, theirsTyped: _index.text, slope: widget.slope);
    final base = Halved.body(color: Halved.muted).copyWith(fontSize: 13);
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text.rich(TextSpan(style: base, children: [
        TextSpan(text: l.before),
        if (l.number != null)
          TextSpan(
              text: l.number,
              style: base.copyWith(
                  color: Halved.deepPine, fontWeight: FontWeight.w800)),
        TextSpan(text: l.after),
      ])),
    );
  }

  Widget _textCard(String name) {
    final first = name.isEmpty ? 'them' : name.split(' ').first;
    final account = _account;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
          color: Halved.deepPine, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('Text $first the game',
                style: Halved.sectionHead()
                    .copyWith(fontSize: 16, color: Colors.white)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Halved.brightMint,
                borderRadius: BorderRadius.circular(8)),
            child: Text('RECOMMENDED',
                style: Halved.label(
                        color: Halved.deepPine, weight: FontWeight.w800)
                    .copyWith(fontSize: 9.5, letterSpacing: 0.6)),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _mobile,
          keyboardType: TextInputType.phone,
          inputFormatters: [_MobileFormatter()],
          onChanged: (_) {
            setState(() => _account = null);
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), _lookup);
          },
          style: Halved.body(color: Colors.white).copyWith(fontSize: 16),
          decoration: InputDecoration(
            labelText: 'MOBILE',
            labelStyle: Halved.label(
                    color: Halved.brightMint, weight: FontWeight.w700)
                .copyWith(fontSize: 11, letterSpacing: 0.7),
            floatingLabelBehavior: FloatingLabelBehavior.always,
            hintText: '(415) 555-0100',
            hintStyle:
                Halved.body(color: Colors.white.withValues(alpha: 0.35)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Halved.brightMint, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide:
                  const BorderSide(color: Halved.brightMint, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (account == null || _numberTaken)
          Text(
              'The live game now, the receipt at the end. If the number is '
              'already on Halved, we will find them.',
              style: Halved.body(color: Colors.white.withValues(alpha: 0.7))
                  .copyWith(fontSize: 12.5))
        else
          _accountBox(account),
      ]),
    );
  }

  Widget _accountBox(Map<String, dynamic> account) {
    final who = (account['name'] as String?) ?? 'A golfer';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: const Color(0xFFE3F8EE),
          borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Expanded(
          child: Text.rich(TextSpan(
            style: Halved.body(color: Halved.deepPine).copyWith(fontSize: 13),
            children: [
              const TextSpan(text: 'That number is '),
              TextSpan(
                  text: who,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              const TextSpan(
                  text: ', already on Halved. Add the account so scores and '
                      'handicap sync.'),
            ],
          )),
        ),
        const SizedBox(width: 10),
        TextButton(
          onPressed: _busy ? null : () => _save(useAccount: true),
          child: Text('Use account',
              style: Halved.body(color: Halved.pine, weight: FontWeight.w800)
                  .copyWith(fontSize: 13)),
        ),
      ]),
    );
  }

  Widget _button(String name) {
    final taken = _numberTaken;
    final label = taken
        ? 'That number is already in use'
        : newGolferButtonLabel(_name.text, _mobile.text);
    final enabled = _nameOk && !_busy && !taken;
    return SizedBox(
      height: 54,
      child: FilledButton(
        onPressed: enabled ? () => _save(useAccount: false) : null,
        style: FilledButton.styleFrom(
          backgroundColor: Halved.brightMint,
          foregroundColor: Halved.deepPine,
          disabledBackgroundColor: Halved.disabledFill,
          disabledForegroundColor: Halved.disabledText,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Text(label,
                style: Halved.button(color: null).copyWith(
                    fontWeight: FontWeight.w800, fontSize: 16)),
      ),
    );
  }
}

/// Formats the mobile as digits arrive: `(415) 555-0100`.
class _MobileFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final text = formatMobile(newValue.text);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
