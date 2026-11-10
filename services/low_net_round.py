"""
services/low_net_round.py
-------------------------
Low Net (Round) calculator — individual game, single round.

Each player's total adjusted score (18 holes) is ranked lowest-to-highest.
Lowest score wins.

Scoring
~~~~~~~
* Per-hole score is adjusted per LowNetRoundConfig (or defaults to full net):
    - 'net'         : gross − strokes (playing_handicap × net_percent / 100)
    - 'gross'       : raw gross score
    - 'strokes_off' : gross − max(0, own_handicap − foursome_low_handicap),
                      strokes allocated by hole stroke_index.
  The strokes_off reference is the lowest playing_handicap IN EACH FOURSOME
  (the low player in the group plays to 0), matching the match games; in a
  cup each group is its own match.  For SINGLES the reference is the lower of
  the 1-v-1 pairing, so it reflects the strokes given in that match.
  Single-foursome rounds are unaffected.
* Net-double-bogey cap: when Round.net_max_double_bogey is on, every
  per-hole effective score is capped at par + 2 (net par + 2 in gross
  terms).  When the flag is off, raw adjusted scores feed the total.

Public API
~~~~~~~~~~
    standings = low_net_round_standings(round_obj)
    summary   = low_net_round_summary(round_obj)
"""

from core.models import HandicapMode
from scoring.models import HoleScore
from scoring.handicap import _strokes_on_hole, make_strokes_fn, effective_hcp_for
from tournament.models import Foursome
from core.handicap_math import round_half_up


# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------

def cap_in_force(round_obj, handicap_mode, net_percent, force_cap=False) -> bool:
    """Is the net-double-bogey cap in force for this round and mode?

    Casually the cap only applies at full Net (100%): it is meaningless for
    Gross and was judged too surprising under a reduced allowance, so it is
    ignored outside Net-100% regardless of the stored round flag. An
    individual-play tournament passes ``force_cap`` and gets it at every
    allowance — never in Gross, where the board is meant to show the real card.

    **One writer**, because two surfaces ask it: the totals builder, which
    applies it, and :func:`stroke_play_hole_card`, which has to tell the
    keypad the ceiling a golfer is typing against. A second copy of this test
    is how the score screen comes to offer a maximum the engine does not
    enforce.
    """
    return bool(
        handicap_mode == HandicapMode.NET
        and (force_cap
             or (bool(round_obj.net_max_double_bogey) and net_percent == 100)))


