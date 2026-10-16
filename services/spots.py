"""
services/spots.py
-----------------
Spots — a capture add-on settled on its OWN pot (never folded into the main
game).  The group agrees at setup WHICH spots it is playing, and that
agreement is the point of the feature: the argument on the 18th is never "how
many sandies did he have" but "we weren't playing pollies".

**One of each type per golfer per hole.**  Two bunkers on a par 5 is one
sandy, so every type is on or off and never a count.  All types pay the same
stake; `EAGLE` pays 2 and a carried greenie pays its worth, which are counts
rather than prices, and `SNAKE` is the one that pays the other way.

Three kinds of type, and the difference is where each is captured:

* **greenie** — the app PLACES it.  It has the pars, so it knows the par 3s,
  and closest-to-the-pin has one winner or nobody: a pick, not a tally.  That
  is also what makes the carry possible.
* **birdie / eagle** — read off the entered SCORES, so they never appear on
  the hole card at all.
* **everything else** — a tick on the spots sheet.

Nothing is stored that can be derived.  The greenie's WORTH is walked from
the par 3s in play order at read time, and birdies come off the scorecard, so
correcting an earlier hole moves every later one — the same reason Survivor's
legs are derived rather than written down.  A stored worth is how the card and
the money come to disagree after an edit.

Settlement is unchanged:
  - per_point + 'all' = "pay around": each spot pays the achiever 1 x bet_unit
    from every OTHER active player on that hole — zero-sum within the hole's
    roster.
  - per_point + 'first' / 'average' settle round-level totals via the wager
    engine.
  - pool: each active player antes bet_unit; the pot splits by share of spots.

Mid-round withdrawal: a player only pays/collects on holes they're active for
(not withdrawn before that hole), mirroring Skins.
"""

from django.db import transaction

from core.models import MatchStatus, RoundStatus, SpotType
from games.models import (SpotsGame, SpotsGreenieResult,
                          SpotsPlayerHoleResult)

#: How each type is captured, what it is worth, and whether it starts ticked.
#:
#: `worth` is the type's price and belongs here rather than on a result row,
#: so an eagle is 2 and a snake is -1 wherever either appears. `entry` is the
#: only thing the UI has to branch on:
#:   'sheet'   — a tick in the spots sheet on any hole
#:   'pick'    — the greenie, par 3s only, one winner or nobody
#:   'derived' — read from the scores; never shown on the hole card
#:
#: Descriptions are deliberately NOT here. They are UI copy and live in the
#: client's catalogue beside the game blurbs; what the server owns is the
#: slug, the label (`SpotType`) and the arithmetic.
SPOT_META = {
    SpotType.GREENIE: {'entry': 'pick',    'worth':  1, 'default': True},
    SpotType.SANDY:   {'entry': 'sheet',   'worth':  1, 'default': True},
    SpotType.POLEY:   {'entry': 'sheet',   'worth':  1, 'default': False},
    SpotType.BIRDIE:  {'entry': 'derived', 'worth':  1, 'default': True},
    SpotType.EAGLE:   {'entry': 'derived', 'worth':  2, 'default': True},
    SpotType.CHIPPY:  {'entry': 'sheet',   'worth':  1, 'default': True},
    SpotType.BARKY:   {'entry': 'sheet',   'worth':  1, 'default': False},
    SpotType.HOGAN:   {'entry': 'sheet',   'worth':  1, 'default': False},
    SpotType.SNAKE:   {'entry': 'sheet',   'worth': -1, 'default': False},
    SpotType.OTHER:   {'entry': 'sheet',   'worth':  1, 'default': False},
}

#: The types the hole's bottom sheet offers. Greenie has its own pick and
#: birdie/eagle are never asked for, so neither belongs in a tick list.
SHEET_TYPES = tuple(t for t, m in SPOT_META.items() if m['entry'] == 'sheet')

DEFAULT_TYPES = [t for t, m in SPOT_META.items() if m['default']]


def default_types() -> list:
    """The ticks a new game starts with, as plain strings."""
    return [str(t) for t in DEFAULT_TYPES]


