"""
services/annandale_friday.py
----------------------------
Annandale Friday — one group of FIVE or SIX golfers on one card, split into
teams that make three better-ball Nassaus.

* **Six golfers:** three pairs, and every pair plays the other two — three
  Nassaus, each golfer in two of them.
* **Five golfers:** a pair and a three. The pair plays each pair OF the three
  — three Nassaus. The pair is in all three; the others are in two each.

Four golfers is deliberately not offered: a foursome plays a standard Nassau.

The matches are ordinary child ``NassauGame`` rows (game_type af_1/2/3,
linked to an ``AnnandaleFridayGame`` by ``NassauGame.annandale_game``), so the
whole Nassau engine — Front / Back / Overall, presses, close-out, 2nd-ball
tiebreak, Claremont, loss cap — is reused as-is. Same shape as
``services.triple_nassau``; two things differ from it:

* **Handicap is the FIELD's, not the pair's.** Off the low man of the whole
  group by default, so a golfer takes the same strokes into every match. The
  child slugs are NOT in ``TRIPLE_CHILD_SLUGS``, so ``nassau._get_score_index``
  already routes them to the field-wide strokes-off index.
* **Matches are 2v2, so the 2nd ball exists.** Tiebreak and Claremont both
  apply, which Triple Nassau's 1v1s cannot have.

Presses use the engine's own rule — the NINE at 2, 4, 6 or 8 down — not a
press on the latest bet. Paul, 29 Oct 2026: one press rule for every Nassau
in the app. The packet's reference drew the other rule; its "press 2 starts
on 8" example is the one place the two disagree.

Workflow (the casual-game shape):
  1. setup_annandale_friday(...) creates the container + three child matches.
  2. calculate_annandale_friday(foursome) runs after every score submission.
  3. annandale_friday_summary(foursome) returns the JSON the mobile UI reads.
"""

from decimal import Decimal

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import AnnandaleFridayGame, NassauGame
from services.nassau import (
    setup_nassau, calculate_nassau, nassau_summary, add_manual_press,
)


AF_CHILD_SLUGS = ('af_1', 'af_2', 'af_3')
GROUP_SIZES = (5, 6)


class AnnandaleShapeError(ValueError):
    """The teams do not make an Annandale Friday. Message is safe to show."""


class AnnandaleLocked(Exception):
    """A team change asked for past the edit ceiling. Message is safe to show."""


class AnnandalePressRefused(ValueError):
    """A manual press the rules do not allow. Message is safe to show."""


# ---------------------------------------------------------------------------
# The shape — pure, so the rules are testable without a database
# ---------------------------------------------------------------------------

def shape_problem(teams: list, roster_ids=None) -> str | None:
    """What is wrong with this split, in a sentence — or None if it plays.

    The setup screen's matches box says exactly this and keeps Next off, so
    the server and the client must agree on it; this is the server's half.

    ``roster_ids``: when given, every golfer in the group must be on exactly
    one team. An Annandale Friday is the whole card — a golfer left off a
    team would be on the card and in no match.
    """
    teams = [list(t) for t in (teams or []) if t]
    flat = [p for t in teams for p in t]
    if len(flat) != len(set(flat)):
        return 'A golfer is on two teams.'
    if roster_ids is not None:
        roster = set(roster_ids)
        if len(roster) not in GROUP_SIZES:
            return ('Annandale Friday is for a group of 5 or 6 — this group '
                    f'has {len(roster)}.')
        missing = roster - set(flat)
        if missing:
            n = len(missing)
            return (f'{n} golfer{"s are" if n > 1 else " is"} not on a team.')
        if set(flat) - roster:
            return 'A team has a golfer who is not in this group.'
    sizes = sorted(len(t) for t in teams)
    n = len(flat)
    if n == 6:
        if sizes == [2, 2, 2]:
            return None
        return 'Six golfers play as three pairs.'
    if n == 5:
        if sizes == [2, 3]:
            return None
        return 'Five golfers play as a pair and a three.'
    return f'Annandale Friday is for a group of 5 or 6 — the teams hold {n}.'