def _build_ln_player_totals(round_obj, handicap_mode, net_percent,
                            participant_ids=None, force_cap=False):
    """
    Return {player_id: {'name': str, 'total': int, 'holes_played': int}}
    for all real players in the round, with handicap adjustment and the
    optional net-double-bogey cap applied per Round.net_max_double_bogey.

    `participant_ids` restricts the game to a SUBSET of the foursome — a subset
    side game (docs/parallel-games.md). None = all real players. ONLY the casual
    `low_net_round_standings` passes this from the round config; the Championship
    never does, so its scoring is unaffected.

    `force_cap` is the individual-play tournament rule: the cap is ALWAYS on and
    applies at any allowance, because the ceiling is stated in terms of the
    strokes actually received (par + 2 + strokes on the hole) and those already
    reflect the allowance. Casual callers leave it False and keep the historic
    Net-100%-only behaviour.
    """
    _subset = set(participant_ids) if participant_ids else None
    cap_enabled = cap_in_force(round_obj, handicap_mode, net_percent,
                               force_cap=force_cap)

    # The field, which is NOT always this round's own foursomes: a host round
    # of a cross-round skins pool borrows the groups whose golfers played
    # their cards in a linked round, because otherwise this board shows
    # blanks for them while the pool tab beside it shows them thru 18.
    # Every ordinary round gets its own foursomes and an empty restriction,
    # so that is the same code path rather than a second one.
    from services.multi_skins import pool_field_foursomes
    foursomes, _allowed = pool_field_foursomes(round_obj)

    def _counts(fs, m):
        """Is this membership part of the field this board is ranking?"""
        if m.player.is_phantom:
            return False
        if _subset is not None and m.player_id not in _subset:
            return False
        ok = _allowed.get(fs.pk)
        return ok is None or m.player_id in ok

    # membership lookup: {player_id: membership}  (across all foursomes)
    membership_map = {}
    for fs in foursomes:
        for m in fs.memberships.all():
            if _counts(fs, m):
                membership_map[m.player_id] = m

    # par lookup: {foursome_id: {hole_number: par}}
    par_index = {}
    for fs in foursomes:
        first_m = next(
            (m for m in fs.memberships.all() if m.tee_id is not None), None
        )
        if first_m:
            par_index[fs.pk] = {h['number']: h['par'] for h in first_m.tee.holes}

    # Partial-round-aware per-hole stroke allocators (scale + re-rank on a
    # 9-hole / back-9 round); a full round reduces to the standard allocation.
    strokes_fns = {fs.pk: make_strokes_fn(fs) for fs in foursomes}

    # For strokes_off: each player's reference low.  For team games it's the
    # lowest playing_handicap in the FOURSOME (the low player plays to 0), which
    # matches every match game (nassau, sixes, …).  For SINGLES the competition
    # is the 1-v-1 pairing, so each player anchors on the LOWER of their own
    # match — the Stroke Play tab then shows the strokes each golfer actually
    # gets in their singles match, not the foursome low.  Single-foursome rounds
    # are unaffected: the group low IS the field low.
    low_hcp_by_pid: dict = {}
    if handicap_mode == HandicapMode.STROKES_OFF:
        from games.models import MatchPlayBracket
        for fs in foursomes:
            real = [m for m in fs.memberships.all() if _counts(fs, m)]
            fs_low = min((m.playing_handicap for m in real), default=0)
            # Singles pairings anchor each player on their opponent, not the
            # group.  Falls back to the foursome low for team games.
            pairing_low = {}
            bracket = (MatchPlayBracket.objects
                       .filter(foursome=fs, bracket_type='cup_singles')
                       .prefetch_related('matches').first())
            if bracket:
                hcp = {m.player_id: m.playing_handicap for m in real}
                for mp in bracket.matches.all():
                    if mp.player1_id in hcp and mp.player2_id in hcp:
                        lo = min(hcp[mp.player1_id], hcp[mp.player2_id])
                        pairing_low[mp.player1_id] = lo
                        pairing_low[mp.player2_id] = lo
            for m in real:
                low_hcp_by_pid[m.player_id] = pairing_low.get(m.player_id, fs_low)

    qs = (
        HoleScore.objects
        # By FOURSOME, not by round — the field above may borrow a group from
        # a linked round. Identical to `foursome__round` on every round that
        # does not. A borrowed group's non-participants are dropped by the
        # `membership_map` miss in the loop below.
        .filter(foursome_id__in=[fs.pk for fs in foursomes],
                player__is_phantom=False)
        .exclude(gross_score=None)
        .values('foursome_id', 'player_id', 'player__name',
                # The SHORT name as well: the board's group card has a 78pt
                # label column, and every other card in the app labels a
                # golfer with `short_name` (which auto-fills to initials).
                'player__short_name',
                'hole_number', 'gross_score', 'net_score')
    )

    totals: dict = {}  # {player_id: {'name', 'total', 'holes_played'}}

    # ── Seed every real player with a PROSPECTIVE stroke plan ────────────────
    # So the Stroke Play scorecard shows where each player's handicap strokes
    # fall over the WHOLE round — including before the round starts / on holes
    # not yet played. Gross/net fill in per hole from the scores below.
    from services.hole_plan import holes_in_play as _holes_in_play
    in_play_by_fs = {}
    for fs in foursomes:
        # The foursome's OWN round: a borrowed group's play order belongs to
        # the round it is playing in, not to the host.
        hs_set = _holes_in_play(fs.round, fs)
        in_play_by_fs[fs.pk] = sorted(hs_set) if hs_set else list(range(1, 19))
    for fs in foursomes:
        holes_fs = in_play_by_fs.get(fs.pk) or list(range(1, 19))
        for m in fs.memberships.all():
            if m.player_id in totals or not _counts(fs, m):
                continue
            plan = {}
            if handicap_mode != HandicapMode.GROSS and m.tee_id is not None:
                for hole in holes_fs:
                    if handicap_mode == HandicapMode.NET:
                        eff = effective_hcp_for(m, net_percent)
                        s = strokes_fns[fs.pk](eff, m.tee, hole)
                    else:  # STROKES_OFF
                        si = m.tee.hole(hole).get('stroke_index', 18)
                        so_diff = round_half_up(
                            max(0, m.playing_handicap
                                - low_hcp_by_pid.get(m.player_id, 0))
                            * net_percent / 100)
                        s = _strokes_on_hole(so_diff, si)
                    if s > 0:
                        plan[hole] = s
            totals[m.player_id] = {
                'name'         : m.player.name,
                'short_name'   : m.player.short_name,
                'total'        : 0,
                'holes_played' : 0,
                'par_played'   : 0,
                'foursome_id'  : fs.pk,
                'handicap'     : m.playing_handicap,
                # The TRUE course handicap — `handicap` is the playing one
                # and differs on a mixed-par card. The board's label says CH.
                'course_handicap': m.course_handicap,
                # The INDEX as well as the playing handicap: the board draws
                # the index beside a name (Design's stroke play packet), and
                # the two answer different questions — CH is what you play
                # off today, the index is who you are.
                'handicap_index': str(m.player.handicap_index or ''),
                'holes'        : {},
                'stroke_plan'  : plan,
                'total_strokes': sum(plan.values()),
            }

    for hs in qs:
        pid  = hs['player_id']
        hole = hs['hole_number']
        fid  = hs['foursome_id']

        membership = membership_map.get(pid)
        if membership is None:
            continue

        # ── Handicap adjustment ─────────────────────────────────────────────
        if handicap_mode == HandicapMode.GROSS:
            adjusted = hs['gross_score']

        elif handicap_mode == HandicapMode.NET:
            if net_percent == 100 and hs['net_score'] is not None:
                adjusted = hs['net_score']
            else:
                if membership.tee_id is None:
                    continue
                eff = effective_hcp_for(membership, net_percent)
                adjusted = hs['gross_score'] - strokes_fns[fid](
                    eff, membership.tee, hole)

        else:  # STROKES_OFF
            if membership.tee_id is None:
                continue
            si       = membership.tee.hole(hole).get('stroke_index', 18)
            # Scale the strokes-off differential by net_percent, matching the
            # app-wide SO allowance (nassau.py / multi_skins.py / points_531.py).
            so       = round_half_up(
                max(0, membership.playing_handicap
                    - low_hcp_by_pid.get(pid, 0))
                * net_percent / 100)
            adjusted = hs['gross_score'] - _strokes_on_hole(so, si)

        # ── Net-double-bogey cap (round-level toggle) ───────────────────────
        par    = par_index.get(fid, {}).get(hole, 4)
        capped = min(adjusted, par + 2) if cap_enabled else adjusted

        strokes_given = hs['gross_score'] - adjusted  # positive = strokes received

        entry = totals.setdefault(pid, {
            'name'        : hs['player__name'],
            'short_name'  : hs['player__short_name'],
            'total'       : 0,
            'holes_played': 0,
            'par_played'  : 0,
            'foursome_id' : fid,
            'handicap'    : membership.playing_handicap,
            'course_handicap': membership.course_handicap,
            'handicap_index': str(membership.player.handicap_index or ''),
            'holes'       : {},   # {hole_number: {par, gross, net_adj, capped}}
        })
        entry['total']        += capped
        entry['holes_played'] += 1
        entry['par_played']   += par
        # Pull stroke index off the player's own tee so women's tees
        # (which can have a different SI ordering than men's) show
        # correctly on the scorecard.
        si_for_hole = None
        if membership.tee_id is not None:
            si_for_hole = membership.tee.hole(hole).get('stroke_index')
        entry['holes'][hole]   = {
            'par'         : par,
            'gross'       : hs['gross_score'],
            'strokes'     : strokes_given,
            'net'         : adjusted,
            'capped'      : capped,
            'stroke_index': si_for_hole,
        }

    return totals