def legacy_default_types() -> list:
    """The defaults MINUS the two that are read off the scores.

    For a caller that did not mention `types` at all — which is the shipped
    2.11.2 app, since the field did not exist when it was built.

    **The rule is that nothing pays for a spot the client cannot show.**
    Birdie and Eagle are derived, so on a phone with no notion of them they
    would move money for a reason nobody on that screen can see: no row
    explaining it, no way to turn it off, and a total that does not match the
    spots anybody tallied. A control that fails loudly (that app's stepper
    gets a 400) is recoverable; a number that is quietly wrong is not.

    Greenie stays. It cannot pay without a pick, and that app has no pick, so
    it is inert — and it starts working the moment the phone updates, rather
    than needing the game reconfigured.
    """
    return [str(t) for t in DEFAULT_TYPES
            if SPOT_META[t]['entry'] != 'derived']


def normalise_types(types) -> list:
    """Keep the known slugs, in `SPOT_META` order, de-duplicated.

    Order is the enum's rather than the caller's so the leaderboard's In play
    pills and the sheet's rows read the same way for every group.
    """
    wanted = {str(t) for t in (types or [])}
    return [str(t) for t in SPOT_META if str(t) in wanted]


def setup_spots(foursome, bet_unit=None, payout_style='per_point',
                per_point_mode='all', loss_cap=None, types=None,
                greenie_carry=True, birdie_basis='gross',
                net_percent=100) -> SpotsGame:
    """Create (or replace) the Spots game for a foursome.

    Replacing cascades to every tick and greenie pick, so it starts fresh.

    `types` is which spots the group is playing — the agreement the feature
    exists for. Omitted means the defaults (`default_types`), because a game
    added from the picker and never configured still has to be playable; an
    EMPTY list is a different thing and is refused, since a Spots game with
    nothing in play can only pay nobody.

    Defaults preserve the historical "pay around" behavior (per_point +
    'all'). Legacy callers passing payout_style='pay_around' are mapped.
    """
    from decimal import Decimal
    SpotsGame.objects.filter(foursome=foursome).delete()
    if bet_unit is None:
        bet_unit = foursome.round.bet_unit
    if payout_style == 'pay_around':          # legacy value → 2-axis
        payout_style, per_point_mode = 'per_point', 'all'
    if payout_style not in ('pool', 'per_point'):
        payout_style = 'per_point'
    if per_point_mode not in ('average', 'all', 'first'):
        per_point_mode = 'all'
    if types is None:
        picked = default_types()
    else:
        picked = normalise_types(types)
        if not picked:
            raise ValueError(
                'Pick at least one spot to play for — a Spots game with '
                'nothing in play can only pay nobody.')
    if birdie_basis not in ('gross', 'net_so'):
        birdie_basis = 'gross'
    return SpotsGame.objects.create(
        foursome       = foursome,
        bet_unit       = bet_unit,
        payout_style   = payout_style,
        per_point_mode = per_point_mode,
        loss_cap       = (Decimal(str(loss_cap)) if loss_cap not in (None, '') else None),
        types          = picked,
        greenie_carry  = bool(greenie_carry),
        birdie_basis   = birdie_basis,
        net_percent    = max(50, min(130, int(net_percent or 100))),
        status         = MatchStatus.PENDING,
    )


def _game_or_default(foursome) -> SpotsGame:
    """The foursome's game, created with defaults if it was never configured.

    Spots can be switched on in the picker without anybody opening its setup
    screen, and the first tap on a hole has to work — the hub's Edit Spots
    tunes it afterwards.
    """
    try:
        return foursome.spots_game
    except SpotsGame.DoesNotExist:
        return setup_spots(foursome)


