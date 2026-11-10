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
from scoring.handicap import build_score_index, _strokes_on_hole
from scoring.models import HoleScore
from core.handicap_math import round_half_up
from services import skin_rules


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


def parked_foursome_ids(round_obj) -> set:
    """Host-round foursomes that are PLACEHOLDERS, not groups still out.

    Reported 9 Nov 2026 from a round whose board said **Final** directly
    under a banner saying **"1 still out of 2 — Group 1 (thru 0)"**. Both
    were reading real data. Paul: *"group 1 completed our round as a linked
    round. The primary was sixes."*

    A pool anchored on a host round can take in whole OTHER rounds. Those
    golfers are usually also seated in the host round — parked there, so
    they are on the roster — and they score in their own round instead. The
    pool handles that: `_resolve_participant_memberships` binds each
    participant to the source round where they actually posted. Nothing
    else did, so `_field_progress` and `RoundCompleteView` kept waiting on a
    seat that was never going to be filled, and the round could not be
    finished by anybody short of the TD force.

    Deliberately narrow — a foursome is parked only when ALL of:

    * this round hosts a pool that has at least one LINKED round (no linked
      round, no parking, and every ordinary round is untouched);
    * every real member is a pool participant the resolver bound to a
      DIFFERENT round — one member who is not in the pool, or who is bound
      here, means somebody is genuinely expected to post;
    * **nothing has been scored in this foursome.** A seat with scores is
      being played in, whatever the pool thinks.

    Returns foursome ids. Empty for every round that does not host a
    cross-round pool, which is almost all of them.
    """
    game = getattr(round_obj, 'multi_skins_game', None)
    if game is None:
        return set()
    if not game.linked_rounds.exists():
        return set()

    bound = _resolve_participant_memberships(game)
    elsewhere = {canon for canon, m in bound.items()
                 if m.foursome.round_id != round_obj.id}
    if not elsewhere:
        return set()

    scored = set(
        HoleScore.objects
        .filter(foursome__round_id=round_obj.id)
        .exclude(gross_score=None)
        .values_list('foursome_id', flat=True)
        .distinct()
    )

    out = set()
    for fs in round_obj.foursomes.all().prefetch_related('memberships__player'):
        if fs.id in scored:
            continue
        real = [m for m in fs.memberships.all()
                if not getattr(m.player, 'is_phantom', False)]
        if real and all(m.player_id in elsewhere for m in real):
            out.add(fs.id)
    return out


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
        # `foursome__round` is not decoration: `build_score_index` reads the
        # round's net-double-bogey flag off every foursome it is handed, so
        # without it a 15-group round paid a query per group just for that.
        .select_related('player', 'player__user', 'foursome',
                        'foursome__round', 'tee')
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
    skin_minimum:    str  = skin_rules.MIN_NONE,
    birdie_steal:    bool = False,
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

    skin_minimum = skin_rules.normalise_minimum(skin_minimum)
    birdie_steal = bool(birdie_steal)

    game, created = MultiSkinsGame.objects.get_or_create(
        round    = round_obj,
        defaults = {
            'handicap_mode': handicap_mode,
            'net_percent'  : net_percent,
            'bet_unit'     : bet_unit if bet_unit is not None else round_obj.bet_unit,
            'status'       : MatchStatus.PENDING,
            'skin_minimum' : skin_minimum,
            'birdie_steal' : birdie_steal,
        },
    )
    if not created:
        game.handicap_mode = handicap_mode
        game.net_percent   = net_percent
        game.skin_minimum  = skin_minimum
        game.birdie_steal  = birdie_steal
        if bet_unit is not None:
            game.bet_unit = bet_unit
        game.save(update_fields=['handicap_mode', 'net_percent', 'bet_unit',
                                 'skin_minimum', 'birdie_steal'])

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

    **It does nothing at all on a TOURNAMENT round**, and that is the one rule
    in here that is about safety rather than tidiness. A tournament round's
    foursomes are the TD's DRAW: the groups are his pairings and his tee
    times, so a scoreless group of one is a real pairing rather than a seat
    this function made, and pruning it would quietly delete a golfer from the
    field. Setting up a sparse skins pool in a 60-player event would have
    taken out every scoreless solo group in it.

    Seating is just as wrong the other way — a new `Foursome` appended to a
    tournament round is a group nobody drew, with no tee time. It cannot
    arise either, because `valid_participant_ids` keeps a tournament pool's
    roster to golfers already in the round, so every participant is already
    seated and there is nothing to reconcile. The guard is here as well
    because the two rules are enforced in different functions and only one of
    them is reached by every caller.
    """
    from django.db.models import Max
    from scoring.handicap import par_adjusted_playing_handicap
    from scoring.models import HoleScore
    from tournament.models import Foursome, FoursomeMembership

    round_obj = game.round
    if round_obj.tournament_id:
        return
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
    members (login-less OK) OR on-app Halved members (phone matches a User).

    **On a TOURNAMENT round the roster is the round's own golfers and nobody
    else.** The on-app clause exists for a CASUAL pool, where the other
    participants play in their own rounds and are linked in by pasting the
    host's watch link — it is how a federated pool finds their scores at all.
    A tournament round already holds the whole field, so an outside golfer
    there would ante into a pool he has no card in: he can never win a skin
    and can never stop paying. He would also have to be SEATED to be scored,
    and seating him means appending a group to the TD's draw.
    """
    from accounts.models import User

    host_ids = set(_round_player_ids(round_obj))
    if round_obj.tournament_id:
        seen_t: set = set()
        return [p for p in participant_ids
                if p in host_ids and not (p in seen_t or seen_t.add(p))]
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