def _rank_standings(player_totals, payouts_cfg, excluded_ids) -> list:
    """
    Rank a pre-built ``{player_id: totals}`` map into the standings list.

    Split out of ``low_net_round_standings`` so the identical ranking / tie /
    prize logic can be reused for each display mode (Gross / Net / Strokes-off)
    in the 12A selector — see docs/features/12a-scorecard-display-modes.md.
    Pass an empty ``payouts_cfg`` for a display-only mode (no prize money):
    only the round's actually-configured mode carries payouts.
    """
    # Sort by net-to-par (total − par_played) so rankings are always in
    # par-relative order regardless of tee/course-par differences between
    # foursomes.  Players with no holes played sort last.
    def _sort_key(kv):
        d = kv[1]
        if d['holes_played'] == 0:
            return (1, 0)           # unsorted players go to the bottom
        return (0, d['total'] - d['par_played'])

    rows = sorted(player_totals.items(), key=_sort_key)

    # ── Assign display ranks (all players, including excluded) ────────────────
    #
    # **The rank reads the SAME key the sort does.** It used to compare
    # `total - par_played` alone, which is 0 - 0 for a golfer who has not
    # posted a hole — so a man thru 0 tied the leader rather than sorting
    # under him, and a board with one finished card and three empty ones
    # read `T1` four times beside a +23 (Paul, 9 Nov 2026).
    #
    # Two golfers are tied only when the whole key matches, which keeps the
    # not-yet-started tied with each other and under everybody who has
    # played — where the sort already put them.
    ranked = []  # [(pid, data, display_rank)]
    rank = 1
    for i, (pid, data) in enumerate(rows):
        if i > 0 and _sort_key(rows[i]) != _sort_key(rows[i - 1]):
            rank = i + 1
        ranked.append((pid, data, rank))

    # ── Prize ranking — eligible (non-excluded) players only ─────────────────
    # Excluded players appear in the standings with their score visible, but
    # they cannot win prize money.  Prize positions are assigned as if excluded
    # players were not competing, so the $1st prize goes to the best-scoring
    # *eligible* player, $2nd to the next, and so on.
    # Only players who have actually scored compete for prizes — the roster is
    # now seeded with not-yet-started players (so their prospective scorecard
    # shows), and those must not be handed money.
    eligible_rows = [(pid, data) for pid, data in rows
                     if pid not in excluded_ids and data['holes_played'] > 0]

    prize_rank = 1
    eligible_ranked: list = []   # [(pid, prize_rank)]
    for i, (pid, data) in enumerate(eligible_rows):
        if i > 0:
            prev_ntp = eligible_rows[i-1][1]['total'] - eligible_rows[i-1][1]['par_played']
            curr_ntp = data['total'] - data['par_played']
            if curr_ntp > prev_ntp:
                prize_rank = i + 1
        eligible_ranked.append((pid, prize_rank))

    prize_rank_map: dict = {pid: r for pid, r in eligible_ranked}

    # Tied players split the money for the PLACES THEY OCCUPY (services/payout.py)
    # — a T2 pair shares 2nd and 3rd rather than taking 2nd each. None, not 0,
    # for a rank that pays nothing: the row shows no prize at all.
    from services.payout import split_tied_places
    prize_rank_payout: dict = {
        r: (amt or None)
        for r, amt in split_tied_places(
            payouts_cfg, [r for _pid, r in eligible_ranked]).items()
    }

    # ── Build standings list ──────────────────────────────────────────────────
    standings = []
    for pid, data, display_rank in ranked:
        hp          = data['holes_played']
        ntp         = (data['total'] - data['par_played']) if hp > 0 else None
        is_excluded = pid in excluded_ids
        payout      = None if is_excluded else prize_rank_payout.get(prize_rank_map.get(pid))
        standings.append({
            'rank'        : display_rank,
            # The PRIZE rank, which is not the display rank: an excluded
            # golfer holds a place on the board and is skipped for the money,
            # so the ledger has to name the rank the payout was assigned to.
            'prize_rank'  : prize_rank_map.get(pid),
            'player_id'   : pid,
            'player_name' : data['name'],
            'short_name'  : data.get('short_name', ''),
            'net_total'   : data['total'],
            'net_to_par'  : ntp,
            'holes_played': hp,
            'foursome_id' : data.get('foursome_id'),
            'excluded'    : is_excluded,
            'payout'      : payout,
            'handicap'    : data.get('handicap', 0),  # raw playing handicap
            'course_handicap': data.get('course_handicap'),
            'handicap_index': data.get('handicap_index', ''),
            'holes'       : data.get('holes', {}),   # {hole_number: hole_data}
            # Prospective full-round stroke allocation (all holes in play) +
            # the total strokes this player receives — drives the scorecard
            # dots that show before/independent of scores.
            'stroke_plan'    : data.get('stroke_plan', {}),
            'total_strokes'  : data.get('total_strokes', 0),
        })

    return standings


