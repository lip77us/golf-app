/// ui_labels.dart — user-facing wording that may be reworded later.
///
/// A non-tournament, one-off round is now just a "Round" / "Rounds" (the
/// "Casual" qualifier was dropped app-wide). Reword in this one place to
/// rebrand; the constant names are kept so call sites don't churn.
library;

/// "Round" — singular; the round-hub title for a standalone round.
const String kCasualRoundLabel = 'Round';

/// "Rounds" — plural; the drawer entry + list-screen title.
const String kCasualRoundsLabel = 'Rounds';
