"""
services/survivor.py
--------------------
Survivor calculator — a three-player "horse race".

A Survivor runs in two phases:

* **The Island** (stored `elimination`) — all three play; the strictly WORST
  score is knocked out.
  If the two worst scores tie, nobody goes and the elimination repeats on the
  next hole with all three still in.  (A tie for *low* is irrelevant here —
  only the bottom of the board matters.)
* **The Duel** (stored `decider`) — the surviving two play head-to-head; the
  strictly LOWER score
  wins the Survivor.  A tie carries the same two to the next hole.

The moment a Survivor is decided a fresh one starts on the very next hole with
all three back in, so a full 18 yields at most nine (each takes a minimum of
two holes).

The round's LAST hole in play order can host neither an elimination nor a
carry, so it settles whatever is standing:

* three alive — the strictly low score wins outright; ANY tie for low is
  **no blood** and nobody pays;
* two alive   — the strictly low score wins; a tie **splits** the eliminated
  player's entry.

**The Zombie Option** (off by default, docs/design-review/handoff-survivor-zombie/
SPEC.md): when on, the eliminated player — the *Zombie* — keeps playing through
the decider.  Going **strictly low outright** on a decider hole brings them back
in; the higher of the two deciders then goes to Zombieville in their place, or if
the deciders tie all three are back.  Either way the SAME Survivor keeps running
— the index does not increment — so it can run to the last hole unsettled, which
is no blood and carries nothing.  A Zombie who goes low on the LAST hole *kills*
the Survivor: it pays nothing, and the Zombie is credited the trophy.

Settlement: every player antes ``Round.bet_unit`` per Survivor, so the pot is
3 × bet_unit and the winner nets +2 while the others are −1 each.  A split is
+½ / +½ / −1.  A killed or no-blood Survivor pays nothing.  Zero-sum in every
case.

Handicaps mirror Points 5-3-1 / Rabbit (Net %, Gross, Strokes-Off-Low), but
**full-round allocation only** — a Survivor's length isn't known until it ends,
so there's nothing stable to spread a per-segment allocation across.  See
docs/survivor.md.

Workflow (same shape as the other casual games):
  1. setup_survivor(...) creates the SurvivorGame row (idempotent).
  2. calculate_survivor(foursome) runs after every score submission and
     rebuilds SurvivorHoleResult from the HoleScore table.
  3. survivor_summary(foursome) returns the JSON the mobile UI consumes.
"""

from django.db import transaction