@transaction.atomic
def tally_spots(foursome, hole_number: int, entries: list) -> SpotsGame:
    """Set which types each named golfer ticked on one hole.

    entries: ``[{'player_id': int, 'types': ['sandy', 'chippy']}, ...]``

    The list is the WHOLE truth for that golfer on that hole — what is absent
    is unticked, which is what makes the sheet's Done button a plain save
    rather than a diff. Golfers not named are left untouched.

    **Only sheet types are accepted.** A greenie is a pick
    (`pick_greenie`) and birdies come off the scorecard, so a tick of either
    would be a second, contradictory record of the same fact.
    """
    game = _game_or_default(foursome)
    real_ids = {
        m.player_id for m in foursome.memberships.filter(player__is_phantom=False)
    }
    in_play = set(game.types or [])
    allowed = {str(t) for t in SHEET_TYPES} & in_play
    for e in entries:
        pid = e.get('player_id')
        if pid not in real_ids:
            continue
        picked = {str(t) for t in (e.get('types') or [])} & allowed
        qs = SpotsPlayerHoleResult.objects.filter(
            game=game, player_id=pid, hole_number=hole_number)
        # Drop what is no longer ticked, among the SHEET types only: a
        # derived or picked row never lands here, and a type the group has
        # since stopped playing keeps its row so that turning it back on does
        # not lose a hole already entered.
        qs.filter(spot_type__in=allowed).exclude(spot_type__in=picked).delete()
        for t in picked:
            SpotsPlayerHoleResult.objects.get_or_create(
                game=game, player_id=pid, hole_number=hole_number,
                spot_type=t)

    if game.status == MatchStatus.PENDING:
        game.status = MatchStatus.IN_PROGRESS
        game.save(update_fields=['status'])
    return game


@transaction.atomic
def pick_greenie(foursome, hole_number: int, player_id=None) -> SpotsGame:
    """Record who took the greenie on a par 3 — or that nobody did.

    `player_id=None` is **Nobody**, which is a real answer and not a missing
    one: it is what rolls the carry to the next par 3. Clearing the pick
    altogether is `clear_greenie`, and the two are different states — an
    undecided hole has no row.
    """
    game = _game_or_default(foursome)
    if player_id is not None:
        real_ids = {
            m.player_id for m in
            foursome.memberships.filter(player__is_phantom=False)
        }
        if player_id not in real_ids:
            raise ValueError('That golfer is not playing in this group.')
    SpotsGreenieResult.objects.update_or_create(
        game=game, hole_number=hole_number,
        defaults={'player_id': player_id})
    if game.status == MatchStatus.PENDING:
        game.status = MatchStatus.IN_PROGRESS
        game.save(update_fields=['status'])
    return game


@transaction.atomic
def clear_greenie(foursome, hole_number: int) -> SpotsGame:
    """Un-answer a par 3 — back to undecided, which is not the same as Nobody."""
    game = _game_or_default(foursome)
    SpotsGreenieResult.objects.filter(
        game=game, hole_number=hole_number).delete()
    return game


def _active_roster_by_hole(real_members, foursome) -> dict:
    """{hole: [player_id, ...]} of players active on each hole.

    The rule lives in `services/withdrawal.py`, read along the group's PLAY
    ORDER. This compared hole NUMBERS until 30 Sep 2026 — the same integer only
    on a round starting at the 1st, and inverted off a shotgun.
    """
    from services.withdrawal import active_pids, play_plan
    order, positions = play_plan(foursome)
    return {h: active_pids(real_members, h, positions) for h in order}


def _in_play_block(types) -> list:
    """``[{'type': slug, 'label': 'Eagle or better', 'worth': 2}, ...]``.

    **The server names the types.** The client holds their one-line
    descriptions, the way it holds game blurbs, but a leaderboard pill or a
    sheet row must never be able to render `eagle_or_better` because a client
    missed a slug — the same reason every board reads `GameType`'s label.
    """
    wanted = []
    for t in types:
        try:
            st = SpotType(t)
        except ValueError:
            continue
        if st not in wanted:
            wanted.append(st)
    # **Catalogue order, always**, whatever order the caller holds them in.
    # The per-hole list comes off a query ordered by slug and the In play
    # pills come off the game's own list, so without this one hole reads
    # "Chippy, Sandy" while the sheet above it reads "Sandy, Chippy". Found by
    # a test, and it is the kind of thing nobody reports and everybody
    # notices.
    return [{'type': str(st), 'label': st.label,
             'worth': SPOT_META[st]['worth']}
            for st in SPOT_META if st in wanted]