def matches_for(teams: list) -> list:
    """The three Nassaus the teams make, in child order, as (side1, side2).

    Six: pairs T0, T1, T2 → T0 v T1, T0 v T2, T1 v T2.
    Five: the pair P against each pair of the three [x, y, z] →
    P v xy, P v xz, P v yz — the pair is side 1 in all three, so it reads as
    the pair's three matches.

    Assumes a valid shape; call ``shape_problem`` first.
    """
    teams = [list(t) for t in teams if t]
    if len(teams) == 3:
        a, b, c = teams
        return [(a, b), (a, c), (b, c)]
    pair  = next(t for t in teams if len(t) == 2)
    three = next(t for t in teams if len(t) == 3)
    x, y, z = three
    return [(pair, [x, y]), (pair, [x, z]), (pair, [y, z])]


def _variant(second_ball_tiebreak: bool, claremont: bool) -> str:
    """Claremont makes the 2nd ball a bet of its own, so with it on the
    tiebreak has nothing left to break — it wins when both are asked for."""
    if claremont:
        return 'claremont'
    return 'tiebreak_2nd' if second_ball_tiebreak else 'none'


def _press_mode(auto_press: bool, manual_press: bool) -> str:
    if auto_press and manual_press:
        return 'both'
    if auto_press:
        return 'auto'
    if manual_press:
        return 'manual'
    return 'none'


def _same_teams(a: list, b: list) -> bool:
    """Same split, ignoring order inside a team. Team ORDER matters — it is
    the colour each team wears and which match is which."""
    return [frozenset(t) for t in (a or [])] == [frozenset(t) for t in (b or [])]


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

def _container_for(foursome):
    try:
        return foursome.annandale_friday_game
    except AnnandaleFridayGame.DoesNotExist:
        return None


