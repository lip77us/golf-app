"""
services/multi_skins.py
-----------------------
Multi-Group Skins calculator — a skins pool that can cross **foursomes
and independent rounds** (docs/multi-skins-cross-round.md).

The pool is anchored on a host round's `MultiSkinsGame`.  Its participant
roster is an explicit M2M of Players; each participant's gross scores are
sourced from whichever source round they play in — the **host round** plus
any **linked rounds** (`MultiSkinsLinkedRound`).  A participant is matched
to a per-round `FoursomeMembership` by exact player id (same account) or by
**normalized phone** (cross-account Halved member), so one shared golfer's
scores flow into the pool from wherever they are entered.

Scoring rules
~~~~~~~~~~~~~
* Each hole is worth 1 skin.  The player with the BEST score-to-compare
  on a hole wins it outright.
* Tied best score → skin dies (no carryover, no junk).
* Only holes where EVERY participant has a score on file are counted.

Handicap modes
~~~~~~~~~~~~~~
* Net (with net_percent) and Gross delegate to scoring.handicap.build_score_index
  per-foursome and union the results across every source round.
* Strokes-Off-Low is pool-wide: the lowest playing handicap across all
  participants plays to 0; strokes are allocated by each player's own tee
  stroke index (each source round may use a different tee).

Settlement
~~~~~~~~~~
Pool = participants × bet_unit.
payout_i = (skins_i / total_skins_won) × pool.
Players with zero skins receive nothing; the pool is always fully
distributed when at least one skin is won.

Workflow
~~~~~~~~
1. setup_multi_skins(round, participant_ids, ...) — create or replace
   the host round's MultiSkinsGame.  Safe to call repeatedly.
2. calculate_multi_skins(round) / recalc_pools_for_round(round) — recompute
   MultiSkinsHoleResult rows.  Called from api.views after every score
   submission in any source (host or linked) round.
3. multi_skins_summary(round) — JSON shape consumed by the mobile UI.
"""
from __future__ import annotations

from collections import defaultdict

from django.db import transaction

from accounts.phone import normalize
from core.models import HandicapMode, MatchStatus, Player
from games.models import (
    MultiSkinsGame, MultiSkinsHoleResult, MultiSkinsLinkedRound,
)
from scoring.handicap import build_score_index
from scoring.models import HoleScore


# ---------------------------------------------------------------------------
# Identity helpers
# ---------------------------------------------------------------------------

def _identity_phone(player) -> str | None:
    """Normalized E.164 phone for a Player — the cross-account match key.

    Prefers the free-text Player.phone; falls back to the linked verified
    User.phone (already normalized) when the Player row carries no phone.
    """
    if getattr(player, 'phone', None):
        return normalize(player.phone)
    u = getattr(player, 'user', None)
    return getattr(u, 'phone', None) if u is not None else None


def _pool_source_rounds(game: MultiSkinsGame) -> list:
    """Host round + every linked round (deduped, host first)."""
    rounds = [game.round]
    seen = {game.round_id}
    for lr in game.linked_rounds.select_related('round').all():
        if lr.round_id not in seen:
            rounds.append(lr.round)
            seen.add(lr.round_id)
    return rounds


def _resolve_participant_memberships(game: MultiSkinsGame) -> dict:
    """
    Map {canonical_participant_id: FoursomeMembership} across the host +
    linked rounds.  Canonical id = the roster Player's id; the membership's
    own player_id may differ (a phone-matched copy in another account).

    A participant can be a member of more than one source round (e.g. a
    login-less roster golfer parked in the host round who actually PLAYS in a
    linked Sixes round).  Bind them to the source round where they have the
    most gross scores — that's where they're really playing — so the pool
    reads the scores that were actually entered.  When no source round has
    scores yet, fall back to source order (host round first).
    """
    from django.db.models import Count
    from tournament.models import FoursomeMembership

    part_ids = set(game.participants.values_list('id', flat=True))
    part_by_phone: dict = {}
    for p in game.participants.all():
        ph = _identity_phone(p)
        if ph:
            part_by_phone.setdefault(ph, p.id)

    source_rounds = _pool_source_rounds(game)
    order = {r.id: i for i, r in enumerate(source_rounds)}
    source_ids = list(order.keys())

    # Scored-hole counts per (round, player) — the tie-breaker that binds a
    # participant to the round they actually played.
    score_counts: dict = {}
    for r in (
        HoleScore.objects
        .filter(foursome__round_id__in=source_ids)
        .exclude(gross_score=None)
        .values('foursome__round_id', 'player_id')
        .annotate(n=Count('id'))
    ):
        score_counts[(r['foursome__round_id'], r['player_id'])] = r['n']

    memberships = (
        FoursomeMembership.objects
        .filter(foursome__round_id__in=source_ids, player__is_phantom=False)
        .select_related('player', 'player__user', 'foursome', 'tee')
    )

    candidates: dict = defaultdict(list)   # canon_id -> [membership]
    for m in memberships:
        canon = None
        if m.player_id in part_ids:
            canon = m.player_id
        else:
            ph = _identity_phone(m.player)
            if ph and ph in part_by_phone:
                canon = part_by_phone[ph]
        if canon is not None:
            candidates[canon].append(m)

    out: dict = {}
    for canon, ms in candidates.items():
        ms.sort(key=lambda m: (
            -score_counts.get((m.foursome.round_id, m.player_id), 0),
            order.get(m.foursome.round_id, 99),
        ))
        out[canon] = ms[0]
    return out


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