def not_on_app_ids(participant_ids: list[int], round_obj=None) -> list[int]:
    """Participant ids that cannot be in this pool.

    A cross-round pool matches players across rounds and accounts by PHONE
    identity, so a golfer with no `User` behind his number cannot be found in
    somebody else's round — which is why the roster is otherwise
    Halved-members-only (docs/multi-skins-cross-round.md).

    **A golfer already seated in the host round is exempt**, and `round_obj`
    is what lets this know. He is in THIS round, on a card somebody is
    keeping, and his scores are read from his own membership — no phone match
    is needed to find him, and `_resolve_participant_memberships` matches on
    exact player id before it ever looks at a phone.

    Without that exemption this contradicted `valid_participant_ids`, which
    has always admitted host-round members "(login-less OK)": one filtered
    silently and kept the guest, the other refused the whole roster at the
    boundary. The boundary won, so a guest playing in the TD's own foursome
    could not be in the pool at all.

    The further rule — that a guest needs somebody ON HIS CARD who can enter
    his score — is the client's (`utils/skins_cards.canJoinPool`), because it
    is about the seating and is fixable on the screen that owns it.
    """
    from accounts.models import User

    seated = set(_round_player_ids(round_obj)) if round_obj is not None else set()
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
        if pid in seated:
            continue
        ph = phones.get(pid)
        if not ph or ph not in on_app:
            bad.append(pid)
    return bad


def not_in_round_ids(round_obj, participant_ids: list[int]) -> list[int]:
    """Participant ids that are not playing in this round.

    Only asked of a TOURNAMENT round, where `valid_participant_ids` keeps the
    roster to the round's own golfers. It filters SILENTLY, which is right for
    a stale id and wrong for a TD who deliberately ticked somebody: he would
    save, see the name gone and have nothing to read. So the boundary refuses
    and names them, and the service stays the backstop.
    """
    seated = set(_round_player_ids(round_obj))
    seen: set = set()
    return [p for p in participant_ids
            if p not in seated and not (p in seen or seen.add(p))]


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

def _build_pool_score_index(game: MultiSkinsGame,
                            member_by_canon: dict | None = None) -> dict:
    """
    Return {canonical_participant_id: {hole_number: adjusted_score}} unioned
    across the host + every linked round.

    Net/Gross: delegate to per-foursome `build_score_index` and remap the
    source player ids to canonical participant ids.
    Strokes-Off-Low: anchored on the lowest participant handicap, applied
    using each player's own tee.
    """
    if member_by_canon is None:
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
        so = round_half_up(max(0, (m.playing_handicap or 0) - low) * net_percent / 100)
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