from core.models import HandicapMode, MatchStatus
from games.models import SurvivorGame, SurvivorHoleResult
from scoring.handicap import build_score_index, _strokes_on_hole, effective_hcp_for
from scoring.models import HoleScore
from services.hole_plan import play_order
from services.points_531 import _build_so_score_index
from core.handicap_math import round_half_up


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_survivor(
    foursome,
    handicap_mode: str = HandicapMode.NET,
    net_percent: int = 100,
    zombie_option: bool = True,
) -> 'SurvivorGame':
    """Create (or replace) the Survivor game for a foursome.  Safe to call
    again — the prior game + its hole results are dropped first."""
    SurvivorGame.objects.filter(foursome=foursome).delete()
    return SurvivorGame.objects.create(
        foursome      = foursome,
        handicap_mode = handicap_mode,
        net_percent   = max(0, min(200, int(net_percent))),
        zombie_option = bool(zombie_option),
        status        = MatchStatus.PENDING,
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _real_members(foursome) -> list:
    return list(
        foursome.memberships
        .select_related('player', 'tee')
        .filter(player__is_phantom=False)
    )


def _score_index(game, foursome) -> dict:
    """{pid: {hole: score_to_compare}} under the game's handicap mode."""
    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_so_score_index(foursome, net_percent=game.net_percent)
    return build_score_index(
        foursome,
        handicap_mode=game.handicap_mode,
        net_percent=game.net_percent,
    )


def _alloc_by_hole(game, foursome, order) -> dict:
    """{pid: {hole: strokes}} — handicap strokes on EVERY hole in play, so the
    stroke dots are defined for unscored holes too (gross − net can only report
    a stroke once a hole is scored).

    Full-round allocation in every mode — see the module docstring for why
    Survivor has no per-segment option.
    """
    memberships = [m for m in _real_members(foursome) if m.tee_id is not None]
    alloc = {m.player_id: {} for m in memberships}
    if game.handicap_mode == HandicapMode.GROSS:
        return alloc

    npct = game.net_percent or 100
    phcps = [m.playing_handicap for m in memberships
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    for m in memberships:
        if game.handicap_mode == HandicapMode.STROKES_OFF:
            hcp = round_half_up(max(0, (m.playing_handicap or 0) - low) * npct / 100)
        else:
            hcp = effective_hcp_for(m, npct)
        if hcp <= 0:
            continue
        per = alloc[m.player_id]
        for h in order:
            s = _strokes_on_hole(hcp, m.tee.hole(h).get('stroke_index', 18))
            if s:
                per[h] = s
    return alloc


def _hole_scores(score_index, pids, hole):
    """(complete, {pid: score}) across `pids` — complete only when every one of
    them has a score on this hole."""
    out = {}
    for pid in pids:
        s = score_index.get(pid, {}).get(hole)
        if s is None:
            return False, {}
        out[pid] = s
    return True, out


def _sole_worst(scores: dict):
    """The player with the strictly highest score, or None when the two worst
    tie (which includes an all-square hole)."""
    if not scores:
        return None
    high = max(scores.values())
    trailers = [pid for pid, s in scores.items() if s == high]
    return trailers[0] if len(trailers) == 1 else None


def _sole_best(scores: dict):
    """The player with the strictly lowest score, or None on a tie for low."""
    if not scores:
        return None
    low = min(scores.values())
    leaders = [pid for pid, s in scores.items() if s == low]
    return leaders[0] if len(leaders) == 1 else None


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

def _run_survivor(game, foursome, score_index, real_ids):
    """Walk the play order and build the Survivor schedule.

    Returns (rows, survivors, fully_scored, state_by_hole):
      * rows      — unsaved SurvivorHoleResult instances (scored holes only)
      * survivors — [{index, holes, eliminated, winner, outcome, complete}];
                    outcome is 'won' | 'split' | 'no_blood' | 'killed' | 'live'
      * fully_scored — count of fully-scored holes
      * state_by_hole — {hole: (alive_ids_before, zombie_id_before)}, so the
                    summary can say who was in play on each hole without
                    re-deriving it from the rows.

    Only fully-scored holes advance the state; an unscored hole is skipped and
    the state carries (same convention as services/rabbit.py), so a group that
    posts hole 6 before hole 5 still reads correctly once both land.

    With the Zombie Option ON a decider hole needs ALL THREE scores, not just
    the two still alive — the resurrection test is about the Zombie's score, so
    the hole can't resolve until they post it.
    """
    order = play_order(foursome.round, foursome)
    rows: list = []
    survivors: list = []
    fully_scored = 0
    state_by_hole: dict = {}

    zombie_on = bool(getattr(game, 'zombie_option', False))
    last_hole = order[-1] if order else None
    alive     = list(real_ids)
    idx       = 1
    holes     = []          # holes consumed by the Survivor in progress
    eliminated_id = None

    def close(outcome, winner_id):
        """Bank the Survivor in progress and reset for the next one."""
        nonlocal alive, idx, holes, eliminated_id
        survivors.append({
            'index'      : idx,
            'holes'      : list(holes),
            'eliminated' : eliminated_id,
            'winner'     : winner_id,
            'outcome'    : outcome,
            'complete'   : True,
        })
        alive, holes, eliminated_id = list(real_ids), [], None
        idx += 1

    for hole in order:
        # With the option on the Zombie's score is part of the hole: the
        # resurrection test needs it, so the hole isn't resolvable without it.
        needed = list(alive)
        if zombie_on and eliminated_id is not None:
            needed.append(eliminated_id)
        is_last = hole == last_hole
        # **Recorded for EVERY hole, scored or not.** It used to be written
        # after the completeness check, so an unscored hole had no state and
        # the summary fell back to "all three alive, no Zombie" — wrong for
        # any hole in the middle of a Survivor, and why the play screen had
        # to walk back to the last scored hole to draw its banner. The card
        # for the hole in play needs the standing it is ABOUT to be played
        # under, which is exactly this.
        state_by_hole[hole] = {
            'alive'   : list(alive),
            'zombie'  : eliminated_id,
            'survivor': idx,
            'first'   : holes[0] if holes else hole,
            # What the hole will be played AS. The resolved rows carry their
            # own `role`; this is the same question asked before the scores.
            'role'    : (SurvivorHoleResult.FINAL if is_last
                         else SurvivorHoleResult.ELIMINATION if len(alive) > 2
                         else SurvivorHoleResult.DECIDER),
        }
        complete, scores = _hole_scores(score_index, needed, hole)
        if not complete:
            continue                       # skip unscored; state carries
        fully_scored += 1
        holes.append(hole)
        # Only the players still in decide the hole; the Zombie is judged
        # separately, below.
        live_scores = {pid: sc for pid, sc in scores.items() if pid in alive}

        if len(alive) > 2:
            # ── Elimination phase ────────────────────────────────────────
            if is_last:
                # No room to eliminate AND decide: the low ball takes it, and
                # any tie for low is no blood.
                winner = _sole_best(live_scores)
                rows.append(SurvivorHoleResult(
                    game=game, hole_number=hole, survivor_index=idx,
                    role=SurvivorHoleResult.FINAL, winner_id=winner,
                    event=(SurvivorHoleResult.WON if winner
                           else SurvivorHoleResult.NO_BLOOD)))
                close('won' if winner else 'no_blood', winner)
                continue

            out = _sole_worst(live_scores)
            rows.append(SurvivorHoleResult(
                game=game, hole_number=hole, survivor_index=idx,
                role=SurvivorHoleResult.ELIMINATION, eliminated_id=out,
                event=(SurvivorHoleResult.ELIMINATED if out
                       else SurvivorHoleResult.NO_ELIMINATION)))
            if out is not None:
                eliminated_id = out
                alive = [pid for pid in alive if pid != out]
            continue

        # ── Decider phase (two alive) ────────────────────────────────────
        role = SurvivorHoleResult.FINAL if is_last else SurvivorHoleResult.DECIDER

        # Zombie first: strictly lower than BOTH deciders brings them back.
        # A tie for low is not enough.
        if zombie_on and eliminated_id is not None:
            zombie_score = scores[eliminated_id]
            if zombie_score < min(live_scores.values()):
                if is_last:
                    # Nothing left to play for: the Survivor dies unpaid, and
                    # the Zombie is credited with having decided it.
                    rows.append(SurvivorHoleResult(
                        game=game, hole_number=hole, survivor_index=idx,
                        role=role, resurrected_id=eliminated_id,
                        winner_id=eliminated_id,
                        event=SurvivorHoleResult.KILLED))
                    close('killed', eliminated_id)
                    continue

                # Back in.  The higher decider takes their place; if the two
                # deciders tie there is nobody to send out and all three are
                # back.  Either way this is the SAME Survivor — no close().
                worst = _sole_worst(live_scores)
                rows.append(SurvivorHoleResult(
                    game=game, hole_number=hole, survivor_index=idx,
                    role=role, resurrected_id=eliminated_id,
                    eliminated_id=worst,
                    event=SurvivorHoleResult.RESURRECTED))
                if worst is None:
                    alive, eliminated_id = list(real_ids), None
                else:
                    alive = [pid for pid in real_ids if pid != worst]
                    eliminated_id = worst
                continue

        winner = _sole_best(live_scores)
        if winner is not None:
            rows.append(SurvivorHoleResult(
                game=game, hole_number=hole, survivor_index=idx,
                role=role, winner_id=winner, event=SurvivorHoleResult.WON))
            close('won', winner)
            continue

        # Tied: the last hole splits the eliminated player's entry, anything
        # earlier carries the same two forward.
        rows.append(SurvivorHoleResult(
            game=game, hole_number=hole, survivor_index=idx, role=role,
            event=(SurvivorHoleResult.SPLIT if is_last
                   else SurvivorHoleResult.CARRIED)))
        if is_last:
            close('split', None)

    # A Survivor still standing when the scores run out is live, not settled.
    if holes:
        survivors.append({
            'index'      : idx,
            'holes'      : list(holes),
            'eliminated' : eliminated_id,
            'winner'     : None,
            'outcome'    : 'live',
            'complete'   : False,
        })

    return rows, survivors, fully_scored, state_by_hole


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_survivor(foursome) -> list:
    """Rebuild SurvivorHoleResult rows from the current HoleScore table and
    update the game's status."""
    try:
        game = foursome.survivor_game
    except SurvivorGame.DoesNotExist:
        return []

    real_ids = [m.player_id for m in _real_members(foursome)]
    SurvivorHoleResult.objects.filter(game=game).delete()
    if not real_ids:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    score_index = _score_index(game, foursome)
    holes_total = len(play_order(foursome.round, foursome))

    rows, _survivors, fully_scored, _state = _run_survivor(
        game, foursome, score_index, real_ids)

    if rows:
        SurvivorHoleResult.objects.bulk_create(rows)

    if fully_scored == 0:
        game.status = MatchStatus.PENDING
    elif fully_scored >= holes_total:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])
    return rows


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def _phcp_in_play(mode, npct, phcp, low_phcp) -> int:
    if mode == HandicapMode.GROSS:
        return 0
    if mode == HandicapMode.STROKES_OFF:
        return round_half_up(max(0, phcp - low_phcp) * npct / 100)
    return round_half_up(phcp * npct / 100)