@transaction.atomic
def setup_multi_skins(
    round_obj,
    participant_ids: list[int],
    handicap_mode:   str  = HandicapMode.NET,
    net_percent:     int  = 100,
    bet_unit:        float | None = None,
) -> MultiSkinsGame:
    """
    Create (or replace) the Multi-Skins pool anchored on this host round.

    participant_ids may reference EITHER a player with a FoursomeMembership
    in this round (single-round pool, login-less golfers allowed) OR an
    on-app (Halved) member selected from connected golfers (federated pool
    — they play in a linked round).  Anything else is filtered out.

    Re-running this on an existing pool UPDATES it in place — it does NOT
    delete+recreate, which would cascade-delete every MultiSkinsLinkedRound
    (unlinking joined rounds) and drop the hole results.  So editing the
    roster mid-round is safe.
    """
    net_percent = max(0, min(200, int(net_percent)))

    game, created = MultiSkinsGame.objects.get_or_create(
        round    = round_obj,
        defaults = {
            'handicap_mode': handicap_mode,
            'net_percent'  : net_percent,
            'bet_unit'     : bet_unit if bet_unit is not None else round_obj.bet_unit,
            'status'       : MatchStatus.PENDING,
        },
    )
    if not created:
        game.handicap_mode = handicap_mode
        game.net_percent   = net_percent
        if bet_unit is not None:
            game.bet_unit = bet_unit
        game.save(update_fields=['handicap_mode', 'net_percent', 'bet_unit'])

    pids = valid_participant_ids(round_obj, participant_ids)
    game.participants.set(pids)
    reconcile_pool_seating(game)
    return game


def _default_tee_for(course, player):
    """Pick a player's default CURRENT tee at a course: lowest sort_priority
    among tees matching their sex (or unisex), else any current tee."""
    from django.db.models import Q
    from core.models import Tee
    qs = Tee.objects.filter(course=course, superseded_by__isnull=True)
    sexed = (qs.filter(Q(sex=player.sex) | Q(sex__isnull=True) | Q(sex=''))
               .order_by('sort_priority', 'tee_name').first())
    return sexed or qs.order_by('sort_priority', 'tee_name').first()


def _participant_source_rounds(game: MultiSkinsGame) -> dict:
    """{canonical_participant_id: set(round_id)} — every source round (host or
    linked) each participant is a member of, matched by id or phone."""
    from tournament.models import FoursomeMembership

    part_ids = set(game.participants.values_list('id', flat=True))
    part_by_phone: dict = {}
    for p in game.participants.all():
        ph = _identity_phone(p)
        if ph:
            part_by_phone.setdefault(ph, p.id)

    source_ids = [r.id for r in _pool_source_rounds(game)]
    out: dict = defaultdict(set)
    for m in (
        FoursomeMembership.objects
        .filter(foursome__round_id__in=source_ids, player__is_phantom=False)
        .select_related('player', 'player__user', 'foursome')
    ):
        canon = (m.player_id if m.player_id in part_ids
                 else part_by_phone.get(_identity_phone(m.player)))
        if canon is not None:
            out[canon].add(m.foursome.round_id)
    return out