def catalogue_block() -> list:
    """Every type the server knows, in catalogue order, with its label, its
    worth, how it is captured, and whether it starts ticked.

    **Sent on every read so the setup checklist can be built from it.** The
    first version of that screen merged `in_play` with `sheet_types` and
    filled the gaps from a hardcoded label map, because a configured game's
    `in_play` holds only the group's own picks — which made the client a
    second place every type is named. Adding Hogan is what proved the cost:
    it would have needed adding twice, and forgetting the client half shows
    a golfer the slug.
    """
    return [{'type': str(t), 'label': t.label, 'worth': m['worth'],
             'entry': m['entry'], 'default': m['default']}
            for t, m in SPOT_META.items()]


def _par_si_by_hole(real_members) -> dict:
    """{hole: (par, stroke_index)} off the first tee that has the hole.

    Par decides which holes are par 3s and what a birdie is; SI allocates the
    strokes-off figure. Taken from a tee rather than from `HoleScore`, which
    stores no stroke index.
    """
    out = {}
    for m in real_members:
        if not m.tee_id:
            continue
        for h in (m.tee.holes or []):
            n = h.get('number')
            if n and n not in out:
                out[n] = (int(h.get('par') or 0),
                          int(h.get('stroke_index') or 0))
    return out


def greenie_plan(foursome, game) -> dict:
    """Walk the par 3s in PLAY ORDER and work out what each one is worth.

    Returns ``{'holes': [...], 'next': {...} | None, 'carry': bool,
    'awards': {hole: (player_id, worth)}}``.

    **A greenie takes two things: on the green in one, AND a par.** (Paul,
    15 Oct 2026.) The app can only see the second. Being closest from the tee
    is a human judgement, so the PICK records who it was and the score decides
    whether he keeps it — on in one and then three putts is a bogey and pays
    nobody.

    So there are four outcomes per par 3, not two:

    * **a winner who parred** — he collects the worth, and the next par 3
      resets to 1.
    * **a winner who did not** (``missed``) — nobody collects, and it carries
      exactly as Nobody would. He was closest; he just did not keep it.
    * **a winner whose score is not in yet** (``pending_score``) — the award
      is provisional and the carry does NOT move, because the answer is not
      known. It resolves itself when the score lands.
    * **Nobody**, or no pick at all.

    Par is GROSS. The greenie is a shot — on the green from the tee and up
    and down — so a net par off a stroke is not the thing being paid for.
    `birdie_basis` is scoped to birdies and eagles on purpose.

    The three carry rules are unchanged:

    * **Only an explicit Nobody (or a missed par) carries.** A par 3 with no
      pick has not happened yet, so it adds nothing to the next one. Picks can
      legitimately arrive out of order, and treating a blank as unclaimed
      would invent a carry out of a hole nobody has played.
    * **A win resets it.** The next par 3 is worth 1 again.
    * **An unclaimed LAST par 3 voids the carry.** It falls out of the walk
      rather than being special-cased: the pending worth has no later par 3 to
      land on, so nobody is paid it.

    Par 3s are ordered by play position, not hole number — off a shotgun the
    4th can be played after the 12th, and the carry follows the group.
    """
    from scoring.models import HoleScore
    from services.withdrawal import play_plan
    order, positions = play_plan(foursome)
    real_members = list(foursome.memberships.select_related('player', 'tee')
                        .filter(player__is_phantom=False))
    par_si = _par_si_by_hole(real_members)
    par3s = [h for h in order if par_si.get(h, (0, 0))[0] == 3]

    picks = {g.hole_number: g for g in game.greenies.all()}
    carry = bool(game.greenie_carry)
    gross = {
        (r.player_id, r.hole_number): r.gross_score
        for r in HoleScore.objects.filter(
            foursome=foursome, player__is_phantom=False,
            hole_number__in=par3s).exclude(gross_score=None)
    }

    pending = 0
    holes, awards, nxt = [], {}, None
    for h in par3s:
        worth = 1 + pending
        par = par_si.get(h, (3, 0))[0] or 3
        g = picks.get(h)
        row = {'hole': h, 'worth': worth, 'carried_from': None,
               'winner_id': None, 'decided': False,
               'missed': False, 'pending_score': False}
        if pending:
            # Which hole the carry came off, for the "Carried from the 4th"
            # chip. The most recent par 3 before this one that resolved.
            prev = [x['hole'] for x in holes if x['decided']]
            row['carried_from'] = prev[-1] if prev else None
        if g is None:
            if nxt is None:
                nxt = row
            holes.append(row)
            continue
        if g.player_id:
            row['winner_id'] = g.player_id
            score = gross.get((g.player_id, h))
            if score is None:
                # Picked, not yet scored. Provisional: the carry must not move
                # on a hole whose answer nobody knows.
                row['pending_score'] = True
                if nxt is None:
                    nxt = row
                holes.append(row)
                continue
            row['decided'] = True
            if int(score) <= par:
                awards[h] = (g.player_id, worth)
                pending = 0
            else:
                # On in one and could not par it. Closest, and keeps nothing.
                row['missed'] = True
                pending = worth if carry else 0
        else:
            row['decided'] = True
            pending = worth if carry else 0
        holes.append(row)

    return {'holes': holes, 'next': nxt, 'carry': carry, 'awards': awards}


