"""
services/spot_types.py
----------------------
**The named per-hole extras, shared by Spots and by Skins junk.**

Two features, one vocabulary. A sandy is a sandy whether the group is playing
it for its own pot (Spots) or for a share of the skins pot (junk), and the
machinery underneath is identical: which types are in play, the greenie pick
and its carry, birdies read off the scorecard, and the arithmetic that turns
the three into a per-hole worth.

Extracted when junk followed Spots (`handoff-skins-junk`, 15 Oct 2026). It was
written inside `services/spots.py` first and could have been copied; this file
is here because of what copying it would have cost. The standing example is in
`live_activity_registry.gross_to_par`: three copies of one traversal, each
guessing at the key a summary uses, one of them guessing wrong and failing
INVISIBLY. A greenie carry duplicated into two engines would drift exactly
that way, and the half that drifted would be somebody's money.

**Nothing here reads a game row.** Every function takes what it needs —
the types, the carry flag, the allowance — so one module serves `SpotsGame`
and `SkinsGame` without either of them having to be shaped like the other.
`SkinsGame` already had a `net_percent` meaning something else entirely (who
wins the SKIN), which is exactly the collision duck-typing would have walked
into.
"""

from core.models import SpotType

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


def active_roster_by_hole(real_members, foursome) -> dict:
    """{hole: [player_id, ...]} of players active on each hole.

    The rule lives in `services/withdrawal.py`, read along the group's PLAY
    ORDER. This compared hole NUMBERS until 30 Sep 2026 — the same integer only
    on a round starting at the 1st, and inverted off a shotgun.
    """
    from services.withdrawal import active_pids, play_plan
    order, positions = play_plan(foursome)
    return {h: active_pids(real_members, h, positions) for h in order}


def in_play_block(types) -> list:
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


def types_block(pairs) -> list:
    """``[(type, worth), ...]`` → labelled rows carrying THAT worth.

    Distinct from `in_play_block`, which labels a catalogue where the worth
    is the type's price. Here the worth is what the spot was actually worth
    ON THAT HOLE, and the two differ for exactly one thing: a carried greenie
    is worth what it carried. Re-deriving it from `SPOT_META` lost the carry
    — the board drew `Greenie on 7` for a greenie worth two, and the hole's
    own line totalled it as 1 while the money said 2.
    """
    out = []
    for t, worth in pairs:
        try:
            st = SpotType(t)
        except ValueError:
            continue
        out.append({'type': str(st), 'label': st.label, 'worth': worth})
    # Catalogue order, as everywhere else.
    order = {str(t): i for i, t in enumerate(SPOT_META)}
    return sorted(out, key=lambda r: order.get(r['type'], 99))


def par_si_by_hole(real_members) -> dict:
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


def greenie_plan(foursome, *, greenies, carry) -> dict:
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

    * **A PLAYED par 3 with no winner carries**, whether the group tapped
      Nobody or simply did not tap at all (`unclaimed`). The first version
      required the explicit tap, on the reasoning that a blank must not invent
      a carry out of a hole nobody has reached — right about an unplayed hole
      and wrong about a played one. On the course nobody taps to record an
      absence: they miss the green, say nothing and walk on, which is exactly
      what happened the first time this was tested. So the gate is whether
      every active golfer has a score, not whether somebody pressed a button.
    * A par 3 **nobody has finished** still adds nothing. That is the case the
      old rule was protecting, and it keeps it: picks legitimately arrive out
      of order, and a hole in front of the group is not an unclaimed one.
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
    par_si = par_si_by_hole(real_members)
    par3s = [h for h in order if par_si.get(h, (0, 0))[0] == 3]

    picks = {g.hole_number: g for g in greenies}
    carry = bool(carry)
    roster = active_roster_by_hole(real_members, foursome)
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
               'missed': False, 'pending_score': False, 'unclaimed': False}
        # Played = every golfer ACTIVE on the hole has a gross score. The
        # withdrawal-aware roster, so a group that lost a man mid-round is
        # not waiting forever on a score that is never coming.
        active = roster.get(h, [])
        played = bool(active) and all(
            gross.get((pid, h)) is not None for pid in active)
        if pending:
            # Which hole the carry came off, for the "Carried from the 4th"
            # chip. The most recent par 3 before this one that resolved.
            prev = [x['hole'] for x in holes if x['decided']]
            row['carried_from'] = prev[-1] if prev else None
        if g is None:
            if played:
                # Played, and nobody is recorded as having taken it. That is
                # the commonest way a greenie goes unclaimed — the group
                # misses the green and says nothing.
                row['decided'] = True
                row['unclaimed'] = True
                pending = worth if carry else 0
            elif nxt is None:
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


def so_strokes_by_hole(real_members, net_percent, par_si) -> dict:
    """{player_id: {hole: strokes}} for the strokes-off birdie basis.

    Strokes off the LOW golfer in the group: each one's playing handicap at
    the game's own allowance, minus the lowest, allocated by stroke index. The
    low man gets none.

    **Not full course handicap**, which is the whole point — a net birdie
    against your own handicap is most of a par, and the design says so.
    """
    from scoring.handicap import _strokes_on_hole, effective_hcp_for
    hcps = {m.player_id: effective_hcp_for(m, net_percent)
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


def derived_from_scores(foursome, *, types, basis='gross',
                        net_percent=100, par_si=None) -> dict:
    """{player_id: {hole: [(type, worth), ...]}} read off the SCORES.

    Birdies and eagles, and nothing else. They never appear on the hole card,
    so this is the only place they exist.

    **An eagle is 2, not 3** — it does not stack with the birdie. And when
    eagles are NOT in play but birdies are, an eagle still scores the birdie:
    it is a birdie or better, and a group paying birdies has not agreed that
    the best score on the hole is worth less than the second best. The design
    leaves that case open; this is the reading.
    """
    in_play = set(types or [])
    birdie, eagle = str(SpotType.BIRDIE), str(SpotType.EAGLE)
    if not ({birdie, eagle} & in_play):
        return {}

    from scoring.models import HoleScore
    real_members = list(foursome.memberships.select_related('player', 'tee')
                        .filter(player__is_phantom=False))
    if par_si is None:
        par_si = par_si_by_hole(real_members)
    so = (so_strokes_by_hole(real_members, net_percent, par_si)
          if basis == 'net_so' else {})

    out = {}
    rows = HoleScore.objects.filter(
        foursome=foursome, player__is_phantom=False).exclude(gross_score=None)
    for r in rows:
        par = par_si.get(r.hole_number, (0, 0))[0]
        if not par:
            continue
        score = int(r.gross_score)
        if basis == 'net_so':
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