@transaction.atomic
def setup_annandale_friday(
    foursome,
    teams:                list,
    handicap_mode:        str   = HandicapMode.STROKES_OFF,
    net_percent:          int   = 100,
    second_ball_tiebreak: bool  = True,
    claremont:            bool  = False,
    auto_press:           bool  = True,
    manual_press:         bool  = False,
    press_unit:           float = 0.00,
    loss_cap                    = None,
) -> AnnandaleFridayGame:
    """Create or update this foursome's Annandale Friday.

    One set of options for every Nassau. The stake per bet is the round's
    ``bet_unit``, as for every Nassau; ``press_unit`` is the press stake.

    **Teams lock at the edit ceiling** (`services/edit_window`): a redraw
    re-decides every match, including holes already settled under the old
    teams. Settings stay open all round, and a settings-only save updates the
    three matches IN PLACE — rebuilding them would delete the manual presses
    a group has already called.
    """
    teams = [[int(p) for p in t] for t in (teams or []) if t]
    roster = [m.player_id for m in foursome.memberships.select_related('player')
              if not m.player.is_phantom]
    problem = shape_problem(teams, roster)
    if problem:
        raise AnnandaleShapeError(problem)

    variant    = _variant(second_ball_tiebreak, claremont)
    press_mode = _press_mode(auto_press, manual_press)
    net_percent = max(0, min(200, int(net_percent)))
    if loss_cap is not None:
        loss_cap = Decimal(str(loss_cap))
        if loss_cap <= 0:
            loss_cap = None

    container = _container_for(foursome)
    if container is not None and _same_teams(container.teams, teams):
        container.teams = teams        # order inside a team may have moved
        container.save(update_fields=['teams'])
        container.matches.update(
            handicap_mode = handicap_mode,
            net_percent   = net_percent,
            variant       = variant,
            press_mode    = press_mode,
            press_unit    = Decimal(str(press_unit or 0)),
            loss_cap      = loss_cap,
        )
        calculate_annandale_friday(foursome)
        return container

    if container is not None:
        from services.edit_window import edits_open, closed_reason
        if not edits_open(foursome):
            raise AnnandaleLocked(closed_reason(
                'The teams',
                'every match is made from them, including the holes already '
                'settled'))
        container.delete()             # cascades to the three matches

    # Stray child rows from an interrupted setup.
    NassauGame.objects.filter(
        foursome=foursome, game_type__in=AF_CHILD_SLUGS).delete()

    container = AnnandaleFridayGame.objects.create(
        foursome=foursome, teams=teams, status=MatchStatus.PENDING)
    for slug, (side1, side2) in zip(AF_CHILD_SLUGS, matches_for(teams)):
        game = setup_nassau(
            foursome,
            team1_ids     = side1,
            team2_ids     = side2,
            handicap_mode = handicap_mode,
            net_percent   = net_percent,
            press_mode    = press_mode,
            press_unit    = press_unit,
            variant       = variant,
            play_front    = True,
            play_back     = True,
            play_overall  = True,
            single_match  = False,
            loss_cap      = loss_cap,
            game_type     = slug,
        )
        game.annandale_game = container
        game.save(update_fields=['annandale_game'])

    # Drop the cached reverse OneToOne, or a summary taken from this same
    # foursome object reads the container that was just deleted.
    foursome._state.fields_cache.pop('annandale_friday_game', None)
    calculate_annandale_friday(foursome)
    return container


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_annandale_friday(foursome) -> AnnandaleFridayGame | None:
    """Recompute the three matches and roll the container status up."""
    container = _container_for(foursome)
    if container is None:
        return None

    children = list(container.matches.all())
    any_scored, all_complete = False, bool(children)
    for child in children:
        g = calculate_nassau(foursome, child.game_type)
        if g is None:
            all_complete = False
            continue
        if g.status != MatchStatus.PENDING:
            any_scored = True
        if g.status != MatchStatus.COMPLETE:
            all_complete = False

    container.status = (
        MatchStatus.COMPLETE         if (children and all_complete)
        else MatchStatus.IN_PROGRESS if any_scored
        else MatchStatus.PENDING
    )
    container.save(update_fields=['status'])
    return container


# ---------------------------------------------------------------------------
# Manual press
# ---------------------------------------------------------------------------

def _current_nine(summary: dict) -> tuple[str, int] | None:
    """(nine, margin) for the nine being played next, or None once the round
    has nothing left to press on."""
    played = len(summary.get('holes') or [])     # scored, in play order
    n = len((summary.get('scorecard') or {}).get('holes_in_play') or []) or 18
    if played >= n:
        return None
    nine = 'front' if played < n // 2 else 'back'
    key = 'front9' if nine == 'front' else 'back9'
    return nine, int((summary.get(key) or {}).get('margin') or 0)


def press_allowed(summary: dict) -> bool:
    """Whether a manual press can be called in this match right now.

    **1 down or level** — the packet's rule. At 2 down the auto press has
    already fired, so a manual press is for the side that wants a bet before
    it gets there. That is wider than the plain Nassau's `can_press`, which
    needs a side to be DOWN; level is allowed here on purpose.
    """
    if summary.get('press_mode') not in ('manual', 'both'):
        return False
    if summary.get('status') == MatchStatus.COMPLETE:
        return False
    cur = _current_nine(summary)
    if cur is None:
        return False
    _, margin = cur
    if abs(margin) > 1:
        return False
    return bool(summary.get('can_press')) or margin == 0


