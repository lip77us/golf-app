/// ui_labels.dart — user-facing wording that may be reworded later.
///
/// Rebrand "Casual" everywhere by changing [kCasualWord] in this one place;
/// the composed singular/plural labels below follow automatically.
library;

/// The word for a non-tournament, one-off round. Reword here (e.g. 'Casual' →
/// 'Pickup' / 'Money Match') to rebrand it across the app.
const String kCasualWord = 'Casual';

/// "Casual Round" — singular; the round-hub title for a standalone round.
const String kCasualRoundLabel = '$kCasualWord Round';

/// "Casual Rounds" — plural; the drawer entry + list-screen title.
const String kCasualRoundsLabel = '$kCasualWord Rounds';
