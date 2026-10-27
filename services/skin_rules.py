"""Who may win a skin — the validation rules, shared by both skins engines.

Two rules, asked for by Paul on 27 Oct 2026 after a user described his Friday
game: *"you win the skin with your stroke but you have to validate the skin
with a gross par, and birdies steal."*

* **A minimum.** A skin cannot be won with a bad hole, however many strokes
  you get. `NET_PAR` requires the score the game is scored on to be par or
  better; `GROSS_PAR` requires the GROSS to be par or better, which is
  stricter — a net par made off a stroke is a gross bogey and fails it. Both
  exist because they are different house rules, and the app is not the
  authority on which one a group plays (same reasoning as the Spots
  checklist).
* **Gross birdie steal.** A natural birdie beats a manufactured one: if any
  player makes a gross birdie or better, only those players can win the hole.

### The design: TWO FILTERS, ONE RANKING

Both rules decide **who is eligible**; neither changes **how scores compare**.
Ranking stays on the score the game is already scored on, so a net game stays
a net game — two players who both make a natural birdie are separated by their
net, not re-ranked on gross. That keeps the rules composable (either, both or
neither, in any combination) instead of three special cases, and it means a
stroke is never silently ignored.

The steal filter OUTRANKS the minimum: a gross birdie is better than par, so
anyone who passes the steal filter passes either minimum automatically. The
two can never contradict each other.

### `decide()` returns LEADERS, not a winner

0, 1 or several ids. The caller owns what a non-single answer means, because
the two engines disagree: round skins carries a tied hole (when `carryover`)
while the cross-round pool kills it. **Nobody qualifying returns an empty
list, which every caller must treat exactly like a tie** — the skin was not
won, so whatever that engine does with an unwon hole is right by construction.

That is the whole reason this is a filter returning leaders rather than a
`winner_id`: it adds a third outcome to a two-outcome decision without either
engine having to learn the other's carry policy.

### Par is per player

Each golfer is measured against the par of HIS OWN tee. Every other game in
this codebase takes one par layout for the foursome (see
`services.triple_cup._par_by_hole`, which says so), and that is fine when the
question is about the hole. This question is about the GOLFER — did *he* make
par — so on a mixed-tee card, where the men's and women's pars can differ, his
own card is the one that decides whether he validated.
"""

# ---------------------------------------------------------------------------
# The minimum
# ---------------------------------------------------------------------------

MIN_NONE = 'none'
MIN_NET_PAR = 'net_par'
MIN_GROSS_PAR = 'gross_par'

SKIN_MINIMUM_CHOICES = [
    (MIN_NONE,      'No minimum'),
    (MIN_NET_PAR,   'Net par or better'),
    (MIN_GROSS_PAR, 'Gross par or better'),
]

_VALID_MINIMUMS = {MIN_NONE, MIN_NET_PAR, MIN_GROSS_PAR}


def normalise_minimum(value) -> str:
    """An unknown value means NO minimum, never a silent stricter rule.

    Failing open matters here: a typo that quietly started validating skins
    would change who gets paid with nothing on screen saying so.
    """
    value = (value or MIN_NONE)
    return value if value in _VALID_MINIMUMS else MIN_NONE


def is_natural_birdie(gross, par) -> bool:
    """Gross birdie or better.  An eagle steals too — it is 'or better'."""
    if gross is None or par is None:
        return False
    return int(gross) <= int(par) - 1


def meets_minimum(score, gross, par, minimum) -> bool:
    """Does this golfer's hole clear the configured minimum?

    `score` is what the game ranks on (net, gross or strokes-off, per the
    game's own handicap mode).  In a GROSS game `NET_PAR` and `GROSS_PAR`
    coincide, which is correct rather than a collision: there is no net score
    to be more lenient about.
    """
    minimum = normalise_minimum(minimum)
    if minimum == MIN_NONE:
        return True
    if par is None:
        # No par on file for his tee — do not invent a verdict.  Failing open
        # keeps an incomplete course from silently voiding every skin.
        return True
    if minimum == MIN_GROSS_PAR:
        return gross is not None and int(gross) <= int(par)
    return score is not None and int(score) <= int(par)   # MIN_NET_PAR


def decide(scores: dict, gross: dict, pars: dict, *,
           minimum: str = MIN_NONE, birdie_steal: bool = False) -> list:
    """The ids tied for the best ELIGIBLE score on one hole.

    scores : {player_id: score the game ranks on}  — the contested roster only
    gross  : {player_id: gross score}
    pars   : {player_id: par of that player's own tee for this hole}

    Returns [] when nobody is eligible, one id for an outright winner, or
    several when they tie.  With both rules off this is exactly the plain
    `min()` both engines did before, which is what makes the default path
    unchanged.
    """
    if not scores:
        return []

    eligible = list(scores)

    # The steal first: if anybody made a natural, nobody else can win.
    if birdie_steal:
        naturals = [pid for pid in eligible
                    if is_natural_birdie(gross.get(pid), pars.get(pid))]
        if naturals:
            eligible = naturals

    # Then the minimum.  A natural already clears it, so this cannot empty a
    # non-empty steal class.
    minimum = normalise_minimum(minimum)
    if minimum != MIN_NONE:
        eligible = [pid for pid in eligible
                    if meets_minimum(scores.get(pid), gross.get(pid),
                                     pars.get(pid), minimum)]

    if not eligible:
        return []

    best = min(scores[pid] for pid in eligible)
    return [pid for pid in eligible if scores[pid] == best]


def rules_line(minimum: str, birdie_steal: bool) -> str:
    """One phrase naming the rules in force, for a board or a receipt.

    Empty string when neither is on, so a caller can test it rather than
    render 'no minimum, no steal' at a group that plays plain skins.
    """
    bits = []
    minimum = normalise_minimum(minimum)
    if minimum == MIN_NET_PAR:
        bits.append('net par or better to win')
    elif minimum == MIN_GROSS_PAR:
        bits.append('gross par or better to win')
    if birdie_steal:
        bits.append('gross birdies steal')
    return ' · '.join(bits)