def _empty_summary(bet_unit) -> dict:
    return {
        'status'    : 'pending',
        'handicap'  : {'mode': HandicapMode.NET, 'net_percent': 100},
        'zombie_option': True,
        'survivors' : [],
        'players'   : [],
        'holes'     : [],
        'scorecard' : {'players': [], 'holes': [], 'holes_in_play': []},
        'current'   : {'survivor': 1, 'alive_ids': [], 'role': 'elimination'},
        'money'     : {'bet_unit': bet_unit, 'pot': bet_unit * 3,
                       'max_liability': bet_unit},
    }


def survivor_summary(foursome) -> dict:
    """JSON-serialisable summary for the mobile Survivor screen + leaderboard."""
    bet_unit = float(foursome.round.bet_unit)
    try:
        game = foursome.survivor_game
    except SurvivorGame.DoesNotExist:
        return _empty_summary(bet_unit)

    members  = _real_members(foursome)
    by_pid   = {m.player_id: m.player for m in members}
    real_ids = list(by_pid.keys())
    if not real_ids:
        return _empty_summary(bet_unit)

    order       = play_order(foursome.round, foursome)
    score_index = _score_index(game, foursome)
    alloc       = _alloc_by_hole(game, foursome, order)
    zombie_on   = bool(game.zombie_option)

    rows, survivors, _, state_by_hole = _run_survivor(
        game, foursome, score_index, real_ids)
    results = {r.hole_number: r for r in rows}

    def short(pid):
        p = by_pid.get(pid)
        return p.short_name if p else None

    # Gross + par for display.
    gross_index: dict = {}
    for r in (
        HoleScore.objects
        .filter(foursome=foursome, player_id__in=real_ids)
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score')
    ):
        gross_index.setdefault(r['player_id'], {})[r['hole_number']] = r['gross_score']

    sample_tee = next((m.tee for m in members if m.tee_id is not None), None)
    par_by_hole, si_by_hole = {}, {}
    if sample_tee is not None:
        for h in order:
            info = sample_tee.hole(h)
            par_by_hole[h] = info.get('par')
            si_by_hole[h]  = info.get('stroke_index')

    # Which Survivor each hole belonged to.  Who was alive (and who was the
    # Zombie) going INTO each hole comes straight from the engine walk rather
    # than being re-derived here — with resurrections the roster can change
    # more than once inside a single Survivor.
    sv_of = {h: sv['index'] for sv in survivors for h in sv['holes']}

    # Per-hole grid, in play order.
    holes_out: list = []
    for hole in order:
        r = results.get(hole)
        st     = state_by_hole.get(hole) or {}
        live   = st.get('alive', list(real_ids))
        zombie = st.get('zombie')
        entries = []
        for pid in real_ids:
            entries.append({
                'player_id'    : pid,
                'short_name'   : by_pid[pid].short_name,
                'name'         : by_pid[pid].name,
                'net_score'    : score_index.get(pid, {}).get(hole),
                'gross'        : gross_index.get(pid, {}).get(hole),
                'strokes'      : alloc.get(pid, {}).get(hole, 0),
                'is_alive'     : pid in live,
                # Out of the Survivor but still playing it — only ever set with
                # the Zombie Option on; drives the plum row and score box.
                'is_zombie'    : bool(zombie_on and pid == zombie),
                'is_eliminated': bool(r and r.eliminated_id == pid),
                'is_resurrected': bool(r and r.resurrected_id == pid),
                'is_winner'    : bool(r and r.winner_id == pid),
            })
        holes_out.append({
            'hole'             : hole,
            # From the walk, so an UNSCORED hole knows which Survivor it
            # belongs to and what it will be played as — `sv_of` covers only
            # resolved holes, and the hole in play is by definition not one.
            'survivor'         : st.get('survivor') or sv_of.get(hole),
            'survivor_from'    : st.get('first'),
            'role'             : (r.role if r else st.get('role')),
            'par'              : par_by_hole.get(hole),
            'eliminated_id'    : r.eliminated_id if r else None,
            'eliminated_short' : short(r.eliminated_id) if (r and r.eliminated_id) else None,
            'resurrected_id'   : r.resurrected_id if r else None,
            'resurrected_short': short(r.resurrected_id) if (r and r.resurrected_id) else None,
            'winner_id'        : r.winner_id if r else None,
            'winner_short'     : short(r.winner_id) if (r and r.winner_id) else None,
            'event'            : r.event if r else None,
            'entries'          : entries,
        })

    # Shared scorecard block (the grid widget the Sixes / Wolf / Rabbit cards
    # render): gross + stroke dots per player, hole winner tinted.
    scorecard = {
        'players': [
            {'player_id': pid, 'name': by_pid[pid].name,
             'short_name': by_pid[pid].short_name}
            for pid in real_ids
        ],
        'holes': [
            {
                'hole'        : h['hole'],
                'par'         : h['par'],
                'stroke_index': si_by_hole.get(h['hole']),
                'winner_id'   : h['winner_id'],
                'winner_short': h['winner_short'],
                'scores': [
                    {'player_id' : e['player_id'],
                     'gross'     : e['gross'],
                     'strokes'   : e['strokes'],
                     # Drives the red cell on the shared grid, the way
                     # winner_id drives the green one.
                     'eliminated': e['is_eliminated'],
                     # …and the plum one when a Zombie comes back.
                     'resurrected': e['is_resurrected']}
                    for e in h['entries']
                ],
            }
            for h in holes_out
        ],
        'holes_in_play': list(order),
    }

    # Settlement — every player antes bet_unit per Survivor.
    money_by_pid = {pid: 0.0 for pid in real_ids}
    sv_out: list = []
    for s in survivors:
        holes  = s['holes']
        winner = s['winner']
        payout = 0.0
        if s['outcome'] == 'won' and winner is not None:
            payout = bet_unit * 2                    # the other two entries
            money_by_pid[winner] += payout
            for pid in real_ids:
                if pid != winner:
                    money_by_pid[pid] -= bet_unit
        elif s['outcome'] == 'split':
            # The final two tied on the last hole: they split the eliminated
            # player's entry and get their own back.
            loser     = s['eliminated']
            survivors_ = [pid for pid in real_ids if pid != loser]
            payout    = bet_unit / 2.0
            if loser is not None:
                money_by_pid[loser] -= bet_unit
                for pid in survivors_:
                    money_by_pid[pid] += payout
        sv_out.append({
            'index'            : s['index'],
            # 'killed' credits the Zombie the trophy (winner_id) while paying
            # nothing — the product call on design's open question.
            'killed_by_id'     : winner if s['outcome'] == 'killed' else None,
            'killed_by_short'  : short(winner) if s['outcome'] == 'killed' else None,
            'start_hole'       : holes[0] if holes else None,
            'end_hole'         : holes[-1] if holes else None,
            'holes'            : len(holes),
            'eliminated_id'    : s['eliminated'],
            'eliminated_short' : short(s['eliminated']) if s['eliminated'] else None,
            'winner_id'        : winner,
            'winner_short'     : short(winner) if winner else None,
            'outcome'          : s['outcome'],
            'complete'         : s['complete'],
            'value'            : bet_unit,
            'payout'           : payout,
        })

    phcp_by_pid = {m.player_id: (m.playing_handicap or 0) for m in members}
    phcps       = [v for v in phcp_by_pid.values()]
    low_phcp    = min(phcps) if phcps else 0
    players_out = []
    for pid, player in by_pid.items():
        players_out.append({
            'player_id'     : pid,
            'name'          : player.name,
            'short_name'    : player.short_name,
            'money'         : money_by_pid.get(pid, 0.0),
            'survivors_won' : sum(1 for s in sv_out if s['winner_id'] == pid),
            'phcp_in_play'  : _phcp_in_play(
                                game.handicap_mode, game.net_percent or 100,
                                phcp_by_pid.get(pid, 0), low_phcp),
        })
    players_out.sort(key=lambda e: (-e['money'], e['name']))

    # Live state — the Survivor in progress (or the last one played).
    live = next((s for s in survivors if not s['complete']), None)
    if live is not None:
        cur_alive = [pid for pid in real_ids if pid != live['eliminated']]
        current = {
            'survivor' : live['index'],
            'alive_ids': cur_alive,
            'role'     : 'decider' if live['eliminated'] else 'elimination',
            # WHO the Zombie is right now — the player out of the live
            # Survivor while the option is on. state_by_hole only covers
            # SCORED holes, so without this the client had to re-derive the
            # state for the hole being played, and a resurrection makes that
            # re-derivation wrong: after a Zombie comes back in and sends a
            # decider out, the Zombie is the DECIDER, not the man who
            # returned. The engine already tracks it; now it says so.
            'zombie_id': live['eliminated'] if zombie_on else None,
        }
    else:
        current = {
            'survivor' : (survivors[-1]['index'] + 1) if survivors else 1,
            'alive_ids': list(real_ids),
            'role'     : 'elimination',
            'zombie_id': None,
        }

    return {
        'status'    : game.status,
        'handicap'  : {'mode': game.handicap_mode,
                       'net_percent': game.net_percent},
        'zombie_option': zombie_on,
        'survivors' : sv_out,
        'players'   : players_out,
        'holes'     : holes_out,
        'scorecard' : scorecard,
        'current'   : current,
        'money'     : {
            'bet_unit'     : bet_unit,
            'pot'          : bet_unit * 3,
            # Worst case: lose every Survivor played.  A Survivor needs two
            # holes — except one that STARTS on the last hole, which settles
            # there in one — so n holes cap at (n + 1) // 2: nine on a full 18,
            # five on a nine-holer.
            'max_liability': bet_unit * max(1, (len(order) + 1) // 2),
        },
    }


# ---------------------------------------------------------------------------
# Score entry — one hole
# ---------------------------------------------------------------------------

# **The Island** and **The Duel** — the group's own names for the two phases
# (`~/Downloads/handoff-survivor-names`, 31 Oct 2026). The STORED role is
# still `elimination` / `decider`: those values are in every
# `SurvivorHoleResult` row and are what the client branches on, so renaming
# them would orphan the history to rename a label. Same call the Hot Spot →
# Hot Seat rename made.
#
# The names do not change with the Zombie option, which is the point of
# having them: a golfer learns one word for the phase he is in.
_PHASE_WORD = {
    SurvivorHoleResult.ELIMINATION: 'The Island',
    SurvivorHoleResult.DECIDER    : 'The Duel',
    SurvivorHoleResult.FINAL      : 'last hole',
}
_PHASE_CHIP = {
    SurvivorHoleResult.ELIMINATION: 'The Island',
    SurvivorHoleResult.DECIDER    : 'The Duel',
    SurvivorHoleResult.FINAL      : 'Last hole',
}


def _money_text(v: float) -> str:
    """`+$10`, `+$2.50`. Whole dollars lose the `.00`, as every other board."""
    whole = abs(v) == int(abs(v))
    body  = f'{abs(v):.0f}' if whole else f'{abs(v):.2f}'
    return f"{'+' if v >= 0 else '−'}${body}"


def _nets_text(nets: list) -> str:
    """`net 4 v 5`, lowest first — the comparison the hole was decided on."""
    vals = sorted(n for n in nets if n is not None)
    return f"net {' v '.join(str(v) for v in vals)}" if vals else ''


def survivor_hole_card(foursome, hole: int) -> dict:
    """Everything the Survivor score-entry screen draws for ONE hole.

    Built from `survivor_summary`, which has already walked the Survivors —
    who is alive, who is in Zombieville, what the hole is being played as and
    what it did are the ENGINE's answers, so the tray and the leaderboard
    cannot disagree. What is derived here is layout and wording.

    Returns `{}` when Survivor is not set up, so a caller can test the key.
    """
    summary = survivor_summary(foursome)
    holes   = summary.get('holes') or []
    here    = next((h for h in holes if h['hole'] == hole), None)
    if here is None:
        return {}

    order    = [h['hole'] for h in holes]
    pot      = float(summary['money']['pot'])
    stake    = float(summary['money']['bet_unit'])
    zombie_on = bool(summary.get('zombie_option'))
    role      = here.get('role') or SurvivorHoleResult.ELIMINATION
    sv_index  = here.get('survivor')
    members   = [m for m in foursome.memberships.all() if not m.player.is_phantom]

    # **Row order is the standing when the hole STARTS** — golfers still in,
    # then Zombieville — and it does not move when somebody goes out or comes
    # back on this hole. The tray says what happened; rows reorder on the
    # next hole, which is the one they describe.
    entries   = {e['player_id']: e for e in (here.get('entries') or [])}
    roster    = [m.player_id for m in members]
    in_play   = [pid for pid in roster if entries.get(pid, {}).get('is_alive')]
    out_now   = [pid for pid in roster if pid not in in_play]
    colour_of = {pid: i for i, pid in enumerate(roster)}

    players = []
    for pid in in_play + out_now:
        e = entries.get(pid, {})
        m = next((x for x in members if x.player_id == pid), None)
        players.append({
            'player_id'      : pid,
            'name'           : e.get('name') or (m.player.name if m else ''),
            'short'          : e.get('short_name'),
            'course_handicap': m.course_handicap if m else None,
            'colour_index'   : colour_of[pid],
            'strokes'        : e.get('strokes', 0),
            'gross'          : e.get('gross'),
            'net'            : e.get('net_score'),
            'is_alive'       : bool(e.get('is_alive')),
            'is_zombie'      : bool(e.get('is_zombie')),
        })

    short_of = {p['player_id']: p['short'] for p in players}
    name_of  = {p['player_id']: p['name'] for p in players}
    net_of   = {p['player_id']: p['net'] for p in players}
    complete = all(p['gross'] is not None for p in players)

    # The sections the players card draws, and what each one is playing for.
    alive_names = ' v '.join(short_of.get(p) or '' for p in in_play)
    sections = [{
        'key'   : 'in_play',
        'title' : (f'The Duel · {alive_names}' if role == SurvivorHoleResult.DECIDER
                   else 'Last hole · what is standing'
                   if role == SurvivorHoleResult.FINAL
                   else 'The Island · all three in'),
        'note'  : ('low takes it' if role == SurvivorHoleResult.DECIDER
                   else 'low takes it' if role == SurvivorHoleResult.FINAL
                   else 'worst goes out'),
        'player_ids': in_play,
    }]
    if out_now:
        sections.append({
            'key'   : 'zombieville',
            'title' : 'Zombieville',
            'note'  : ('low outright comes back' if zombie_on
                       else 'out of this Survivor'),
            'player_ids': out_now,
        })

    tee   = next((m.tee for m in members if m.tee_id), None)
    hinfo = tee.hole(hole) if tee else {}

    card = {
        'hole'        : hole,
        'par'         : here.get('par') or hinfo.get('par'),
        'yards'       : hinfo.get('yards'),
        'stroke_index': hinfo.get('stroke_index'),
        'nine'        : 'back nine' if hole > 9 else 'front nine',
        'survivor'    : {
            'index'    : sv_index,
            'from_hole': here.get('survivor_from'),
            'pot'      : pot,
            'stake'    : stake,
        },
        'role'       : role,
        'phase_chip' : _PHASE_CHIP.get(role, 'The Island'),
        'phase_note' : (f'{alive_names} · ${pot:.0f} pot'
                        if role == SurvivorHoleResult.DECIDER
                        else f'${pot:.0f} pot'),
        'sections'   : sections,
        'players'    : players,
        'zombie_option': zombie_on,
        'result'     : None,
        'next'       : None,
    }

    if not complete or not here.get('event'):
        return card

    card['result'] = _survivor_hole_result(
        here, role, players, in_play, out_now, short_of, name_of, net_of,
        summary, sv_index, stake, pot)

    # The Survivor that takes over, offered only once this one has ended.
    if card['result']['survivor_ended']:
        pos  = order.index(hole)
        nxt  = order[pos + 1] if pos + 1 < len(order) else None
        if nxt is not None:
            card['next'] = {
                'index'     : (sv_index or 0) + 1,
                'start_hole': nxt,
                'pot'       : pot,
                'title'     : f'Survivor {(sv_index or 0) + 1} from {nxt} '
                              f'· all three in',
                'note'      : 'The Island first: the worst score outright '
                              'goes out.',
            }
    return card


def _survivor_hole_result(here, role, players, in_play, out_now,
                          short_of, name_of, net_of, summary, sv_index,
                          stake, pot) -> dict:
    """The tray's three lines for a hole that has resolved.

    **Every string is written here**, because every one of them is a RULE —
    what a tie does, who pays whom, which Survivor takes over. A client
    composing them would be a second copy of the engine's own transitions,
    and the two would disagree the first time one of them was edited.
    """
    event = here['event']
    out   = here.get('eliminated_id')
    back  = here.get('resurrected_id')
    win   = here.get('winner_id')
    sv    = next((s for s in summary['survivors'] if s['index'] == sv_index), None)

    # ── Line 1: the chip ────────────────────────────────────────────────────
    # A tie carries NO nets: the numbers are the evidence for something
    # moving, and on a tie nothing did (the packet's own chip list).
    alive_nets = [net_of.get(p) for p in in_play]
    all_nets   = [net_of.get(p['player_id']) for p in players]
    chip_owner = None
    if event == SurvivorHoleResult.WON:
        chip, nets = f'{short_of.get(win)} takes it', _nets_text(alive_nets)
        chip_owner = win
    elif event == SurvivorHoleResult.RESURRECTED:
        chip, nets = f'{short_of.get(back)} low outright', _nets_text(all_nets)
        chip_owner = back
    elif event == SurvivorHoleResult.ELIMINATED:
        chip = f'{short_of.get(out)} out'
        nets = f'net {net_of.get(out)}, worst'
        chip_owner = out
    elif event == SurvivorHoleResult.KILLED:
        chip, nets = f'{short_of.get(win)} low outright', _nets_text(all_nets)
        chip_owner = win
    elif event == SurvivorHoleResult.SPLIT:
        chip, nets = 'Tie for low', ''
    elif event == SurvivorHoleResult.NO_BLOOD:
        chip, nets = 'Tie for low', ''
    elif event == SurvivorHoleResult.NO_ELIMINATION:
        chip, nets = 'Tie for worst', ''
    else:                                        # CARRIED
        chip, nets = 'Duel halved', ''

    # ── Line 2: the standing AFTER the hole ─────────────────────────────────
    def span(pid, text):
        return {'player_id': pid, 'text': text}

    ended = event in (SurvivorHoleResult.WON, SurvivorHoleResult.SPLIT,
                      SurvivorHoleResult.NO_BLOOD, SurvivorHoleResult.KILLED)
    money, money_is_cash = None, False
    if event == SurvivorHoleResult.WON:
        segs  = [span(win, f'{name_of.get(win)} wins Survivor {sv_index}')]
        money, money_is_cash = _money_text(stake * 2), True
    elif event == SurvivorHoleResult.SPLIT:
        pair  = [p for p in in_play]
        segs  = [span(pair[0], short_of.get(pair[0])), span(None, ' v '),
                 span(pair[1], short_of.get(pair[1]))]
        money, money_is_cash = f'{_money_text(stake / 2)} each', True
    elif event in (SurvivorHoleResult.NO_BLOOD, SurvivorHoleResult.KILLED):
        # **A kill reads as `No blood`, not as the Zombie's name.** He is
        # credited the trophy and paid nothing, so a standing line saying he
        # WON it would be money language over a hole that moved none. The
        # chip above already names him taking the hole outright, and line 3
        # says what that did. Design's screen 08.
        segs  = [span(None, 'No blood')]
        money = '—'
    else:
        # Still running: who is in, and what the next hole is played as.
        after_in  = [p['player_id'] for p in players if p['is_alive']]
        if back is not None and out is None:
            after_in = [p['player_id'] for p in players]
        if event == SurvivorHoleResult.RESURRECTED:
            after_in = [p['player_id'] for p in players
                        if p['player_id'] != out]
        if len(after_in) > 2:
            segs  = [span(None, 'All three in')]
            money = 'The Island'
        else:
            segs  = [span(after_in[0], short_of.get(after_in[0])),
                     span(None, ' v '),
                     span(after_in[1], short_of.get(after_in[1]))]
            money = 'The Duel'

    # ── Line 3: what happened, and what it costs ────────────────────────────
    nxt_hole = None
    order    = [h['hole'] for h in summary['holes']]
    pos      = order.index(here['hole'])
    if pos + 1 < len(order):
        nxt_hole = order[pos + 1]

    # **Who is CHASING is not who went out on this hole.** `eliminated_id` is
    # this hole's event and is None on a halved decider — the man chasing has
    # been in Zombieville since earlier in the Survivor, which is the standing
    # the hole was played under. Reading the event gave `None still chasing`.
    chaser = out_now[0] if out_now else None
    loser  = (sv or {}).get('eliminated_id') or chaser

    if event == SurvivorHoleResult.WON:
        lead = f"Won on {here['hole']}"
        rest = f"${stake:.0f} from each of the other two"
    elif event == SurvivorHoleResult.CARRIED:
        lead = ''
        rest = (f'A tie carries. The Duel again on {nxt_hole}, '
                f'{short_of.get(chaser)} still chasing.')
    elif event == SurvivorHoleResult.RESURRECTED and out is not None:
        lead = f'{short_of.get(back)} is back in.'
        rest = (f'{short_of.get(out)} had the higher score in the Duel and '
                f'goes to Zombieville. The Duel on {nxt_hole}.')
    elif event == SurvivorHoleResult.RESURRECTED:
        lead = f'{short_of.get(back)} is back in.'
        rest = (f'The Duel tied, so nobody goes out. '
                f'The Island on {nxt_hole}.')
    elif event == SurvivorHoleResult.ELIMINATED:
        lead = f'{short_of.get(out)} goes to Zombieville.'
        rest = (f'A low score outright on {nxt_hole} brings '
                f'{short_of.get(out)} back.'
                if summary.get('zombie_option')
                else f'{short_of.get(out)} is out of this Survivor.')
    elif event == SurvivorHoleResult.NO_ELIMINATION:
        lead = ''
        rest = f'Nobody goes out. The Island again on {nxt_hole}.'
    elif event == SurvivorHoleResult.SPLIT:
        lead = ''
        rest = (f'Hole {here["hole"]} settles what is standing. '
                f'{short_of.get(in_play[0])} and {short_of.get(in_play[1])} '
                f'split {short_of.get(loser)}’s ${stake:.0f}.')
    elif event == SurvivorHoleResult.KILLED:
        lead = ''
        rest = 'A Zombie win on 18 kills the Survivor. Nobody pays.'
    else:                                        # NO_BLOOD
        lead = ''
        rest = 'Nobody took it outright, so nobody pays.'

    return {
        'event'         : event,
        'phase_word'    : _PHASE_WORD.get(role, 'elimination'),
        'chip'          : chip,
        'chip_nets'     : nets,
        'chip_player_id': chip_owner,
        'standing'      : segs,
        'standing_right': money,
        'right_is_money': money_is_cash,
        'line_lead'     : lead,
        'line_rest'     : rest,
        'survivor_ended': ended,
    }
