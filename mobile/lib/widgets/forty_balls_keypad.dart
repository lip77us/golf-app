/// widgets/forty_balls_keypad.dart
/// --------------------------------
/// The 40 Balls score keypad — one tap per stroke count, coded to par.
///
/// **Scoped to 40 Balls, deliberately** (Paul, 24 Oct 2026: "unique to 40
/// balls, at least for now"). Every other game enters a score through
/// `InlineScorePicker`, which thirteen screens share, so a keypad there is a
/// system-wide change rather than one game's. It lives in its own widget
/// rather than inside `score_entry_screen` precisely so that "at least for
/// now" stays cheap: promoting it later is a move, not a rewrite.
///
/// The coding is the scorecard notation a golfer already knows — a circle for
/// under par, a square for over, doubled at two or more — so the keys say what
/// a number MEANS on this hole without a legend. The handoff is explicit that
/// there is no legend underneath, and that is why: the shapes are the legend.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/halved_brand.dart';

/// How a stroke count sits against par.
enum ScoreShape { eagle, birdie, par, bogey, double }

/// [strokes] is the handicap the golfer gets on this hole, and it moves the
/// BASELINE rather than the score: a golfer with one stroke who makes 5 on a
/// par 4 is drawn as a par. That is Net Style Entry, which `net_score_button`
/// and `inline_score_picker` have always honoured — the keypad was the one
/// surface left coding against bare par, so one golfer saw a par box in the
/// picker and a bogey square on the keys for the same number.
///
/// Callers that do not pass it are unchanged.
ScoreShape shapeForScore(int score, int par, {int strokes = 0}) {
  final d = score - par - strokes;
  if (d <= -2) return ScoreShape.eagle;
  if (d == -1) return ScoreShape.birdie;
  if (d == 0) return ScoreShape.par;
  if (d == 1) return ScoreShape.bogey;
  return ScoreShape.double;
}

/// Colours for the notation.
///
/// The bogey ink is [Halved.clayInk], which carries the note about its
/// near-collision with `Halved.caution`. It moved there when the Points board
/// needed the same `#8A4A1C` for a total under target: two boards wearing one
/// ink must not each hold their own copy of it.
class _Clay {
  static const parFill    = Color(0xFFBFDCC6);
  static const bogeyFill  = Color(0xFFFDF6EF);
  static const bogeyLine  = Color(0xFFD9A27A);
  static const bogeyText  = Halved.clayInk;
  static const doubleFill = Color(0xFFFAEBDD);
}

/// One key, or a score box drawn with the same notation.
///
/// Shared so a `4` in the keypad and the `4` that lands in the player's row
/// cannot drift apart — the handoff asks for both, and two implementations of
/// one mark is how they stop matching.
class ScoreNotation extends StatelessWidget {
  final int score;
  final int par;

  /// Strokes this golfer gets here; see [shapeForScore]. The caller decides
  /// whether Net Style Entry is on, so a gross game passes 0.
  final int strokes;
  final double width;
  final double height;
  final double fontSize;
  final VoidCallback? onTap;

  /// The square shapes' corner, and the inset of a doubled ring.
  ///
  /// The defaults are drawn for a 60pt key and a 44pt score box. At the 24pt
  /// the leaderboard card wants, a 10pt corner is a squircle and a 4pt inset
  /// swallows the digit — so the SIZE is a parameter rather than a reason for
  /// a second widget. Null keeps the figures every existing caller draws.
  final double? cornerRadius;

  const ScoreNotation({
    super.key,
    required this.score,
    required this.par,
    this.strokes = 0,
    this.width = double.infinity,
    this.height = 60,
    this.fontSize = 25,
    this.onTap,
    this.cornerRadius,
  });