@transaction.atomic
def reconcile_pool_seating(game: MultiSkinsGame, handicap_allowance: float = 1.0):
    """
    Keep each participant seated in exactly one scorable place (Halved-only
    pool; docs/multi-skins-cross-round.md, use-case 4):

    * A participant who plays in a LINKED round is scored there — remove any
      scoreless host-round SOLO group we auto-made for them.
    * A participant not in ANY source round gets their OWN new group of one in
      the host round, so they self-score and the round shows in their login.
    * A scoreless solo group whose player was dropped from the roster is pruned.

    Only ever deletes a group of ONE real player with NO scores, so a real
    playing group (the TD's foursome, a shared group) and history are safe.
    """
    from django.db.models import Max
    from scoring.handicap import par_adjusted_playing_handicap
    from scoring.models import HoleScore
    from tournament.models import Foursome, FoursomeMembership

    round_obj = game.round
    host_id   = round_obj.id
    part_ids  = set(game.participants.values_list('id', flat=True))
    src       = _participant_source_rounds(game)

    # 1) Prune scoreless SOLO host groups that are no longer needed.
    for fs in list(round_obj.foursomes.prefetch_related('memberships__player')):
        reals = [m for m in fs.memberships.all() if not m.player.is_phantom]
        if len(reals) != 1:
            continue
        pid            = reals[0].player_id
        plays_in_link  = any(r != host_id for r in src.get(pid, set()))
        dropped        = pid not in part_ids
        if (plays_in_link or dropped) and \
                not HoleScore.objects.filter(foursome=fs).exists():
            fs.delete()

    # 2) Seat participants who are in NO source round in a fresh solo group.
    src        = _participant_source_rounds(game)   # refresh after prune
    to_add     = [pid for pid in part_ids if not src.get(pid)]
    if not to_add:
        return
    players    = {p.id: p for p in Player.objects.filter(id__in=to_add)}
    next_group = (round_obj.foursomes.aggregate(m=Max('group_number'))['m'] or 0)
    for pid in to_add:
        player = players.get(pid)
        if player is None:
            continue
        tee = _default_tee_for(round_obj.course, player)
        if tee is None:
            continue   # course has no tees — can't seat them
        next_group += 1
        fs = Foursome.objects.create(round=round_obj, group_number=next_group)
        course_hcp  = player.course_handicap(tee)
        playing_hcp = par_adjusted_playing_handicap(
            course_hcp, tee.par, tee.par, handicap_allowance)
        FoursomeMembership.objects.create(
            foursome         = fs,
            player           = player,
            tee              = tee,
            course_handicap  = course_hcp,
            playing_handicap = playing_hcp,
        )


def valid_participant_ids(round_obj, participant_ids: list[int]) -> list[int]:
    """Filter participant_ids to those eligible for this pool: host-round
    members (login-less OK) OR on-app Halved members (phone matches a User)."""
    from accounts.models import User

    host_ids = set(_round_player_ids(round_obj))
    keep: list[int] = []
    to_check = [pid for pid in participant_ids if pid not in host_ids]
    players = {p.id: p for p in Player.objects.filter(id__in=to_check)
                                              .select_related('user')}
    # Phones of the non-host candidates → one query for on-app membership.
    cand_phones = {pid: _identity_phone(players[pid])
                   for pid in to_check if pid in players}
    on_app = set(
        User.objects
        .filter(phone__in=[ph for ph in cand_phones.values() if ph])
        .values_list('phone', flat=True)
    )
    for pid in participant_ids:
        if pid in host_ids:
            keep.append(pid)
        elif cand_phones.get(pid) in on_app and cand_phones.get(pid):
            keep.append(pid)
    # Preserve caller order, dedup.
    seen: set = set()
    return [p for p in keep if not (p in seen or seen.add(p))]


def _round_player_ids(round_obj) -> list[int]:
    """All real-player IDs across every foursome in this round."""
    from tournament.models import FoursomeMembership
    return list(
        FoursomeMembership.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .values_list('player_id', flat=True)
    )


def not_on_app_ids(participant_ids: list[int]) -> list[int]:
    """Participant ids that are NOT Halved members — no `User` carries their
    phone.  A cross-round pool matches players across rounds/accounts by phone
    identity, so a login-less golfer can't reliably participate; the pool roster
    is Halved-only (docs/multi-skins-cross-round.md).  Used to reject a bad
    roster at the API boundary."""
    from accounts.models import User

    players = {p.id: p for p in Player.objects.filter(id__in=participant_ids)
                                              .select_related('user')}
    phones  = {pid: _identity_phone(players[pid]) for pid in players}
    on_app  = set(
        User.objects
        .filter(phone__in=[ph for ph in phones.values() if ph])
        .values_list('phone', flat=True)
    )
    bad: list[int] = []
    for pid in participant_ids:
        ph = phones.get(pid)
        if not ph or ph not in on_app:
            bad.append(pid)
    return bad