def press_annandale(foursome, match: int, start_hole: int):
    """Call a manual press in match 1, 2 or 3, from ``start_hole`` to the end
    of that nine. Refuses with a sentence when the rules do not allow it."""
    if match not in (1, 2, 3):
        raise AnnandalePressRefused('There are three matches: 1, 2 or 3.')
    slug = AF_CHILD_SLUGS[match - 1]
    if _container_for(foursome) is None:
        raise AnnandalePressRefused('No Annandale Friday is set up for this group.')
    s = nassau_summary(foursome, slug)
    if s is None:
        raise AnnandalePressRefused('That match is not set up.')
    if s.get('press_mode') not in ('manual', 'both'):
        raise AnnandalePressRefused('Manual presses are off for this game.')
    if not press_allowed(s):
        raise AnnandalePressRefused(
            'A press can be called when a side is 1 down or the match is level.')
    try:
        press = add_manual_press(foursome, start_hole, game_type=slug)
    except ValueError as e:
        raise AnnandalePressRefused(str(e)) from e
    calculate_annandale_friday(foursome)
    return press


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def settings_chips(summary: dict) -> list[str]:
    """The board's settings strip: the shared chips, then the STAKES.

    `services.game_settings` leaves the stake out on purpose — its unit is
    game-specific — but this game's unit is plain (a bet, a press), and the
    stakes sat on the board beside the money, where "Bet $10 · Press $10"
    read as part of what had been won (Paul, 29 Oct 2026: "move the $10 bet
    and $10 press to the top with the other parameters").
    """
    from services.game_settings import _money, settings_chips as shared
    out = shared(summary)
    bet = _money(summary.get('bet_unit'))
    if bet:
        out.append(f'{bet} a bet')
    press = summary.get('press_unit') or 0
    if (summary.get('auto_press') or summary.get('manual_press')) and press:
        out.append(f'{_money(press)} a press')
    return out