  @override
  Widget build(BuildContext context) {
    final shape = shapeForScore(score, par, strokes: strokes);
    final rounded = shape == ScoreShape.eagle || shape == ScoreShape.birdie ||
        shape == ScoreShape.par;

    final (Color fill, Color line, Color text) = switch (shape) {
      ScoreShape.eagle  => (Halved.card, Halved.deepPine, Halved.deepPine),
      ScoreShape.birdie => (Halved.card, Halved.pine, Halved.deepPine),
      ScoreShape.par    => (_Clay.parFill, Halved.pine, Halved.deepPine),
      ScoreShape.bogey  => (_Clay.bogeyFill, _Clay.bogeyLine, _Clay.bogeyText),
      ScoreShape.double => (_Clay.doubleFill, _Clay.bogeyLine, _Clay.bogeyText),
    };
    // Eagle and double+ are DOUBLED — a second ring inside the first, which is
    // how a scorecard marks two under or two over.
    final doubled = shape == ScoreShape.eagle || shape == ScoreShape.double;

    BorderRadius radius(double r) => BorderRadius.circular(r);
    final corner = cornerRadius ?? 10;
    // The inner ring's inset. 4 at the default, and proportional below it so
    // a 24pt mark keeps a readable digit inside two rings.
    final inset = cornerRadius == null ? 4.0 : (height / 10).clamp(2.0, 4.0);

    Widget box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius(rounded ? height / 2 : corner),
        border: Border.all(color: line, width: 1.5),
      ),
      alignment: Alignment.center,
      child: doubled
          ? Container(
              margin: EdgeInsets.all(inset),
              decoration: BoxDecoration(
                borderRadius: radius(rounded
                    ? (height - inset * 2) / 2
                    : (corner - inset).clamp(1.0, corner)),
                border: Border.all(color: line, width: 1.2),
              ),
              alignment: Alignment.center,
              child: _numeral(score, text, fontSize),
            )
          : _numeral(score, text, fontSize),
    );

    if (onTap == null) return box;
    return Semantics(
      button: true,
      label: '$score, ${_shapeWord(shape)}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius(rounded ? height / 2 : corner),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap!();
          },
          child: box,
        ),
      ),
    );
  }

  static Widget _numeral(int n, Color color, double size) => Text(
        '$n',
        style: TextStyle(
          fontSize: size,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1,
        ),
      );

  static String _shapeWord(ScoreShape s) => switch (s) {
        ScoreShape.eagle  => 'eagle or better',
        ScoreShape.birdie => 'birdie',
        ScoreShape.par    => 'par',
        ScoreShape.bogey  => 'bogey',
        ScoreShape.double => 'double bogey or worse',
      };
}


/// The white keypad sheet: 1–9 coded to par, then `10+` and `Clear`.
///
/// Stateful only for the `10+` field, which swaps the grid for a number pad
/// rather than opening a dialog — the handoff draws it in place, and a sheet
/// over a sheet on a phone at arm's length is a worse thing to dismiss with a
/// glove on.
class FortyBallsKeypad extends StatefulWidget {
  /// The golfer being entered, named in the header so a scorer with the phone
  /// at the next tee can see whose number he is about to type.
  final String playerName;
  final int par;

  /// Strokes this golfer gets on this hole, for the `1 stroke · par 3` line.
  final int strokes;

  /// When true the keys are coded against par PLUS this golfer's strokes, so
  /// they recode as focus moves down the card. Read from Net Style Entry by
  /// the caller rather than here, because the widget has no business knowing
  /// which games offer strokes at all.
  final bool netStyle;

  final ValueChanged<int> onScore;
  final VoidCallback onClear;

  /// Ends an EDIT SESSION and hands the bar back to the tray.
  ///
  /// `Edit scores` is plural and used to let you change exactly one: the
  /// screen cleared its editing flag the moment a key landed, so the tray
  /// came straight back (Paul, 30 Oct 2026). A session needs a way out that
  /// is not "type another number", and this is it. Null — every other
  /// caller — draws nothing and keeps the old one-shot behaviour.
  final VoidCallback? onDone;

  /// The highest GROSS that counts on this hole, when something caps it —
  /// Stroke Play's net double bogey. Shown as `· max 7`, because a golfer
  /// about to type a 10 should know before he does that the total will count
  /// seven and the card will keep the ten.
  ///
  /// Named for the FACT rather than the game, and null everywhere else: a
  /// number here when nothing enforces one would be a maximum the engine
  /// does not apply.
  final int? capMax;

  /// Stableford's place in the same slot: where the points table bottoms
  /// out for this golfer (`0 pts from 6`). There is no maximum to state —
  /// anything from there down scores the same — so it says that instead.
  final String? floorText;

  /// Marks this golfer as not scoring the hole and moves on.
  ///
  /// **Fourball, after a close-out, and nowhere else.** The match is over,
  /// the group is playing the rest of the card, and a golfer is allowed to
  /// pick up — so the bottom row becomes three equal keys. Null everywhere
  /// else, which keeps `10+` narrow beside a wide `Clear` and the two
  /// destructive-ish controls at different widths.
  final VoidCallback? onNoScore;

  /// Replaces `1 stroke` / `no stroke` in the header. Triple Nassau's
  /// strokes are by MATCH, so the honest line names the opponents
  /// (`stroke v Paul, Dave`) rather than a count.
  final String? strokeNote;

  const FortyBallsKeypad({
    super.key,
    required this.playerName,
    required this.par,
    required this.strokes,
    required this.onScore,
    required this.onClear,
    this.netStyle = false,
    this.onDone,
    this.capMax,
    this.floorText,
    this.onNoScore,
    this.strokeNote,
  });