def _pool_gross_and_pars(game, members: dict | None = None) -> tuple:
    """({cid: {hole: gross}}, {cid: {hole: par}}) keyed by CANONICAL id.

    The validation rules need gross and par, which the pool score index does
    not carry.  Both are read through `_resolve_participant_memberships`, so a
    golfer is measured against the card he actually played on -- his own tee in
    his own round, which in a cross-round pool is not the host's.

    `members` is the already-resolved map when the caller has one. Resolving
    it costs three round-wide queries, and one pass used to do it three times.

    **The gross rows are ONE query**, keyed on the exact (foursome, player)
    pairs. It was one query per participant, which is invisible in a
    four-handed casual pool and twenty queries on every posted score in a
    sixty-player tournament.
    """
    if members is None:
        members = _resolve_participant_memberships(game)
    gross: dict = {}
    pars: dict = {}
    want: dict = {}          # (foursome_id, player_id) -> canonical id
    for cid, m in members.items():
        if m is None:
            continue
        pars[cid] = {
            h['number']: h.get('par')
            for h in ((m.tee.holes or []) if m.tee_id else [])
            if h.get('number')
        }
        gross[cid] = {}
        want[(m.foursome_id, m.player_id)] = cid
    if not want:
        return gross, pars
    for r in (
        HoleScore.objects
        .filter(foursome_id__in={fs for fs, _ in want},
                player_id__in={pl for _, pl in want})
        .exclude(gross_score=None)
        .values('foursome_id', 'player_id', 'hole_number', 'gross_score')
    ):
        # The pair filter is a product, so a golfer who also appears in
        # another source foursome would match there too — `want` is what
        # keeps each canonical id reading only the card he is bound to.
        cid = want.get((r['foursome_id'], r['player_id']))
        if cid is not None:
            gross[cid][r['hole_number']] = r['gross_score']
    return gross, pars


