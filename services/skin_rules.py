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
* **Gross birdie steal.** A natural birdie beats a manufactured one — but
  **only a manufactured BIRDIE**. If the best ball on the hole is a net
  birdie and somebody made a real one, the real one wins; a net EAGLE still
  takes the hole (Paul, via Design, 28 Oct 2026). The rule says a birdie made
  with a shot does not beat one made without; it was never meant to outrank
  a score two under.

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

### The WORDS live here too

`rules_line` names the rules in force and `rules_note` states what they cost
a golfer; `copy_block` is the whole catalogue, for a setup screen describing
options nobody has chosen yet. All three are here for the reason the chips
already were: the first build spelled this rule in **five** places — the
board footnote, two strings in the setup card and two doc comments — and
they had already drifted apart by the time Design read them, which is how
`beats a lower net score` survived as the published wording of a rule that
never meant that.

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
    """Gross birdie or better — a natural eagle is a natural birdie too.

    Whether a natural STEALS is a separate question, and the answer is in
    `decide`: it does so only when the best ball on the hole is a net
    birdie, never over a net eagle.
    """
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

    # The steal first: a natural shuts the other balls out — but only when
    # the best ball on the hole is a NET BIRDIE.
    #
    # **A gross birdie beats a net birdie, not a net eagle** (Paul, via
    # Design, 28 Oct 2026). The first version let any natural win outright,
    # so a man who made 3 on a par 4 beat a man who made 3 with a stroke on
    # a par 5 — a net eagle, and the better score. The steal is there to say
    # a birdie made with a shot does not beat one made without; it was never
    # meant to outrank a score two under.
    #
    # A natural's own ranking score is at most its gross, which is already a
    # net birdie, so whenever a natural exists the best ball is a net birdie
    # or better. That leaves exactly two cases, and `== -1` is the one the
    # steal is for.
    if birdie_steal:
        naturals = [pid for pid in eligible
                    if is_natural_birdie(gross.get(pid), pars.get(pid))]
        if naturals:
            # A natural was found, so at least one eligible ball has a par
            # and this list is never empty.
            to_par = [scores[pid] - pars[pid] for pid in eligible
                      if scores.get(pid) is not None
                      and pars.get(pid) is not None]
            if min(to_par) == -1:
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


#: One place names each option and says what it does. A setup screen is
#: describing rules nobody has chosen yet, so it needs the catalogue rather
#: than the in-force line.
OPTION_COPY = {
    MIN_NET_PAR: {
        'key'  : MIN_NET_PAR,
        'label': 'Net par or better to win',
        'note' : 'A hole where nobody qualifies goes unwon.',
    },
    MIN_GROSS_PAR: {
        'key'  : MIN_GROSS_PAR,
        'label': 'Gross par or better to win',
        'note' : 'A hole where nobody qualifies goes unwon.',
    },
    'birdie_steal': {
        'key'  : 'birdie_steal',
        'label': 'Gross birdies steal',
        'note' : 'A gross birdie beats a net birdie, not a net eagle.',
    },
}


def copy_block() -> list:
    """Every option, in a fixed order, for a screen offering the choice."""
    return [dict(OPTION_COPY[k])
            for k in (MIN_NET_PAR, MIN_GROSS_PAR, 'birdie_steal')]


def rules_note(minimum: str, birdie_steal: bool) -> str:
    """What the rules in force actually COST a golfer, in one sentence.

    The minimum outranks the steal, because a natural clears any minimum and
    so can never be the reason a hole goes unwon — and an unwon hole is the
    thing plain skins never does, which is the only reason this sentence is
    on a board at all.

    Empty when neither rule is on, so a caller tests it rather than printing
    a consequence at a group playing plain skins.
    """
    if normalise_minimum(minimum) != MIN_NONE:
        return OPTION_COPY[MIN_NET_PAR]['note']
    if birdie_steal:
        return OPTION_COPY['birdie_steal']['note']
    return ''


def rules_line(minimum: str, birdie_steal: bool) -> str:
    """One phrase naming the rules in force, for a board or a receipt.

    Empty string when neither is on, so a caller can test it rather than
    render 'no minimum, no steal' at a group that plays plain skins.
    """
    bits = []
    minimum = normalise_minimum(minimum)
    # The same labels as the catalogue, lower-cased: this phrase sits in
    # running text and the client sentence-cases each chip. Two spellings of
    # one rule is the thing this module exists to prevent.
    if minimum in (MIN_NET_PAR, MIN_GROSS_PAR):
        bits.append(OPTION_COPY[minimum]['label'][0].lower()
                    + OPTION_COPY[minimum]['label'][1:])
    if birdie_steal:
        bits.append(OPTION_COPY['birdie_steal']['label'][0].lower()
                    + OPTION_COPY['birdie_steal']['label'][1:])
    return ' · '.join(bits)