def annandale_friday_summary(foursome) -> dict | None:
    """The three Nassau summaries, the teams, and each golfer's net across
    every match he is in. None when no Annandale Friday is configured.

    A golfer's net is read off each match's own settled ``payouts.total``
    (per golfer, +ve = side 1 up), never recomputed — the engine owns presses,
    Claremont and the loss cap, and a second sum is how two figures for one
    golfer come to disagree.
    """
    container = _container_for(foursome)
    if container is None:
        return None

    teams   = [list(t) for t in (container.teams or [])]
    members = {m.player_id: m
               for m in foursome.memberships.select_related('player')}
    team_of = {pid: i for i, t in enumerate(teams) for pid in t}

    def _pinfo(pid):
        m = members.get(pid)
        p = m.player if m else None
        return {
            'player_id'       : pid,
            'name'            : p.name if p else '',
            'short_name'      : p.short_name if p else '',
            'playing_handicap': (m.playing_handicap if m else None),
            'team'            : team_of.get(pid),
        }

    order = [pid for t in teams for pid in t]
    net_by_pid = {pid: 0.0 for pid in order}
    # What every bet would pay if the round stopped now — the board's "now"
    # figure. The ledger shows this until the round ends; a ledger reading
    # $0 under a board reading +$20 "now" was the first thing the phone said.
    live_by_pid = {pid: 0.0 for pid in order}
    # Strokes in play, read off the matches' own teams — the same figure in
    # every match because the allocation is the field's. Score entry's
    # keypad states it; reading it here keeps that caption from carrying a
    # second copy of the handicap rules.
    strokes_by_pid: dict = {}
    # Each golfer's money match by match — what his total is MADE of. The
    # ledger shows it under the total so the numbers on the board reconcile:
    # "+$70" with nothing beside it, under a match card saying "+$40", was
    # three right numbers nobody could connect (Paul, 29 Oct 2026).
    by_match_pid: dict = {pid: [] for pid in order}
    matches_by_pid = {pid: 0 for pid in order}
    matches = []
    cfg = {}

    children = {c.game_type: c for c in container.matches.all()}
    for i, (slug, (side1, side2)) in enumerate(zip(AF_CHILD_SLUGS,
                                                   matches_for(teams))):
        if slug not in children:
            continue
        s = nassau_summary(foursome, slug)
        if s is None:
            continue
        # Each side's golfers in CARD order. The Nassau engine lists a team in
        # database order, so the board said "Jim & Paul" under a pill saying
        # "Paul & Jim" — two names for one side on one screen.
        for key, ids in (('team1', side1), ('team2', side2)):
            pos = {pid: n for n, pid in enumerate(ids)}
            s['teams'][key] = sorted(
                s['teams'].get(key, []),
                key=lambda pl: pos.get(pl['player_id'], len(pos)))
        # CAPPED: the loss cap is per side per Nassau, and `total` is the
        # uncapped sum — settling on it would pay out past the cap.
        total = float(s['payouts']['total_capped'])
        live = float(s['payouts'].get('live_total') or 0)
        for side in ('team1', 'team2'):
            for pl in s['teams'].get(side, []):
                strokes_by_pid.setdefault(pl['player_id'], pl.get('phcp_in_play'))
        for pid in side1:
            by_match_pid.setdefault(pid, []).append({
                'match': i + 1, 'vs_ids': list(side2),
                'net': round(total, 2), 'live_net': round(live, 2)})
        for pid in side2:
            by_match_pid.setdefault(pid, []).append({
                'match': i + 1, 'vs_ids': list(side1),
                'net': round(-total, 2), 'live_net': round(-live, 2)})
        for pid in side1:
            net_by_pid[pid] = net_by_pid.get(pid, 0.0) + total
            live_by_pid[pid] = live_by_pid.get(pid, 0.0) + live
            matches_by_pid[pid] = matches_by_pid.get(pid, 0) + 1
        for pid in side2:
            net_by_pid[pid] = net_by_pid.get(pid, 0.0) - total
            live_by_pid[pid] = live_by_pid.get(pid, 0.0) - live
            matches_by_pid[pid] = matches_by_pid.get(pid, 0) + 1
        if not cfg:
            child = children[slug]
            cfg = {
                'handicap_mode'       : s.get('handicap_mode'),
                'net_percent'         : s.get('net_percent', 100),
                'press_mode'          : s.get('press_mode', 'none'),
                'press_unit'          : float(s.get('press_unit', 0) or 0),
                'variant'             : child.variant,
                'loss_cap'            : (float(child.loss_cap)
                                         if child.loss_cap is not None else None),
            }
        matches.append({
            'match'       : i + 1,
            'game_type'   : slug,
            'side1_ids'   : list(side1),
            'side2_ids'   : list(side2),
            # Which team each side is, so the client colours a side by its
            # TEAM — in a five, all three opponents of the pair are clay.
            'side1_team'  : team_of.get(side1[0]),
            'side2_team'  : team_of.get(side2[0]),
            'can_press'   : press_allowed(s),
            'summary'     : s,
        })

    variant = cfg.get('variant', 'none')
    press_mode = cfg.get('press_mode', 'none')
    return {
        'status'              : container.status,
        'group_size'          : len(order),
        'handicap_mode'       : cfg.get('handicap_mode'),
        'net_percent'         : cfg.get('net_percent', 100),
        # The two raw keys `services.game_settings` reads, so the board's
        # settings strip states them in the same words as every Nassau.
        'variant'             : variant,
        'press_mode'          : press_mode,
        'second_ball_tiebreak': variant == 'tiebreak_2nd',
        'claremont'           : variant == 'claremont',
        'auto_press'          : press_mode in ('auto', 'both'),
        'manual_press'        : press_mode in ('manual', 'both'),
        'bet_unit'            : float(foursome.round.bet_unit),
        'press_unit'          : cfg.get('press_unit', 0.0),
        'loss_cap'            : cfg.get('loss_cap'),
        'teams'               : [[_pinfo(pid) for pid in t] for t in teams],
        'players'             : [
            {**_pinfo(pid),
             'strokes_in_play': strokes_by_pid.get(pid),
             'matches': matches_by_pid.get(pid, 0),
             'net'    : round(net_by_pid.get(pid, 0.0), 2),
             'live_net': round(live_by_pid.get(pid, 0.0), 2),
             'by_match': by_match_pid.get(pid, [])}
            for pid in order
        ],
        'matches'             : matches,
    }