@transaction.atomic
def _calculate_game(game: MultiSkinsGame) -> list:
    """Recompute MultiSkinsHoleResult rows for a pool.  Returns saved rows."""
    participant_ids = list(game.participants.values_list('id', flat=True))
    MultiSkinsHoleResult.objects.filter(game=game).delete()

    if len(participant_ids) < 2:
        game.status = MatchStatus.PENDING
        game.save(update_fields=['status'])
        return []

    # Resolved ONCE and handed down. It is three round-wide queries, and
    # this pass asked for it twice before.
    members     = _resolve_participant_memberships(game)
    score_index = _build_pool_score_index(game, members)   # canonical ids
    gross_index, par_index = _pool_gross_and_pars(game, members)

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
        # Same decider as round skins (services/skin_rules).  An empty answer
        # means nobody validated, which here lands on the pool's own rule for
        # an unwon hole: the skin dies (no carryover in a cross-round pool).
        leaders = skin_rules.decide(
            scores,
            {cid: gross_index.get(cid, {}).get(hole_num)
             for cid in participant_ids},
            {cid: par_index.get(cid, {}).get(hole_num)
             for cid in participant_ids},
            minimum      = game.skin_minimum,
            birdie_steal = game.birdie_steal,
        )

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
            'skin_minimum': skin_rules.MIN_NONE,
            'birdie_steal': False,
            'skin_rules'  : '',
            'skin_rules_note': '',
            'skin_rule_copy' : skin_rules.copy_block(),
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
    score_index = _build_pool_score_index(game, member_by_canon)

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
            return round_half_up(max(0, phcp - low_phcp) * npct / 100)
        return round_half_up(phcp * npct / 100)   # NET

    # Whole dollars, and they still add up — the same helper round skins
    # settles through, for the reason its docstring gives: `round(share, 2)`
    # pays $133.33 three times out of $400 and the board promises $400.
    # Done HERE rather than on the board, because the tournament settlement
    # reads these same figures and a pot that does not balance blocks Settle.
    from services.skins import _whole_dollar_shares
    if grand_total > 0:
        payout_by_cid = _whole_dollar_shares(
            {cid: skins_won[cid] / grand_total * pool
             for cid in participant_ids},
            pool,
        )
    else:
        # **Nothing awarded yet, so nothing is paid — and the helper must not
        # be asked.** It distributes a target across shares that already sum
        # to it; handed all-zeros and a $60 pool it would floor everything to
        # nothing, find $60 unassigned and hand a dollar to each golfer in
        # turn. Round skins avoids this from the other end (it does not
        # charge a segment's ante until a skin is won, which is the same
        # rule): a pot that collects and distributes nothing is not a pot.
        payout_by_cid = {cid: 0.0 for cid in participant_ids}

    # **A stable place in the POOL's roster, which is what a golfer's
    # colour follows.** `players_out` is sorted by skins below, so an index
    # into it moves the moment somebody wins one — and the board must not
    # change a golfer's colour then, or the hole tiles stop matching the
    # ledger swatches. Same fix as `services.skins`.
    players_out: list = []
    for _i, cid in enumerate(participant_ids):
        p      = canon_players[cid]
        m      = member_by_canon.get(cid)
        won    = skins_won[cid]
        payout = payout_by_cid.get(cid, 0.0)
        players_out.append({
            'roster_index' : _i,
            'player_id'    : cid,
            'name'         : p.name,
            'short_name'   : p.short_name,
            'foursome_id'  : m.foursome_id if m else None,
            'group_number' : m.foursome.group_number if m else None,
            'round_id'     : m.foursome.round_id if m else None,
            'skins_won'    : won,
            'payout'       : round(payout, 2),
            # **Signed and zero-sum**, for the settlement and the receipt.
            # Every participant antes `bet_unit` and the shares sum to the
            # pot, so `payout − ante` balances by construction — EXCEPT
            # before anybody has won one, where charging the ante for a pot
            # that has paid nothing would leave a table of losses with no
            # winner. Same rule the tournament pool's pot uses, and the
            # same rule round skins uses per segment.
            'net'          : round(payout - (bet_unit if grand_total else 0.0),
                                   2),
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

    # **Every hole, and the dots on the ones nobody has reached.** A stroke dot
    # says where a stroke FALLS, so it is only useful before the hole is
    # played. This skipped unscored holes entirely and derived strokes as
    # `gross - net`, which needs a gross — so the card showed the holes already
    # in and nothing ahead of them. Same defect fixed in fourball (63610a2);
    # Skins has always done it the right way round and says so in its own
    # comment.
    #
    # `_phcp_in_play` is the pool's in-play handicap — gross, net% or
    # strokes-off against the POOL's low — so these are the strokes skins
    # actually issues, just computed before the hole rather than after.
    # Allocated on each participant's OWN tee, like the scoring does: the pool
    # is one course but not necessarily one set of tees.
    holes_out: list = []
    for hole_num in range(1, 19):
        hr = winner_by_hole.get(hole_num)
        scores = []
        for cid in participant_ids:
            m = member_by_canon.get(cid)
            si = 18
            if m is not None and m.tee_id is not None:
                si = m.tee.hole(hole_num).get('stroke_index', 18)
            elif si_by_hole.get(hole_num):
                si = si_by_hole[hole_num]
            phcp = _phcp_in_play(
                (m.playing_handicap or 0) if m is not None else 0)
            scores.append({
                'player_id': cid,
                'gross'    : gross_index.get(cid, {}).get(hole_num),
                'strokes'  : _strokes_on_hole(phcp, si),
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

    linked = [lr.round_id for lr in game.linked_rounds.all()]

    return {
        'status'   : game.status,
        'handicap' : {
            'mode'       : game.handicap_mode,
            'net_percent': game.net_percent,
        },
        # Same three keys round skins emits, same meanings — one vocabulary
        # for one rule, so a client draws the pool's rules with the code it
        # already has.
        'skin_minimum': game.skin_minimum,
        'birdie_steal': game.birdie_steal,
        'skin_rules'  : skin_rules.rules_line(game.skin_minimum,
                                              game.birdie_steal),
        # The CONSEQUENCE, and the catalogue a setup screen draws options
        # from. Both here for the reason the chips already were: this rule
        # was spelled in five places on the client and they had drifted.
        'skin_rules_note': skin_rules.rules_note(game.skin_minimum,
                                                 game.birdie_steal),
        'skin_rule_copy' : skin_rules.copy_block(),
        'players'  : players_out,
        'holes'    : holes_out,
        'money'    : {
            'bet_unit'   : bet_unit,
            'pool'       : pool,
            'total_skins': grand_total,
        },
        'linked_rounds': linked,
        # **Is the money entirely inside this round?**
        #
        # A pool that spans rounds — or accounts — cannot be settled by a
        # round-scoped receipt: half its golfers are not on it, and netting
        # the slice that is would hand somebody a figure that is not what
        # he is owed. One round, every participant seated in it, is the
        # degenerate case this module was built around, and it is the
        # common one: a side game across the groups of a single round.
        'round_local'  : (not linked and bool(players_out)
                          and all(p['round_id'] == game.round_id
                                  for p in players_out)),
    }