def pool_overlap(game: MultiSkinsGame, round_obj) -> list[int]:
    """
    Canonical participant ids that are present in `round_obj` (matched by
    exact player id OR normalized phone).  This is the subset of the pool
    roster that `round_obj` would contribute if linked — used to gate a join
    (≥ 1 required) and to preview what a link brings in.
    """
    from tournament.models import FoursomeMembership

    part_ids = set(game.participants.values_list('id', flat=True))
    part_by_phone: dict = {}
    for p in game.participants.all():
        ph = _identity_phone(p)
        if ph:
            part_by_phone.setdefault(ph, p.id)

    found: set = set()
    for m in (
        FoursomeMembership.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .select_related('player', 'player__user')
    ):
        if m.player_id in part_ids:
            found.add(m.player_id)
        else:
            ph = _identity_phone(m.player)
            if ph and ph in part_by_phone:
                found.add(part_by_phone[ph])
    return sorted(found)


# ---------------------------------------------------------------------------
# Score index across every source round (keyed by canonical participant id)
# ---------------------------------------------------------------------------

def _build_pool_score_index(game: MultiSkinsGame) -> dict:
    """
    Return {canonical_participant_id: {hole_number: adjusted_score}} unioned
    across the host + every linked round.

    Net/Gross: delegate to per-foursome `build_score_index` and remap the
    source player ids to canonical participant ids.
    Strokes-Off-Low: anchored on the lowest participant handicap, applied
    using each player's own tee.
    """
    member_by_canon = _resolve_participant_memberships(game)
    if not member_by_canon:
        return {}

    if game.handicap_mode == HandicapMode.STROKES_OFF:
        return _build_pool_so_index(game, member_by_canon)

    by_fs: dict = defaultdict(list)   # foursome -> [(canon_id, membership)]
    for canon, m in member_by_canon.items():
        by_fs[m.foursome].append((canon, m))

    merged: dict = {}
    for fs, items in by_fs.items():
        per_fs = build_score_index(
            fs,
            handicap_mode = game.handicap_mode,
            net_percent   = game.net_percent,
        )
        for canon, m in items:
            holes = per_fs.get(m.player_id)
            if holes:
                merged[canon] = dict(holes)
    return merged