def _so_strokes_by_hole(real_members, game, par_si) -> dict:
    """{player_id: {hole: strokes}} for the strokes-off birdie basis.

    Strokes off the LOW golfer in the group: each one's playing handicap at
    the game's own allowance, minus the lowest, allocated by stroke index. The
    low man gets none.

    **Not full course handicap**, which is the whole point — a net birdie
    against your own handicap is most of a par, and the design says so.
    """
    from scoring.handicap import _strokes_on_hole, effective_hcp_for
    hcps = {m.player_id: effective_hcp_for(m, game.net_percent)
            for m in real_members}
    if not hcps:
        return {}
    low = min(hcps.values())
    out = {}
    for pid, h in hcps.items():
        off = max(0, h - low)
        out[pid] = {hole: _strokes_on_hole(off, si)
                    for hole, (_par, si) in par_si.items() if si}
    return out


def derived_spots(foursome, game, par_si=None) -> dict:
    """{player_id: {hole: [(type, worth), ...]}} read off the SCORES.

    Birdies and eagles, and nothing else. They never appear on the hole card,
    so this is the only place they exist.

    **An eagle is 2, not 3** — it does not stack with the birdie. And when
    eagles are NOT in play but birdies are, an eagle still scores the birdie:
    it is a birdie or better, and a group paying birdies has not agreed that
    the best score on the hole is worth less than the second best. The design
    leaves that case open; this is the reading.
    """
    in_play = set(game.types or [])
    birdie, eagle = str(SpotType.BIRDIE), str(SpotType.EAGLE)
    if not ({birdie, eagle} & in_play):
        return {}

    from scoring.models import HoleScore
    real_members = list(foursome.memberships.select_related('player', 'tee')
                        .filter(player__is_phantom=False))
    if par_si is None:
        par_si = _par_si_by_hole(real_members)
    so = (_so_strokes_by_hole(real_members, game, par_si)
          if game.birdie_basis == 'net_so' else {})

    out = {}
    rows = HoleScore.objects.filter(
        foursome=foursome, player__is_phantom=False).exclude(gross_score=None)
    for r in rows:
        par = par_si.get(r.hole_number, (0, 0))[0]
        if not par:
            continue
        score = int(r.gross_score)
        if game.birdie_basis == 'net_so':
            score -= so.get(r.player_id, {}).get(r.hole_number, 0)
        to_par = score - par
        if to_par <= -2 and eagle in in_play:
            got = (eagle, SPOT_META[SpotType.EAGLE]['worth'])
        elif to_par <= -1 and birdie in in_play:
            got = (birdie, SPOT_META[SpotType.BIRDIE]['worth'])
        else:
            continue
        out.setdefault(r.player_id, {}).setdefault(r.hole_number, []).append(got)
    return out