  @override
  State<FortyBallsKeypad> createState() => _FortyBallsKeypadState();
}

class _FortyBallsKeypadState extends State<FortyBallsKeypad> {
  final _ctrl = TextEditingController();
  bool _typing = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  int? get _typed {
    final n = int.tryParse(_ctrl.text.trim());
    return (n != null && n >= 10) ? n : null;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Halved.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(Halved.rCard)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _header(),
        const SizedBox(height: 12),
        if (_typing) _tenPlus() else _grid(),
      ]),
    );
  }

  Widget _header() => Row(children: [
        Expanded(
          child: Text(
            // The name stays in both states — the 10+ field is still that
            // golfer's score, and losing his name is how a scorer types it
            // against the wrong row.
            widget.playerName,
            style: const TextStyle(
                fontWeight: FontWeight.w700, color: Halved.deepPine),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            _typing
                ? 'Type a score of 10 or more'
                : [
                    (widget.strokeNote ?? '').isNotEmpty
                        ? widget.strokeNote!
                        : _strokeWord(widget.strokes),
                    'par ${widget.par}',
                    if (widget.capMax != null) 'max ${widget.capMax}',
                    if ((widget.floorText ?? '').isNotEmpty) widget.floorText!,
                  ].join(' · '),
            style: const TextStyle(fontSize: 12, color: Halved.muted),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.onDone != null) ...[
          const SizedBox(width: 6),
          // 44pt, because it is the only way out of an edit session.
          SizedBox(
            height: 44,
            child: TextButton(
              onPressed: widget.onDone,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: Halved.deepPine,
              ),
              child: const Text('Done',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ]);

  /// `no stroke` rather than `0 strokes`, which is what it used to say and
  /// reads as a quantity of nothing. The packets for Sixes and Rabbit both
  /// write it this way.
  static String _strokeWord(int n) =>
      n == 0 ? 'no stroke' : n == 1 ? '1 stroke' : '$n strokes';

  Widget _grid() {
    // 3 per row, 8pt gaps, keys 60 tall — the handoff's figures.
    Widget key(int n) => Expanded(
          child: ScoreNotation(
            score: n,
            par: widget.par,
            strokes: widget.netStyle ? widget.strokes : 0,
            height: 60,
            onTap: () => widget.onScore(n),
          ),
        );
    Widget row(List<int> ns) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            for (var i = 0; i < ns.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              key(ns[i]),
            ],
          ]),
        );

    return Column(mainAxisSize: MainAxisSize.min, children: [
      row(const [1, 2, 3]),
      row(const [4, 5, 6]),
      row(const [7, 8, 9]),
      Row(children: [
        // 10+ takes ONE column and Clear the remaining two, so the two
        // destructive-ish controls are never adjacent at the same width.
        // With `No score` in play there are three keys and they share
        // evenly, which is what the Fourball packet draws.
        Expanded(child: _flatButton('10+', onTap: () {
          setState(() { _typing = true; _ctrl.clear(); });
        })),
        const SizedBox(width: 8),
        if (widget.onNoScore != null) ...[
          Expanded(
            child: _flatButton('No score', onTap: widget.onNoScore!),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          flex: widget.onNoScore == null ? 2 : 1,
          child: _flatButton('Clear', filled: true, onTap: widget.onClear),
        ),
      ]),
    ]);
  }

  Widget _tenPlus() => Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 28, fontWeight: FontWeight.w700,
              color: Halved.deepPine),
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _commitTyped(),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _flatButton('Cancel', onTap: () {
            setState(() => _typing = false);
          })),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: _flatButton(
              'Enter',
              filled: true,
              // Disabled until the value is genuinely a 10+ score: the field
              // exists because the keypad stops at 9, so a 7 typed here would
              // be a key press that went the long way round.
              onTap: _typed == null ? null : _commitTyped,
            ),
          ),
        ]),
      ]);

  void _commitTyped() {
    final n = _typed;
    if (n == null) return;
    widget.onScore(n);
    setState(() => _typing = false);
  }

  Widget _flatButton(String label,
      {VoidCallback? onTap, bool filled = false}) {
    final enabled = onTap != null;
    return Material(
      color: filled
          ? (enabled ? Halved.surface : Halved.disabledFill)
          : Halved.card,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: filled
                ? null
                : Border.all(color: Halved.cardBorder, width: 1.5),
          ),
          child: Text(label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: enabled ? Halved.deepPine : Halved.disabledText,
              )),
        ),
      ),
    );
  }
}