def _serialize_results(standings) -> list:
    """Shape a standings list into the wire ``results`` payload (one row per
    player). Shared by the configured-mode ``results`` and every entry in the
    12A ``modes`` block so all three modes carry an identical row shape."""
    return [
        {
            'rank'        : s['rank'],
            'player_id'   : s['player_id'],
            'name'        : s['player_name'],
            # What the board's group card labels a row with — see
            # `HoleGridScorecard`, whose label column is 78pt wide.
            'short_name'  : s.get('short_name', ''),
            'total_net'   : s['net_total'],
            'net_to_par'  : s['net_to_par'],
            'holes_played': s['holes_played'],
            'foursome_id' : s['foursome_id'],
            'excluded'    : s.get('excluded', False),
            'payout'      : s['payout'],
            'handicap'    : s.get('handicap', 0),
            # The TRUE course handicap. `handicap` is the playing one and
            # differs on a mixed-par card, so a board labelling it `CH` was
            # naming the wrong number — `_rank_standings` has carried the CH
            # since the label shipped and this serializer dropped it.
            'course_handicap': s.get('course_handicap'),
            'prize_rank'  : s.get('prize_rank'),
            'handicap_index': s.get('handicap_index', ''),
            'holes'       : [
                {'hole': h, **v}
                for h, v in sorted(s.get('holes', {}).items())
            ],
            'stroke_plan'  : s.get('stroke_plan', {}),
            'total_strokes': s.get('total_strokes', 0),
        }
        for s in standings
    ]


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def low_net_round_standings(round_obj) -> list:
    """
    Calculate adjusted totals for all real players in the round.

    Reads LowNetRoundConfig if present; falls back to full net (100%).

    Returns a list of dicts ordered by total (lowest first), with ties
    sharing the same rank and the prize pool split evenly among them:
        {
            'rank'        : int,
            'player_id'   : int,
            'player_name' : str,
            'net_total'   : int,
            'net_to_par'  : int | None,
            'holes_played': int,
            'foursome_id' : int,
            'payout'      : float | None,
        }
    """
    try:
        config        = round_obj.low_net_config
        handicap_mode = config.handicap_mode
        net_percent   = config.net_percent
        payouts_cfg   = {p['place']: float(p['amount']) for p in (config.payouts or [])}
        excluded_ids  = set(config.excluded_player_ids or [])
        # Subset side game: restrict scoring/ranking/payouts to these players.
        participant_ids = config.participant_player_ids or None
    except Exception:
        handicap_mode = HandicapMode.NET
        net_percent   = 100
        payouts_cfg   = {}
        excluded_ids  = set()
        participant_ids = None

    player_totals = _build_ln_player_totals(
        round_obj, handicap_mode, net_percent, participant_ids=participant_ids)

    return _rank_standings(player_totals, payouts_cfg, excluded_ids)