def spots_summary(foursome) -> dict:
    """JSON-serialisable summary (shape mirrors skins_summary for the UI)."""
    bet_unit_default = float(foursome.round.bet_unit)
    try:
        game = foursome.spots_game
    except SpotsGame.DoesNotExist:
        # Spots was added to the round but not yet configured. Surface the
        # roster and the DEFAULT types, so the Spots button and the greenie
        # card draw what the group will actually get — the first tap
        # auto-creates the game with exactly these (see `_game_or_default`).
        # Reporting an empty `in_play` here would draw a sheet with no rows.
        real_members = list(
            foursome.memberships.select_related('player')
            .filter(player__is_phantom=False)
        )
        players = sorted(
            ({'player_id': m.player_id,
              'name'      : m.player.name,
              'short_name': m.player.short_name or m.player.name,
              'spots'     : 0,
              'payout'    : 0.0,
              'net'       : 0.0}
             for m in real_members),
            key=lambda p: p['name'])
        return {
            'status'        : MatchStatus.PENDING,
            'payout_style'  : 'per_point',
            'players'       : players,
            'holes'         : [],
            'catalogue'     : catalogue_block(),
            'in_play'       : _in_play_block(default_types()),
            'sheet_types'   : _in_play_block(
                                [t for t in default_types()
                                 if t in {str(x) for x in SHEET_TYPES}]),
            'greenie'       : {'carry': True, 'holes': [], 'next': None},
            'birdie_basis'  : 'gross',
            'money'         : {'bet_unit': bet_unit_default, 'total_spots': 0},
        }

    real_members = list(
        foursome.memberships.select_related('player')
        .filter(player__is_phantom=False)
    )
    bet_unit = float(game.bet_unit)
    roster   = _active_roster_by_hole(real_members, foursome)

    in_play = set(game.types or [])
    par_si  = _par_si_by_hole(real_members)

    # ---- the three sources, reduced to one shape ----------------------------
    # `earned[pid][hole]` is a list of (type, worth). Ticks, the greenie pick
    # and the scorecard all land here, so the settlement below never has to
    # know which of the three a spot came from — and a type the group has
    # STOPPED playing drops out in one place.
    earned: dict = {}

    def _add(pid, hole, spot_type, worth):
        earned.setdefault(pid, {}).setdefault(hole, []).append(
            (str(spot_type), worth))

    rows = list(SpotsPlayerHoleResult.objects
                .filter(game=game, spot_type__in=in_play)
                .select_related('player'))
    for r in rows:
        meta = SPOT_META.get(SpotType(r.spot_type))
        if meta:
            _add(r.player_id, r.hole_number, r.spot_type, meta['worth'])

    greenie = greenie_plan(foursome, game)
    if str(SpotType.GREENIE) in in_play:
        for hole, (pid, worth) in greenie['awards'].items():
            _add(pid, hole, SpotType.GREENIE, worth)

    for pid, holes_map in derived_spots(foursome, game, par_si).items():
        for hole, got in holes_map.items():
            for spot_type, worth in got:
                _add(pid, hole, spot_type, worth)

    totals  = {m.player_id: 0 for m in real_members}
    by_hole: dict = {}
    for pid, holes_map in earned.items():
        for hole, got in holes_map.items():
            worth = sum(w for _t, w in got)
            totals[pid] = totals.get(pid, 0) + worth
            by_hole.setdefault(hole, {})[pid] = {
                'worth': worth, 'types': [t for t, _w in got]}

    # ---- settlement ---------------------------------------------------------
    # 2-axis (maps to services.wager): pool / per_point{all|first|average}.
    # 'all' keeps the historical per-hole, withdrawal-aware "pay around"; the
    # other per-point modes settle round-level total spots via the wager engine.
    net = {m.player_id: 0.0 for m in real_members}
    _per_point = game.payout_style == 'per_point'
    if _per_point and game.per_point_mode in ('first', 'average'):
        from decimal import Decimal
        from services.wager import (settle as _wager_settle, WagerConfig,
                                    PER_POINT, VS_AVERAGE, PAY_WINNER)
        cfg = WagerConfig(
            funding    = PER_POINT,
            settlement = PAY_WINNER if game.per_point_mode == 'first' else VS_AVERAGE,
            rate       = Decimal(str(bet_unit)),
            cap        = (Decimal(str(game.loss_cap))
                          if game.loss_cap is not None else None),
        )
        net = {pid: float(v) for pid, v in _wager_settle(dict(totals), cfg).items()}
    elif game.payout_style == 'pool':
        # Everyone antes one bet_unit (the pot = each player's max loss). The
        # pot is then handed to the "winners":
        #   - if anyone is positive: split among positive players proportional
        #     to their positive spots (negatives/zeros get nothing);
        #   - else: the least-negative player(s) take it, split on a tie.
        ante = bet_unit
        pot  = ante * len(real_members)
        positives = {pid: c for pid, c in totals.items() if c > 0}
        shares = {}
        if positives:
            spos = sum(positives.values())
            shares = {pid: pot * (c / spos) for pid, c in positives.items()}
        elif totals:
            top = max(totals.values())
            winners = [pid for pid, c in totals.items() if c == top]
            shares = {pid: pot / len(winners) for pid in winners}
        for m in real_members:
            net[m.player_id] = round(shares.get(m.player_id, 0.0) - ante, 2)
    else:  # pay_around
        for h, per_player in by_hole.items():
            active = roster.get(h, [])
            if len(active) < 2:
                continue
            spots_on_hole = {pid: 0 for pid in active}
            for pid, got in per_player.items():
                if pid in spots_on_hole:
                    spots_on_hole[pid] += got['worth']
            total_h = sum(spots_on_hole.values())
            n = len(active)
            for pid in active:
                net[pid] += bet_unit * (spots_on_hole[pid] * n - total_h)
        net = {pid: round(v, 2) for pid, v in net.items()}

    short = {m.player_id: (m.player.short_name or m.player.name)
             for m in real_members}
    players = sorted(
        ({'player_id': m.player_id,
          'name'      : m.player.name,
          'short_name': short[m.player_id],
          'spots'     : totals[m.player_id],
          'payout'    : net[m.player_id],
          # Signed, zero-sum net for the Settlement view (== payout here).
          'net'       : net[m.player_id]}
         for m in real_members),
        key=lambda p: p['spots'], reverse=True)

    # Each hole carries the TYPES as well as the count, which is the whole
    # argument for option D over a bare stepper: the receipt can say "2 Sandy,
    # Poley" rather than "3 spots".
    holes = [
        {'hole': h,
         'spots': [{'player_id': pid,
                    'short_name': short.get(pid, ''),
                    'count': by_hole[h][pid]['worth'],
                    'types': _in_play_block(by_hole[h][pid]['types'])}
                   for pid in sorted(by_hole[h])]}
        for h in sorted(by_hole)
    ]

    # The greenie's state for the board and the hole card: what the next par 3
    # is worth, and where a carry came from. `worth` is derived, so an edit to
    # an earlier par 3 moves every later one.
    greenie_block = {
        'carry' : greenie['carry'],
        # Par is gross and the card has to say so, because "on in one" is the
        # half the app cannot check and the par is the half it can.
        'needs_par': True,
        'holes' : [
            dict(h, winner_short=short.get(h['winner_id'], None))
            for h in greenie['holes']
        ],
        'next'  : greenie['next'],
    }

    round_done = foursome.round.status == RoundStatus.COMPLETE
    anything = bool(rows or greenie['awards']
                    or any(h['decided'] for h in greenie['holes']))
    status = (MatchStatus.COMPLETE if round_done
              else (MatchStatus.IN_PROGRESS if anything else game.status))

    sheet = [t for t in (game.types or [])
             if t in {str(x) for x in SHEET_TYPES}]
    return {
        'status'        : status,
        'payout_style'  : game.payout_style,
        'per_point_mode': game.per_point_mode,
        'loss_cap'      : (float(game.loss_cap)
                           if game.loss_cap is not None else None),
        'catalogue'     : catalogue_block(),
        'in_play'       : _in_play_block(game.types or []),
        'sheet_types'   : _in_play_block(sheet),
        'greenie'       : greenie_block,
        'birdie_basis'  : game.birdie_basis,
        'net_percent'   : game.net_percent,
        'players'       : players,
        'holes'         : holes,
        'money'         : {'bet_unit': bet_unit,
                           'total_spots': sum(totals.values())},
    }
