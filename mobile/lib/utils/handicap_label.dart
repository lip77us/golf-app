/// `16.2 · CH 14` — the two numbers a golfer is identified and plays by.
///
/// **One composer, five boards.** Stroke Play showed the index alone, on the
/// reasoning that CH moves with the tee while the index is who you are —
/// right that CH is not identity, wrong that it is either-or. The index
/// cannot be used to read a net figure, which is what a board is for: *"the
/// index shows, but not the gets, so I don't know the players CH"* (Paul, 31
/// Oct 2026). The other four boards named neither.
///
/// It is written here rather than in each board because five copies of one
/// label is how they come to disagree about what a middot separates — the
/// same reason `gross_to_par` and the tray header are shared.
///
/// **This is the COURSE handicap, not what the game gives him.** A game's own
/// allowance (strokes off the low man, a net percentage) is a third number,
/// and it is already stated once per card in the settings strip rather than
/// once per row.
String handicapLabel({String? index, int? courseHandicap}) {
  final idx = (index ?? '').trim();
  final ch = courseHandicap == null ? '' : 'CH $courseHandicap';
  if (idx.isEmpty) return ch;
  if (ch.isEmpty) return idx;
  return '$idx · $ch';
}