def field_standing(round_obj) -> dict:
    """Each golfer's place in the ROUND's field, keyed by player id.

    What the score-entry standing row reports, and the one fact that card
    cannot work out for itself: it holds one foursome, and a place is about
    everybody. A rank taken off four golfers would be a place among four
    wearing the words of a place in the field.

    **Ranked by :func:`low_net_round_standings`, which is the board the row's
    own pill opens.** A second implementation would eventually put a golfer
    2nd on the row and 3rd on the board he taps through to.

    Two departures from the board's rows, both in the direction of claiming
    less:

    * a golfer who has not teed off is **unranked** rather than sharing the
      last rank handed out — he is not on the board yet, and the row says
      `Tee off` for him anyway. Unstarted golfers sort last, so this can never
      change the rank of a golfer who HAS a score, and the two surfaces agree
      wherever the row actually speaks.
    * ``tied`` counts only golfers who have started, for the same reason.

    ``field`` is every golfer ENTERED, not the ones who have started: eight
    golfers are eight golfers from the first tee, and that is how many rows
    the board draws all day.
    """
    rows = low_net_round_standings(round_obj)

    started = [r for r in rows if r.get('holes_played')]
    at_rank: dict = {}
    for r in started:
        at_rank[r['rank']] = at_rank.get(r['rank'], 0) + 1

    field = len(rows)
    out = {}
    for r in rows:
        playing = bool(r.get('holes_played'))
        out[r['player_id']] = {
            # Which figure this row carries. One payload key must never mean
            # two shapes — the Stableford tournament sends `points` here and
            # no `net_to_par`, and a client casting blind would read one as
            # the other.
            'metric'    : 'stroke',
            'rank'      : r['rank'] if playing else None,
            'tied'      : playing and at_rank.get(r['rank'], 0) > 1,
            'field'     : field,
            'net_to_par': r['net_to_par'],
            'thru'      : r.get('holes_played') or 0,
        }
    return out