def _build_pool_so_index(game: MultiSkinsGame, member_by_canon: dict) -> dict:
    """
    Strokes-Off-Low across the whole pool.  Low handicap is the lowest
    playing_handicap among PARTICIPANTS.  Each player gets one stroke on
    every hole whose stroke_index ≤ their SO, using the stroke_index from
    their OWN membership's tee.
    """
    net_percent = game.net_percent
    items = list(member_by_canon.items())   # (canon, membership)
    phcps = [m.playing_handicap for _, m in items
             if m.playing_handicap is not None]
    low = min(phcps) if phcps else 0

    canon_by_src = {m.player_id: canon for canon, m in items}
    mem_by_src   = {m.player_id: m     for _,     m in items}
    source_round_ids = {r.id for r in _pool_source_rounds(game)}

    rows = (
        HoleScore.objects
        .filter(player_id__in=list(mem_by_src.keys()))
        .exclude(gross_score=None)
        .values('player_id', 'hole_number', 'gross_score', 'foursome__round_id')
    )

    out: dict = {}
    for r in rows:
        if r['foursome__round_id'] not in source_round_ids:
            continue
        pid    = r['player_id']
        m      = mem_by_src.get(pid)
        canon  = canon_by_src.get(pid)
        if m is None or canon is None:
            continue
        gross = r['gross_score']
        if m.tee_id is None:
            out.setdefault(canon, {})[r['hole_number']] = gross
            continue
        so = round(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
        if so <= 0:
            out.setdefault(canon, {})[r['hole_number']] = gross
            continue
        full_laps = so // 18
        remainder = so %  18
        si        = m.tee.hole(r['hole_number']).get('stroke_index', 18)
        strokes   = full_laps + (1 if si <= remainder else 0)
        out.setdefault(canon, {})[r['hole_number']] = gross - strokes
    return out


# ---------------------------------------------------------------------------
# Calculator
# ---------------------------------------------------------------------------

@transaction.atomic
def _calculate_game(game: MultiSkinsGame) -> list:
    """Recompute MultiSkinsHoleResult rows for a pool.  Returns saved rows."""
    participant_ids = list(game.participants.values_list('id', flat=True))
    MultiSkinsHoleResult.objects.filter(game=game).delete()

    if len(participant_ids) < 2:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    score_index = _build_pool_score_index(game)   # keyed by canonical id

    rows         = []
    fully_scored = 0

    for hole_num in range(1, 19):
        scores: dict = {}
        complete = True
        for cid in participant_ids:
            s = score_index.get(cid, {}).get(hole_num)
            if s is None:
                complete = False
                break
            scores[cid] = s
        if not complete:
            continue

        fully_scored += 1
        min_score = min(scores.values())
        leaders   = [cid for cid, s in scores.items() if s == min_score]

        winner_id = leaders[0] if len(leaders) == 1 else None
        rows.append(MultiSkinsHoleResult(
            game        = game,
            hole_number = hole_num,
            winner_id   = winner_id,
        ))

    if rows:
        MultiSkinsHoleResult.objects.bulk_create(rows)

    if fully_scored == 0:
        game.status = MatchStatus.PENDING
    elif fully_scored >= 18:
        game.status = MatchStatus.COMPLETE
    else:
        game.status = MatchStatus.IN_PROGRESS
    game.save(update_fields=['status'])

    return rows


def calculate_multi_skins(round_obj) -> list:
    """Recompute the pool HOSTED on this round (if any)."""
    try:
        game = round_obj.multi_skins_game
    except MultiSkinsGame.DoesNotExist:
        return []
    return _calculate_game(game)


def recalc_pools_for_round(round_obj) -> None:
    """
    Recompute every Multi-Skins pool this round participates in — the pool it
    HOSTS (if any) plus every pool it is LINKED into.  Called after any score
    submission in the round.
    """
    games: dict = {}
    try:
        g = round_obj.multi_skins_game
        games[g.id] = g
    except MultiSkinsGame.DoesNotExist:
        pass
    for lr in (MultiSkinsLinkedRound.objects
               .filter(round=round_obj).select_related('game')):
        games[lr.game_id] = lr.game
    for g in games.values():
        _calculate_game(g)


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

def multi_skins_summary(round_obj) -> dict:
    """Summary for the pool hosted on round_obj (default shape if none)."""
    try:
        game = round_obj.multi_skins_game
    except MultiSkinsGame.DoesNotExist:
        bet_unit = float(round_obj.bet_unit)
        return {
            'status'   : MatchStatus.PENDING,
            'handicap' : {'mode': HandicapMode.NET, 'net_percent': 100},
            'players'  : [],
            'holes'    : [],
            'money'    : {'bet_unit': bet_unit, 'pool': 0.0, 'total_skins': 0},
            'linked_rounds': [],
        }
    return _summary_for_game(game)


def _summary_for_game(game: MultiSkinsGame) -> dict:
    """
    JSON-serialisable summary for the mobile client.

    Shape (keys added for cross-round: each player's `round_id`, top-level
    `linked_rounds`):
        {
            'status', 'handicap': {mode, net_percent},
            'players': [{player_id, name, short_name, foursome_id,
                         group_number, round_id, skins_won, payout,
                         thru, phcp_in_play}],   # sorted by skins_won
            'holes'  : [{hole, par, stroke_index, winner_id, winner_short,
                         is_dead, scores:[{player_id, gross, strokes}]}],
            'money'  : {bet_unit, pool, total_skins},
            'linked_rounds': [round_id, ...],
        }
    """
    bet_unit = float(game.bet_unit)

    canon_players   = {p.id: p for p in game.participants.all()}
    participant_ids = list(canon_players.keys())
    member_by_canon = _resolve_participant_memberships(game)

    # Skins won per canonical participant.
    skins_won: dict = {cid: 0 for cid in participant_ids}
    hole_results = list(
        MultiSkinsHoleResult.objects
        .filter(game=game)
        .select_related('winner')
        .order_by('hole_number')
    )
    for hr in hole_results:
        if hr.winner_id and hr.winner_id in skins_won:
            skins_won[hr.winner_id] += 1

    # Adjusted (net-per-hole) + raw gross indexes, keyed by canonical id.
    score_index = _build_pool_score_index(game)

    inv_src = {m.player_id: cid for cid, m in member_by_canon.items()}
    source_round_ids = {r.id for r in _pool_source_rounds(game)}
    gross_index:   dict = {}
    thru_by_canon: dict = {cid: 0 for cid in participant_ids}
    if inv_src:
        for r in (
            HoleScore.objects
            .filter(player_id__in=list(inv_src.keys()))
            .exclude(gross_score=None)
            .values('player_id', 'hole_number', 'gross_score',
                    'foursome__round_id')
        ):
            if r['foursome__round_id'] not in source_round_ids:
                continue
            cid = inv_src[r['player_id']]
            gross_index.setdefault(cid, {})[r['hole_number']] = r['gross_score']
            if r['hole_number'] > thru_by_canon[cid]:
                thru_by_canon[cid] = r['hole_number']

    grand_total = sum(skins_won.values())
    pool        = len(participant_ids) * bet_unit

    mode = game.handicap_mode
    npct = game.net_percent or 100
    phcps = [
        (member_by_canon[cid].playing_handicap or 0)
        for cid in participant_ids
        if cid in member_by_canon
        and member_by_canon[cid].playing_handicap is not None
    ]
    low_phcp = min(phcps) if phcps else 0

    def _phcp_in_play(phcp: int) -> int:
        if mode == HandicapMode.GROSS:
            return 0
        if mode == HandicapMode.STROKES_OFF:
            return round(max(0, phcp - low_phcp) * npct / 100)
        return round(phcp * npct / 100)   # NET

    players_out: list = []
    for cid in participant_ids:
        p      = canon_players[cid]
        m      = member_by_canon.get(cid)
        won    = skins_won[cid]
        payout = (won / grand_total * pool) if grand_total > 0 else 0.0
        players_out.append({
            'player_id'    : cid,
            'name'         : p.name,
            'short_name'   : p.short_name,
            'foursome_id'  : m.foursome_id if m else None,
            'group_number' : m.foursome.group_number if m else None,
            'round_id'     : m.foursome.round_id if m else None,
            'skins_won'    : won,
            'payout'       : round(payout, 2),
            'thru'         : thru_by_canon[cid],
            'phcp_in_play' : _phcp_in_play(m.playing_handicap or 0) if m else 0,
        })
    players_out.sort(key=lambda x: (-x['skins_won'], x['name']))

    # Par + stroke index from any participant's tee — every source round is
    # on the SAME course (enforced at join), so the layout is shared.
    sample_tee = None
    for cid in participant_ids:
        m = member_by_canon.get(cid)
        if m is not None and m.tee_id is not None:
            sample_tee = m.tee
            break

    par_by_hole: dict = {}
    si_by_hole:  dict = {}
    if sample_tee is not None:
        for h in range(1, 19):
            hd = sample_tee.hole(h)
            par_by_hole[h] = hd.get('par')
            si_by_hole[h]  = hd.get('stroke_index')

    winner_by_hole = {hr.hole_number: hr for hr in hole_results}

    holes_out: list = []
    for hole_num in range(1, 19):
        hr = winner_by_hole.get(hole_num)
        scored_cids = [
            cid for cid in participant_ids
            if hole_num in gross_index.get(cid, {})
        ]
        if hr is None and not scored_cids:
            continue
        scores = []
        for cid in scored_cids:
            gross   = gross_index[cid][hole_num]
            net     = score_index.get(cid, {}).get(hole_num)
            strokes = (gross - net) if net is not None else 0
            scores.append({
                'player_id': cid,
                'gross'    : gross,
                'strokes'  : max(0, strokes),
            })
        holes_out.append({
            'hole'        : hole_num,
            'par'         : par_by_hole.get(hole_num),
            'stroke_index': si_by_hole.get(hole_num),
            'winner_id'   : hr.winner_id if hr else None,
            'winner_short': hr.winner.short_name if hr and hr.winner else None,
            'is_dead'     : hr is not None and hr.winner_id is None,
            'scores'      : scores,
        })

    return {
        'status'   : game.status,
        'handicap' : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        'players'  : players_out,
        'holes'    : holes_out,
        'money'    : {
            'bet_unit'   : bet_unit,
            'pool'       : pool,
            'total_skins': grand_total,
        },
        'linked_rounds': [lr.round_id for lr in game.linked_rounds.all()],
    }
