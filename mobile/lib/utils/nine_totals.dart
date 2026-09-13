/// utils/nine_totals.dart
///
/// OUT / IN / TOT on a hole-by-hole card.
///
/// Every scorecard in the app splits at the turn the same way, and the three
/// facts that follow from the split — which summary columns exist, how wide
/// the content really is, and where a given hole's right edge sits once the
/// summary columns are counted — were being derived by hand on each card. Two
/// of them are easy to get subtly wrong: a `contentWidth` measured in hole
/// cells alone leaves the rule stopping short of the grid it underlines, and a
/// scroll target that ignores the OUT column lands a back-nine hole one column
/// shy of the right edge.
///
/// **A nine that is not in play has no column.** A back-nine round shows IN
/// alone rather than an OUT that could only ever be blank, and TOT appears
/// only when there are two nines for it to total.
library;

class NineSplit {
  final List<int> front;
  final List<int> back;
  final bool showOut;
  final bool showIn;
  final bool showTot;

  const NineSplit._(this.front, this.back,
      this.showOut, this.showIn, this.showTot);

  /// Split a play order at the turn. Holes 1-9 are the front whatever order
  /// they are played in — a shotgun round starting on the 7th still has a
  /// front nine, and OUT still means the same nine holes.
  factory NineSplit.of(List<int> holeRange) {
    final front = holeRange.where((h) => h <= 9).toList();
    final back = holeRange.where((h) => h > 9).toList();
    return NineSplit._(front, back,
        front.isNotEmpty, back.isNotEmpty,
        front.isNotEmpty && back.isNotEmpty);
  }

  /// How many summary columns the card carries.
  int get count => (showOut ? 1 : 0) + (showIn ? 1 : 0) + (showTot ? 1 : 0);

  /// Every hole, both nines — for the rows that do not need the split.
  List<int> get all => [...front, ...back];

  /// The full width of the scrolling half, summary columns included. A rule
  /// measured without them stops short of the grid it is meant to underline.
  double contentWidth(double cellW, double summaryW) =>
      cellW * (front.length + back.length) + summaryW * count;

  /// Where [hole]'s RIGHT EDGE sits in content coordinates, counting the
  /// summary columns before it — null when the hole is not in play.
  ///
  /// A back-nine hole is one column further right than its position in the
  /// play order suggests, which is the part that is easy to miss.
  double? rightEdgeOf(int hole, double cellW, double summaryW) {
    final fi = front.indexOf(hole);
    if (fi >= 0) return (fi + 1) * cellW;
    final bi = back.indexOf(hole);
    if (bi < 0) return null;
    return front.length * cellW +
        (showOut ? summaryW : 0) +
        (bi + 1) * cellW;
  }
}