def low_net_round_summary(round_obj) -> dict:
    """
    Return serialisable summary dict:
        {
          'handicap_mode': str,          # the round's CONFIGURED mode
          'net_percent'  : int,
          'entry_fee'    : float,
          'payouts'      : [{'place': int, 'amount': float}, ...],
          'results'      : [ ... configured-mode rows ... ],   # backward-compat
          'primary_mode' : str,          # 12A: the mode `results` is ranked by
          'modes'        : {             # 12A: all three, independently ranked
              'gross':       {'net_percent': int, 'results': [...]},
              'net':         {'net_percent': int, 'results': [...]},
              'strokes_off': {'net_percent': int, 'results': [...]},
          },
        }

    The `modes` block (design 12A — docs/features/12a-scorecard-display-modes.md)
    lets the client re-rank the Stroke Play tab between Gross / Net / Strokes-off
    WITHOUT refetching. Only the configured mode carries payouts; the other two
    are display-only views. SO is relative-to-low AND scaled by net %, matching
    the app-wide SO allowance (nassau / multi_skins / points_531). `results`
    mirrors the configured mode for older clients that don't read `modes`.
    """
    try:
        config          = round_obj.low_net_config
        entry_fee       = float(config.entry_fee)
        payouts_cfg     = config.payouts or []
        hmode           = config.handicap_mode
        npct            = config.net_percent
        excluded_ids    = set(config.excluded_player_ids or [])
        participant_ids = config.participant_player_ids or None
    except Exception:
        entry_fee       = 0.0
        payouts_cfg     = []
        hmode           = HandicapMode.NET
        npct            = 100
        excluded_ids    = set()
        participant_ids = None

    payouts_map = {p['place']: float(p['amount']) for p in payouts_cfg}

    # ── Per-mode standings (12A) ──────────────────────────────────────────────
    # Each mode is built with the app's existing per-mode engine, so nothing
    # about scoring semantics changes — this only SURFACES the three views.
    # Payouts belong to the configured mode only (the round is settled in one
    # mode); the others are display-only, so they get an empty payout map.
    mode_specs = [
        ('gross',       HandicapMode.GROSS,       100),
        ('net',         HandicapMode.NET,         npct),
        ('strokes_off', HandicapMode.STROKES_OFF, npct),
    ]
    primary_key = ('gross' if hmode == HandicapMode.GROSS
                   else 'strokes_off' if hmode == HandicapMode.STROKES_OFF
                   else 'net')

    modes: dict = {}
    for key, m_mode, m_npct in mode_specs:
        totals = _build_ln_player_totals(
            round_obj, m_mode, m_npct, participant_ids=participant_ids)
        pmap   = payouts_map if key == primary_key else {}
        modes[key] = {
            'net_percent': m_npct,
            'results'    : _serialize_results(
                _rank_standings(totals, pmap, excluded_ids)),
        }

    # The holes this round actually plays (see services/hole_plan) + a
    # representative par per hole, so the client can render the FULL scorecard
    # strip — including not-yet-played holes as blanks — instead of only the
    # holes that happen to have scores. For a normal round this is 1..18.
    from services.hole_plan import holes_in_play as _holes_in_play
    in_play = sorted(_holes_in_play(round_obj))
    rep_tee = None
    for fs in round_obj.foursomes.all():
        m = fs.memberships.exclude(tee__isnull=True).first()
        if m is not None:
            rep_tee = m.tee
            break
    hole_pars: dict = {}
    hole_si: dict = {}   # 12A two-row scorecard: SI row needs every hole's index
    if rep_tee is not None:
        for h in in_play:
            try:
                hole_pars[h] = rep_tee.hole(h).get('par')
                hole_si[h]   = rep_tee.hole(h).get('stroke_index')
            except StopIteration:
                pass

    return {
        'handicap_mode': hmode,
        'net_percent'  : npct,
        'entry_fee'    : entry_fee,
        'payouts'      : payouts_cfg,
        # What the table pays out in total — the ledger's `Pool $580`. Here
        # rather than summed on the phone: a client adding a money column up
        # is a client with an opinion about money.
        'purse'        : float(sum(p.get('amount') or 0 for p in payouts_cfg)),
        'holes_in_play': in_play,
        'hole_pars'    : hole_pars,
        'hole_stroke_index': hole_si,
        # Backward-compat: `results` is the configured mode, reused from `modes`
        # so it can never drift from the selector's version of the same view.
        'results'      : modes[primary_key]['results'],
        'primary_mode' : primary_key,
        'modes'        : modes,
    }


# ---------------------------------------------------------------------------
# Score entry — one hole
# ---------------------------------------------------------------------------

def _first_name(name: str) -> str:
    return (name or '').strip().split(' ')[0] or (name or '')


