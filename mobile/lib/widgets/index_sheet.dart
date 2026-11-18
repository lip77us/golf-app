/// The index sheet: a number pad for one golfer's index. It saves nothing
/// itself — it returns what was typed and whether to step on to the next
/// golfer, and the caller saves.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/halved_brand.dart';
import '../utils/add_players.dart';
import '../utils/golfer_index.dart';
import 'golfer_avatar.dart';

class IndexSheetResult {
  /// The index as the server stores it (`-2.1` for a +2.1 handicap).
  final String stored;

  /// "Save · Dave ›" — carry on to the next golfer.
  final bool advance;
  const IndexSheetResult(this.stored, this.advance);
}

/// Whose index this is, and so what saving it means (handoff §5).
enum IndexOwner { you, halved, guest, saved }

Future<IndexSheetResult?> showIndexSheet(
  BuildContext context, {
  required String name,
  required String? currentStored,
  required IndexOwner owner,
  required double? myIndex,
  int slope = 113,
  String? nextFirstName,
  String? stepLabel,
  VoidCallback? onEditDetails,
}) =>
    showModalBottomSheet<IndexSheetResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Halved.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => IndexSheet(
        name: name,
        currentStored: currentStored,
        owner: owner,
        myIndex: myIndex,
        slope: slope,
        nextFirstName: nextFirstName,
        stepLabel: stepLabel,
        onEditDetails: onEditDetails,
      ),
    );

class IndexSheet extends StatefulWidget {
  final String name;
  final String? currentStored;
  final IndexOwner owner;
  final double? myIndex;
  final int slope;
  final String? nextFirstName;
  /// `Player 2 of 4`, only while stepping through a group.
  final String? stepLabel;
  final VoidCallback? onEditDetails;

  const IndexSheet({
    super.key,
    required this.name,
    required this.currentStored,
    required this.owner,
    required this.myIndex,
    this.slope = 113,
    this.nextFirstName,
    this.stepLabel,
    this.onEditDetails,
  });

  @override
  State<IndexSheet> createState() => _IndexSheetState();
}

class _IndexSheetState extends State<IndexSheet> {
  String _typed = '';

  String get _first => widget.name.trim().split(' ').first;

  String get _sub {
    switch (widget.owner) {
      case IndexOwner.guest:
        return 'Guest · this round only';
      case IndexOwner.saved:
        return 'Saved in your golfers';
      case IndexOwner.halved:
        return 'On Halved · yours until $_first updates it';
      case IndexOwner.you:
        return 'Your profile index';
    }
  }

  void _press(String k) => setState(() => _typed = padKey(_typed, k));

  void _done(bool advance) {
    final s = storedFromTyped(_typed);
    if (s == null) return;
    Navigator.of(context).pop(IndexSheetResult(s, advance));
  }

  @override
  Widget build(BuildContext context) {
    final stored = storedFromTyped(_typed);
    final shown = _typed.isNotEmpty
        ? _typed
        : (indexLabel(widget.currentStored) ?? '—');
    final grey = _typed.isEmpty;

    Widget strokes;
    if (widget.owner == IndexOwner.you) {
      strokes = Text('Your own index. It sets everyone’s strokes against you.',
          textAlign: TextAlign.center,
          style: Halved.body(color: Halved.muted));
    } else {
      final l = strokesLine(
          yours: widget.myIndex, theirsTyped: _typed, slope: widget.slope);
      strokes = Text.rich(
          TextSpan(style: Halved.body(color: Halved.muted), children: [
            TextSpan(text: l.before),
            if (l.number != null)
              TextSpan(
                  text: l.number,
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, color: Halved.deepPine)),
            TextSpan(text: l.after),
          ]),
          textAlign: TextAlign.center);
    }

    Widget key(String label, String k, {Widget? child}) => Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _press(k),
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Halved.cardBorder)),
                  child: child ??
                      Text(label,
                          style: GoogleFonts.schibstedGrotesk(
                              fontSize: 24,
                              fontWeight: FontWeight.w600,
                              color: Halved.deepPine)),
                ),
              ),
            ),
          ),
        );
    Widget keyRow(List<Widget> c) => Row(children: c);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            GolferAvatar(name: widget.name, onHalved: false, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.schibstedGrotesk(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: Halved.deepPine)),
                Text(
                    widget.stepLabel == null ? _sub : '$_sub · ${widget.stepLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Halved.body(color: Halved.muted)),
              ]),
            ),
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cancel',
                    style: Halved.body(
                        color: Halved.pine, weight: FontWeight.w800))),
          ]),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('INDEX',
                style: Halved.body(color: Halved.muted, weight: FontWeight.w700)),
            const SizedBox(width: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: const BoxDecoration(
                  border: Border(
                      bottom: BorderSide(color: Halved.brightMint, width: 3))),
              child: Text(shown,
                  style: GoogleFonts.schibstedGrotesk(
                      fontSize: 46,
                      fontWeight: FontWeight.w700,
                      color: grey ? Halved.disabledText : Halved.deepPine)),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(height: 20, child: strokes),
          const SizedBox(height: 8),
          keyRow([key('1', '1'), key('2', '2'), key('3', '3')]),
          keyRow([key('4', '4'), key('5', '5'), key('6', '6')]),
          keyRow([key('7', '7'), key('8', '8'), key('9', '9')]),
          keyRow([
            key('+ / .', '+.',
                child: Text('+ / .',
                    style: Halved.body(
                        color: Halved.muted, weight: FontWeight.w700))),
            key('0', '0'),
            key('', 'back',
                child: const Icon(Icons.backspace_outlined,
                    color: Halved.deepPine)),
          ]),
          const SizedBox(height: 8),
          if (widget.nextFirstName == null)
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Halved.brightMint,
                  foregroundColor: Halved.deepPine,
                  disabledBackgroundColor: Halved.disabledFill,
                  minimumSize: const Size.fromHeight(54),
                  shape: const StadiumBorder()),
              onPressed: stored == null ? null : () => _done(false),
              child: Text('Save',
                  style: Halved.body(weight: FontWeight.w800)
                      .copyWith(fontSize: 17)),
            )
          else
            // Stepping through a group: Save & done stops here, the mint
            // button is the main action and carries on.
            Row(children: [
              Expanded(
                flex: 2,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Halved.pine,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Halved.disabledFill,
                      minimumSize: const Size.fromHeight(54),
                      shape: const StadiumBorder()),
                  onPressed: stored == null ? null : () => _done(false),
                  child: Text('Save & done',
                      style: Halved.body(weight: FontWeight.w800)
                          .copyWith(fontSize: 15)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Halved.brightMint,
                      foregroundColor: Halved.deepPine,
                      disabledBackgroundColor: Halved.disabledFill,
                      minimumSize: const Size.fromHeight(54),
                      shape: const StadiumBorder()),
                  onPressed: stored == null ? null : () => _done(true),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('Save → Next: ${widget.nextFirstName}',
                        style: Halved.body(weight: FontWeight.w800)
                            .copyWith(fontSize: 15)),
                  ),
                ),
              ),
            ]),
          if (widget.onEditDetails != null)
            TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onEditDetails!();
                },
                child: Text('Edit name, mobile…',
                    style: Halved.body(color: Halved.pine, weight: FontWeight.w700))),
        ]),
      ),
    );
  }
}