def stroke_play_hole_card(foursome, hole: int) -> dict:
    """Everything the Stroke Play score-entry tray draws for ONE hole.

    `~/Downloads/handoff-stroke-play`. Built from
    :func:`low_net_round_standings` — **the board the tray's own places open
    through** — rather than from a second walk over the scores. The totals,
    the ranks, the per-hole net and the cap are the engine's; what is derived
    here is the one fact the engine has no reason to answer, which is where
    this hole left each golfer against where he stood before it.

    **A place is about everybody, so the field is the whole ROUND**, not this
    card. The packet writes it as "casual rounds: positions count within your
    own group only" — which is the same thing, because a casual round is one
    group. Where it is not (a multi-group casual round), ranking the group
    alone would put a golfer 2nd on the tray and 5th on the board his pill
    opens, which is the mistake :func:`field_standing` carries a paragraph
    about.

    Returns `{}` when the round plays no Stroke Play, so a caller can test
    the key.
    """
    round_obj = foursome.round
    if not plays_low_net_round(round_obj):
        return {}

    try:
        config  = round_obj.low_net_config
        hmode   = config.handicap_mode
        npct    = config.net_percent
    except Exception:
        hmode, npct = HandicapMode.NET, 100
    cap = cap_in_force(round_obj, hmode, npct)

    rows = {r['player_id']: r for r in low_net_round_standings(round_obj)}
    if not rows:
        return {}

    from services.hole_plan import play_order as _play_order
    order = _play_order(round_obj, foursome) or list(range(1, 19))

    members = [m for m in foursome.memberships.all() if not m.player.is_phantom]
    here_ids = [m.player_id for m in members if m.player_id in rows]
    if not here_ids:
        return {}

    # ── This hole, per golfer on this card ───────────────────────────────────
    # `strokes` comes from the scored hole when there is one and from the
    # PROSPECTIVE plan when there is not — which is the case that matters,
    # because the keypad is coded against par plus the strokes before a
    # number is typed.
    par_here = None
    players = []
    for m in members:
        r = rows.get(m.player_id)
        if r is None:
            continue
        h = (r.get('holes') or {}).get(hole)
        plan = r.get('stroke_plan') or {}
        strokes = (h or {}).get('strokes')
        if strokes is None:
            strokes = plan.get(hole, plan.get(str(hole), 0))
        par = (h or {}).get('par')
        if par is None:
            par = _rep_par(m, hole)
        if par_here is None:
            par_here = par
        gross = (h or {}).get('gross')
        # The hole dict's two adjusted figures, and they are easy to read the
        # wrong way round: `net` is the UNCAPPED adjusted score and `capped`
        # is the one the total is built from. Both are already net of the
        # strokes, so the counted figure is `capped` as it stands.
        counted = (h or {}).get('capped')
        players.append({
            'player_id'      : m.player_id,
            'name'           : m.player.name,
            'first'          : _first_name(m.player.name),
            'short'          : (m.player.short_name or '').strip() or m.player.name,
            'course_handicap': m.course_handicap,
            'par'            : par,
            'strokes'        : strokes or 0,
            'gross'          : gross,
            # The counted net — post-cap, which is what the total is built
            # from. A capped hole therefore shows a net BELOW gross minus
            # strokes, and `capped` is what explains it.
            'net'            : counted,
            'capped'         : bool(h and h.get('capped') != h.get('net')),
            # The gross ceiling this golfer is typing against, for the
            # keypad's `max N`. Null when the cap is not in force — a number
            # there would be a maximum nothing enforces.
            'cap_max'        : (par + 2 + (strokes or 0)) if cap and par is not None else None,
        })

    # ── Places, before and after ─────────────────────────────────────────────
    # Everybody who has started, with this hole's contribution removed from
    # the golfers on THIS card who have one. Nobody else moved.
    after  = {pid: r['net_to_par'] for pid, r in rows.items()
              if r.get('holes_played')}
    before = dict(after)
    for p in players:
        pid, g = p['player_id'], p['gross']
        if g is None or pid not in after:
            continue
        r = rows[pid]
        if (r.get('holes_played') or 0) <= 1:
            # His first hole: he was not on the board before it, so there is
            # no place to have moved from.
            before.pop(pid, None)
            continue
        h = r['holes'][hole]
        before[pid] = after[pid] - (h['capped'] - h['par'])

    def _place(table, pid):
        if pid not in table:
            return None, False
        v = table[pid]
        lower = sum(1 for x in table.values() if x < v)
        same  = sum(1 for x in table.values() if x == v)
        return lower + 1, same > 1

    final = bool(order) and hole == order[-1]
    standing = []
    for p in sorted(players,
                    key=lambda p: (1, 0) if rows[p['player_id']]['net_to_par'] is None
                    else (0, rows[p['player_id']]['net_to_par'])):
        pid = p['player_id']
        r = rows[pid]
        pa, tied = _place(after, pid)
        pb, _    = _place(before, pid)
        standing.append({
            'player_id' : pid,
            'name'      : p['name'],
            'short'     : p['short'],
            'place'     : pa,
            'place_text': None if pa is None else ('T' if tied else '') + str(pa),
            # Places GAINED. Null on the last hole, where the packet drops the
            # arrow — the round is over and there is nowhere left to move —
            # and null for a golfer who had no place to move from.
            'moved'     : None if (final or pa is None or pb is None) else pb - pa,
            'to_par'    : r['net_to_par'],
            'thru'      : r.get('holes_played') or 0,
            'gross'     : p['gross'],
            'net'       : p['net'],
            'capped'    : p['capped'],
            'strokes'   : p['strokes'],
            'par'       : p['par'],
        })

    # ── The cap, in words ────────────────────────────────────────────────────
    # The server writes them because the cap is a RULE: the card keeps the
    # score the golfer made and the total counts the ceiling, which is two
    # facts about one number and the thing a group argues about.
    cap_notes = []
    for p in players:
        if not p['capped'] or p['gross'] is None or p['cap_max'] is None:
            continue
        # Stated in GROSS, because that is the number the golfer typed and
        # the one he will argue about. `cap_max` is the same ceiling the
        # engine applied, read back the other way.
        cap_notes.append(
            f"{p['first']}’s {p['gross']} counts as {p['cap_max']}, net "
            f"double bogey. The card keeps the {p['gross']}.")

    # ── The leader, when he is not on this card ──────────────────────────────
    # A leader line naming a golfer three rows above is the one thing the tray
    # cannot work out; naming one who is ON the card would be a repeat.
    leader = None
    started = [r for r in rows.values() if r.get('holes_played')]
    if started:
        top = min(started, key=lambda r: r['net_to_par'])
        if top['player_id'] not in here_ids:
            leader = {
                'name'  : top['player_name'],
                'to_par': top['net_to_par'],
                'thru'  : top.get('holes_played') or 0,
            }

    return {
        'hole'         : hole,
        'par'          : par_here,
        'handicap_mode': hmode,
        'net_percent'  : npct,
        'show_net'     : hmode != HandicapMode.GROSS,
        'cap'          : cap,
        'final'        : final,
        'group'        : len(here_ids),
        'field'        : len(rows),
        'players'      : players,
        'standing'     : standing,
        'cap_notes'    : cap_notes,
        'leader'       : leader,
        'ball'         : ball_on_hole(foursome, hole),
        'rumble'       : _rumble_block(foursome, hole),
    }


def ball_on_hole(foursome, hole: int):
    """Thin re-export so this module's own readers find it.

    The ball's facts live in `services.red_ball`, which owns the rotation and
    the death — Stroke Play only draws them.
    """
    from services.red_ball import ball_on_hole as _impl
    return _impl(foursome, hole)


def _rumble_block(foursome, hole: int) -> dict | None:
    """How many of the group's balls count on this hole.

    `None` when the round does not play Irish Rumble, or when the hole falls
    in no segment — the strip says nothing rather than guessing a number the
    calculator would not use.

    `all_count` is what the design draws as "[4] all count": the count has
    reached the group's size, so nobody's ball is idle. Read off
    `counting_players`, the same figure the calculator caps with, so a
    three-ball borrowing a fourth reads the same in both places.
    """
    rnd = foursome.round
    if 'irish_rumble' not in (rnd.active_games or []):
        return None

    from services.irish_rumble import balls_on_hole, counting_players

    count = balls_on_hole(rnd, foursome, hole)
    if count is None:
        return None
    size = counting_players(foursome)
    return {'count': count, 'of': size, 'all_count': count >= size}


def _rep_par(membership, hole):
    """The par the ENGINE caps against, for a hole with no score yet.

    `_build_ln_player_totals` takes one par per foursome off the first
    membership that has a tee, so the ceiling reported to the keypad has to
    come from the same place or it would offer a maximum the total does not
    enforce.
    """
    fs = membership.foursome
    first = next((m for m in fs.memberships.all() if m.tee_id is not None), None)
    if first is None:
        return None
    try:
        return first.tee.hole(hole).get('par')
    except StopIteration:
        return None


# ---------------------------------------------------------------------------
# What a tournament round is SCORED on, when nothing in its games says so
# ---------------------------------------------------------------------------

def plays_low_net_round(round_obj) -> bool:
    """Stroke Play is this round's own game.

    Named in `active_games` — the casual path — **or** the scoring method of
    the individual-play tournament it belongs to, which names it nowhere on
    the round. One function because two callers ask it (the hole card and the
    hole tray) and a round where they disagreed would ship a tray with no
    card in it.
    """
    if 'low_net_round' in (round_obj.active_games or []):
        return True
    return unstated_scoring_game(round_obj) == 'low_net_round'


def unstated_scoring_game(round_obj) -> str | None:
    """The game this round is scored on and does not say it is playing.

    **An individual-play tournament sets its scoring method ONCE, on the
    tournament** (`stroke` or `stableford`), and the ROUND's `active_games`
    carries only its side games. So a tournament round running stroke play
    with a Multi-Group Skins pool stores `['multi_skins']` — and anything that
    asks the round what it is playing gets "a skins pool".

    The LEADERBOARD never had this problem: `_build_leaderboard` emits the
    Stroke Play block for every individual-ball round whatever `active_games`
    says. **Score entry did**, which is how a stroke round with a pool got the
    pool's standings card, the pool as its primary game, and no stroke-play
    entry at all — no keypad, no hole tray, no ribbon. Reported from a
    tournament called "Stroke With Skins" (Paul, 4 Nov 2026).

    This is deliberately NOT the board's question and must not be fused with
    it. The board asks "does this round get a Stroke Play tab", which is true
    of nearly every round including every casual one. This asks "what is
    MISSING from `active_games`", and the answer for a casual round is
    nothing: one that plays stroke play puts `low_net_round` in the list, and
    that path works.

    None when: no tournament, a cup or Foursome Play event (both keep their
    own per-round scoring), a team-ball round where no golfer has a ball of
    his own, or the game is already named.
    """
    t = getattr(round_obj, 'tournament', None)
    if t is None or not t.is_individual_play:
        return None
    if getattr(t, 'is_team_play', False):
        return None
    games = set(round_obj.active_games or [])
    # Team-ball formats have no per-golfer ball, so there is no individual
    # score to be scored ON — the same exclusion the board's Stroke Play tab
    # makes, for the same reason.
    if games & {'triple_cup', 'scramble', 'team_play'}:
        return None
    slug = 'stableford' if t.scoring_method == 'stableford' else 'low_net_round'
    return None if slug in games else slug
