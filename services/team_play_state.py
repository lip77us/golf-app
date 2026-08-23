"""
services/team_play_state.py
---------------------------
Team Play's DB-aware layer: provisioning the teams, and the read model every
Team Play surface consumes (docs/design-review/handoff-team-play/SPEC.md).

``services/team_play.py`` and ``services/team_handicap.py`` are pure rules.
This module is where they meet the round.

Two things it exists to get right
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
**The phantom has to be provisioned here, not by round setup.**  Team Play
always sends EXPLICIT groups — step 6 is the TD assigning all 23 men by hand —
and ``services/round_setup`` deliberately does not pad an explicit group,
because a 2-man multi-skins group would be distorted by a phantom.  Its
auto-grouped phantom also carries a flat 36 handicap, which is the wrong number
here by a distance: a Team Play phantom is the **average of the three real
men**, and that average is what makes the ordinary 25/20/15/10 table apply with
no special three-man row.

**A team is a Foursome.**  The team name is ``Foursome.name``; everything a
Foursome has no field for — colour, the team figure and its raw sum, the drive
rota — is on :class:`TeamPlayTeamState`.
"""

from decimal import Decimal

from django.db import transaction

from services.team_handicap import (
    BEST_BALL_PCT, allowance_table, best_ball_allowance,
    phantom_course_handicap, player_own_ball_handicap, positional_allowance,
    shamble_allowance, shamble_allowance_pct,
)
from services.team_play import (
    BALLS_PER_HOLE, ball_count_summary, build_rota, drive_penalty_strokes,
    drive_shortfall, drive_windows, pair_on_hole, phantom_cover_on_hole,
    resolve_ball_counts, window_requirement, window_state,
)


# Colour is assigned whether or not the TD renames the team, because it does
# real work on the leaderboard and the scorecard: six team names, most of them
# one syllable and all unfamiliar, and the colour block is how a man finds his
# team without reading.  The packet's six come first, in its order.
TEAM_COLOURS = [
    'Pine', 'Clay', 'Slate', 'Dune', 'Fern', 'Rust',
    'Moss', 'Ash', 'Ochre', 'Flint', 'Reed', 'Cobalt',
]


def team_colour_for(index: int) -> str:
    """1-based group number → its colour, wrapping if a field ever outgrows
    the list."""
    return TEAM_COLOURS[(index - 1) % len(TEAM_COLOURS)]


# ---------------------------------------------------------------------------
# 1. Provisioning
# ---------------------------------------------------------------------------

def _real_memberships(foursome):
    return list(
        foursome.memberships.filter(player__is_phantom=False)
        .select_related('player', 'tee')
        .order_by('course_handicap', 'player__name')
    )


def _phantom_membership(foursome):
    return foursome.memberships.filter(player__is_phantom=True).first()


@transaction.atomic
def ensure_phantom_fourth(foursome, config=None):
    """
    Give a three-man FOURSOME its phantom 4th, handicapped at the average of
    the three real men — and take it away again if a fourth golfer lands.

    Nobody is ever borrowed.  A golfer from another team would be hitting shots
    for a team he is competing against, and every good one costs his own team
    the pot; there is no version of that a TD can defend at the scoring table.

    **A pair never gets one.**  In fours the phantom is a handicap device for a
    team that still hits four balls; in pairs it would be an imaginary man
    taking half the shots in an alternate shot.  An odd field is blocked
    instead, naming the golfer who has no partner — a ten-second fix that does
    not deserve a special case
    (docs/design-review/handoff-team-pairs/SPEC.md §3.1).

    Returns the phantom membership, or None for a team that does not need one.
    """
    from services.round_setup import _get_or_create_phantom

    if config is None:
        config = getattr(foursome.round.tournament, 'team_play_config', None)

    real = _real_memberships(foursome)
    existing = _phantom_membership(foursome)

    if config is not None and config.is_pairs:
        # Pairs have no phantom at any roster size. Clear a stale one so a
        # tournament switched from fours to pairs mid-setup does not keep it.
        if existing:
            existing.delete()
        if foursome.has_phantom:
            foursome.has_phantom = False
            foursome.save(update_fields=['has_phantom'])
        return None

    if len(real) != 3:
        # Four men (or a team still being built) — no phantom, and remove a
        # stale one so a team that just filled up stops carrying it.
        if existing:
            existing.delete()
        if foursome.has_phantom:
            foursome.has_phantom = False
            foursome.save(update_fields=['has_phantom'])
        return None

    avg = phantom_course_handicap([m.course_handicap for m in real])

    if existing:
        if existing.course_handicap != avg or existing.playing_handicap != avg:
            existing.course_handicap  = avg
            existing.playing_handicap = avg
            existing.save(update_fields=['course_handicap', 'playing_handicap'])
    else:
        from tournament.models import FoursomeMembership
        existing = FoursomeMembership.objects.create(
            foursome         = foursome,
            player           = _get_or_create_phantom(foursome.round.account),
            tee              = real[0].tee,
            course_handicap  = avg,
            playing_handicap = avg,
            # The Team Play phantom's ball is PLAYED — by whoever is not
            # driving — so nothing derives its score.  The algorithm is
            # recorded for its handicap rule alone.
            phantom_algorithm = 'rotating_player_scores',
        )

    if not foursome.has_phantom:
        foursome.has_phantom = True
        foursome.save(update_fields=['has_phantom'])
    return existing


@transaction.atomic
def ensure_team_state(foursome, *, index=None):
    """Create the team's state row and give it a colour if it has none."""
    from tournament.models import TeamPlayTeamState

    state, created = TeamPlayTeamState.objects.get_or_create(foursome=foursome)
    if not state.colour:
        state.colour = team_colour_for(index or foursome.group_number)
        state.save(update_fields=['colour'])
    # The colour is NOT written into Foursome.name. A team the TD never named
    # is `Group N` — that is what he was shown in the wizard, and calling it
    # Pine on the hub is the app inventing a name nobody chose. The colour
    # still identifies the row on the board; it just is not the team's name.
    return state


@transaction.atomic
def sync_teams(tournament):
    """
    Bring every team in the tournament's single round up to date: phantoms
    provisioned, colours assigned, allowances computed and stored.

    Idempotent — the build-teams screen calls it on every change, and it is
    called again when the round is created.
    """
    round_obj = tournament.rounds.order_by('round_number').first()
    if round_obj is None:
        return []

    config = getattr(tournament, 'team_play_config', None)
    teams  = []
    for foursome in round_obj.foursomes.order_by('group_number'):
        ensure_phantom_fourth(foursome, config)
        state = ensure_team_state(foursome, index=foursome.group_number)
        if config is not None:
            apply_default_name(foursome, config, state)
        if config is not None:
            allowance = compute_allowance(foursome, config)
            if (state.team_handicap != allowance.strokes
                    or state.team_handicap_raw != allowance.raw):
                state.team_handicap     = allowance.strokes
                state.team_handicap_raw = allowance.raw
                state.save(update_fields=['team_handicap', 'team_handicap_raw'])
        teams.append(foursome)
    return teams


# ---------------------------------------------------------------------------
# 2. Allowance, worked on the TD's own teams
# ---------------------------------------------------------------------------

def hole_data(foursome):
    """The tee's hole list — par and stroke index for all eighteen."""
    membership = foursome.memberships.select_related('tee').first()
    return (membership.tee.holes if membership and membership.tee else []) or []


def resolved_counts(foursome, config):
    """
    ``{hole: balls}`` for this team's card.

    A one-ball format plays one ball, so the count is meaningless and the dict
    is empty.  **Best ball is best-1-of-2 on all eighteen** — a shamble whose
    count the TD does not set — so it resolves to a flat 1 and every consumer
    of this dict works untouched: the card's `1 of 2 counts`, the counting-net
    subset, and par multiplied by the count, which for best-1 is the hole's own
    par.
    """
    if config.plays_one_ball:
        return {}
    if config.counts_every_ball:
        return {h['number']: 1 for h in hole_data(foursome)}
    return resolve_ball_counts(config, hole_data(foursome))


def average_ball_count(foursome, config) -> Decimal:
    counts = resolved_counts(foursome, config)
    if not counts:
        return Decimal('0')
    return Decimal(sum(counts.values())) / Decimal(len(counts))


def compute_allowance(foursome, config):
    """
    The team's figure, worked on its own men.

    A generic illustration proves nothing; his own four men and their four
    percentages are the only numbers a TD will check — which is why this
    returns the contributions, not just the total.
    """
    memberships = _real_memberships(foursome)
    phantom     = _phantom_membership(foursome)

    handicaps = [m.course_handicap for m in memberships]
    phantom_index = None
    if phantom is not None:
        phantom_index = len(handicaps)
        handicaps.append(phantom.course_handicap)

    table = allowance_table(config.team_size, config.team_format)
    if table is not None:
        # Every format that ends in one ball: a positional table, lowest first,
        # summed, rounded ONCE on the total.  25/20/15/10 for a foursome
        # scramble; 35/15, 50/50, 60/40 and 60/40 for the four pairs formats.
        return positional_allowance(
            handicaps, table,
            override_pct  = config.allowance_override_pct,
            phantom_index = phantom_index,
        )

    if config.counts_every_ball:
        # Best ball — 85% of each man's own, and the better net counts. Not a
        # team figure at all; the sum is the balance strip's number.
        return best_ball_allowance(
            handicaps, override_pct=config.allowance_override_pct)

    return shamble_allowance(
        handicaps,
        avg_ball_count = average_ball_count(foursome, config),
        override_pct   = config.allowance_override_pct,
        phantom_index  = phantom_index,
    )


def allowance_label(foursome, config) -> dict:
    """
    What the handicap screen states rather than asks.

    The allowance is a table, not a preference: presenting it as an open
    question invites a guess.
    """
    if config.allowance_override_pct is not None:
        return {
            'kind' : 'override',
            'pct'  : config.allowance_override_pct,
            'label': f'{config.allowance_override_pct}% flat — your own percentage',
        }

    if config.counts_every_ball:
        # Best ball is the ONE pairs format whose allowance is per golfer: each
        # man plays his own strokes and the better net counts. The card reads
        # `3 / 16`, not one figure.
        return {
            'kind' : 'own_ball_pct',
            'pct'  : BEST_BALL_PCT,
            'label': f"{BEST_BALL_PCT}% of each golfer's own course handicap",
        }

    table = allowance_table(config.team_size, config.team_format)
    if table is not None:
        pcts = [int(p * 100) for p in table]
        if config.is_pairs:
            low, high = pcts
            if low == high:
                # Alternate shot: 50% low + 50% high IS 50% of the combined,
                # and combined is how a pair says it out loud. The most
                # generous table by a distance, and correctly so — one ball
                # means both mistakes count.
                label = f'{low}% of the combined course handicap'
            else:
                label = f'{low}% low + {high}% high'
        else:
            label = ' / '.join(str(p) for p in pcts) + \
                    ' of course handicap, lowest first'
        return {
            'kind' : 'pairs_table' if config.is_pairs else 'scramble_table',
            'pct'  : None,
            'table': pcts,
            'label': label,
        }

    pct = shamble_allowance_pct(average_ball_count(foursome, config))
    return {
        'kind' : 'shamble_pct',
        'pct'  : pct,
        'label': f"{pct}% of each golfer's own course handicap",
    }


# ---------------------------------------------------------------------------
# 3. Drives
# ---------------------------------------------------------------------------

def drive_picks(foursome) -> dict:
    """``{hole_number: player_id}`` for the holes played so far."""
    return {
        p.hole_number: p.player_id
        for p in foursome.team_drive_picks.all()
    }


def thru_hole(foursome) -> int:
    """The last hole this team has completed. Drives are the tracker's clock:
    a hole is not complete until the drive is picked."""
    picks = drive_picks(foursome)
    return max(picks) if picks else 0


def drive_state(foursome, config) -> dict:
    """
    The tracker (SPEC §5) — per-window pips, the sentence, and the rota.

    It warns and never blocks: the team may knowingly take the shortfall, and
    by default a shortfall costs nothing.
    """
    from tournament.models import TeamPlayConfig

    real   = _real_memberships(foursome)
    ids    = [m.player_id for m in real]
    picks  = drive_picks(foursome)
    thru   = thru_hole(foursome)

    names = {m.player_id: m.player.name for m in real}

    if config.drive_rule == TeamPlayConfig.DRIVE_NONE:
        return {'rule': config.drive_rule, 'windows': [], 'rota': [],
                'shortfall': 0, 'penalty_strokes': 0}

    if config.drive_rule == TeamPlayConfig.DRIVE_ALTERNATING:
        state = getattr(foursome, 'team_play_state', None)
        pairs = (state.drive_pairs if state else []) or []
        rota  = [tuple(p) for p in pairs] if pairs else build_rota(ids)
        short = {m.player_id: short_label(m.player) for m in real}

        def _rota_row(h):
            up = list(pair_on_hole(rota, h) or ())
            # "Gunst and Yau are up" for a foursome; "Maiolini tees" for a
            # pair. Named on EVERY hole either way — a pair that loses track
            # of an alternate-shot rota plays a hole out of order and the
            # round is gone.
            #
            # The LINE takes short labels because it is read on the tee, one
            # hole at a time; `pair_names` keeps the full names for the roster
            # view beside it.
            up_names = [names.get(pid, '') for pid in up]
            up_short = [short.get(pid, '') for pid in up]
            line = (f'{up_short[0]} tees' if len(up_short) == 1
                    else ' and '.join(up_short) + ' are up') if up_short else ''
            return {
                'hole'          : h,
                'pair'          : up,
                'pair_names'    : up_names,
                'line'          : line,
                'phantom_cover' : phantom_cover_on_hole(rota, ids, h),
                'phantom_cover_name': names.get(
                    phantom_cover_on_hole(rota, ids, h), ''),
            }

        return {
            'rule'            : config.drive_rule,
            'windows'         : [],
            'pairs_set'       : bool(pairs),
            'rota'            : [_rota_row(h) for h in range(1, 19)],
            # A schedule has nothing to fall short of, so the penalty setting
            # does not apply to it.
            'shortfall'       : 0,
            'penalty_strokes' : 0,
        }

    req = window_requirement(config, len(ids))

    # The card names the man — "Maiolini owes 1", not a player id. The pure
    # tracker in services/team_play deals in ids because it has no DB; the
    # names are attached here, where the memberships already are.
    def _named(window):
        for g in window['golfers']:
            g['name'] = names.get(g['player_id'], '')
        return window

    return {
        'rule'            : config.drive_rule,
        'required'        : req['required'],
        'per_golfer'      : req['per_golfer'],
        'holes'           : req['holes'],
        'free'            : req['free'],
        'floating'        : req['floating'],
        'windows'         : [
            _named(window_state(config, w, picks, ids, thru))
            for w in drive_windows(config)
        ],
        'rota'            : [],
        'shortfall'       : drive_shortfall(config, picks, ids),
        'penalty_strokes' : drive_penalty_strokes(config, picks, ids),
    }


def short_label(player) -> str:
    """
    What a golfer is called in one word on a card — his surname.

    The two tee sentences sit on the card, where a full name pushes the line
    onto two rows and reads nothing like the way a pair talks: *Maiolini tees*,
    *Yau plays the second shot*.  Everywhere with room for it — the drive
    tracker, the team roster, settlement — keeps the full name.

    Not ``Player.short_name``: that is the scorecard's five-character column
    label and comes out as initials (`AM`), which is a grid header rather than
    something you say to a man on a tee.
    """
    full = (player.name or '').strip()
    return full.split()[-1] if full else ''


def drive_control_kind(config) -> str:
    """
    What the tee-shot control on the card actually DOES
    (docs/design-review/handoff-team-pairs/SPEC.md §5).

    Every format that chooses a tee shot draws the same control, and this is
    the part to get right in code:

    ``record``       Scramble.  Compliance against a quota — a tick.
    ``instruction``  Scotch.  Picking the drive says who hits NEXT, so the card
                     answers with a sentence rather than a tick.  A quota is
                     available on top, off by default, because the tap is
                     already there.
    ``rota``         Alternate shot.  Odd/even, set on the 1st tee, fixed for
                     eighteen.  Nothing is chosen on the hole; the card states
                     who is up.
    ``none``         Best ball and Chapman.  Both men drive every hole with no
                     choice to record.
    """
    from tournament.models import TeamPlayConfig

    if config.team_format == TeamPlayConfig.FORMAT_SCOTCH:
        return 'instruction'
    if config.team_format == TeamPlayConfig.FORMAT_ALTERNATE_SHOT:
        return 'rota'
    if config.team_format in (TeamPlayConfig.FORMAT_BEST_BALL,
                              TeamPlayConfig.FORMAT_CHAPMAN):
        return 'none'
    return 'record'


def tee_note(foursome, config, hole_number: int) -> str:
    """
    The sentence the card says on this hole, or ``''`` when the format has
    nothing to say.

    Two of them, and they are the two the packet asks for by name:

    * **Scotch, once the drive is picked** — *Maiolini plays the second shot,
      then alternate.*  The partner whose drive was NOT taken plays the second
      shot, which is why the tap is an instruction rather than a record.
    * **Alternate shot, on every tee** — *Maiolini tees.*  Without exception:
      a pair that loses track plays a hole out of order and the round is gone.

    Computed here, on the server, so the client never re-derives a rule.
    """
    from tournament.models import TeamPlayConfig

    kind = drive_control_kind(config)
    real = _real_memberships(foursome)
    # Surnames on the card, the way the packet draws it and the way a pair says
    # it out loud — "Maiolini tees", not "Anna Maiolini tees". The tracker off
    # the card keeps full names, where there is room for them.
    names = {m.player_id: short_label(m.player) for m in real}

    if kind == 'rota':
        state = getattr(foursome, 'team_play_state', None)
        pairs = (state.drive_pairs if state else []) or []
        if not pairs:
            return 'Set the tee rota before the first score.'
        rota = [tuple(p) for p in pairs]
        up   = pair_on_hole(rota, hole_number) or ()
        return f'{names.get(up[0], "")} tees.' if up else ''

    if kind == 'instruction':
        picked = drive_picks(foursome).get(hole_number)
        if picked is None:
            return 'Both drive — take the better one. The pick says who plays next.'
        other = next((pid for pid in names if pid != picked), None)
        if other is None:
            return ''
        return f'{names[other]} plays the second shot, then alternate.'

    if config.team_format == TeamPlayConfig.FORMAT_CHAPMAN:
        return 'Both drive, swap for the second, then one ball in turn.'
    if config.team_format == TeamPlayConfig.FORMAT_BEST_BALL:
        return 'Both play their own ball. The better net counts.'
    return ''


# ---------------------------------------------------------------------------
# 4. The read model
# ---------------------------------------------------------------------------

def team_name(foursome, config, real=None) -> str:
    """
    What the team is called before the TD names it.

    **A foursome is `Group N`.**  Four surnames fit nowhere and a colour the TD
    never chose is one more thing on screen that does not help him.

    **A pair is its two surnames** — `Maiolini & Yau`.  That is not the app
    inventing a name: it is the only thing anybody calls a pair, two fit on a
    leaderboard row, and golfers say it that way out loud.  Sixteen characters,
    the same cap the ball game uses, and a pair whose surnames overflow it
    falls back to `Group N` rather than being truncated mid-word.  Free text
    over it either way, and the colour is still assigned for the card.
    """
    if foursome.name:
        return foursome.name
    fallback = f'Group {foursome.group_number}'
    if not config.is_pairs:
        return fallback
    return _pair_surnames(foursome, real) or fallback


@transaction.atomic
def apply_default_name(foursome, config, state=None):
    """
    Write a pair's surname name onto the Foursome, so every surface reads it —
    the round hub, the tee sheet, the chat header and the board, none of which
    know Team Play exists.

    Only while ``name_is_default``: the moment the TD types his own name over
    it, a roster change stops dragging the name along with it.

    A foursome is untouched.  `Group N` is a label rather than a name, and
    writing a colour a TD never chose into the field would make it one.
    """
    if not config.is_pairs:
        return None
    state = state or ensure_team_state(foursome)
    if not state.name_is_default:
        return None
    derived = _pair_surnames(foursome)
    if derived and foursome.name != derived:
        foursome.name = derived
        foursome.save(update_fields=['name'])
    return derived


def _pair_surnames(foursome, real=None):
    """`Maiolini & Yau`, or `''` when the roster cannot produce one."""
    if real is None:
        real = _real_memberships(foursome)
    if len(real) != 2:
        return ''
    surnames = [m.player.name.split()[-1]
                for m in real if (m.player.name or '').strip()]
    if len(surnames) != 2:
        return ''
    joined = ' & '.join(surnames)
    # Sixteen characters, the same cap the ball game uses, because the name has
    # to fit a leaderboard row next to a colour block. Overflow falls back to
    # `Group N` rather than being truncated mid-word.
    return joined if len(joined) <= 16 else ''


def team_dict(foursome, config) -> dict:
    """One team, as every Team Play surface reads it."""
    real      = _real_memberships(foursome)
    phantom   = _phantom_membership(foursome)
    state     = getattr(foursome, 'team_play_state', None)
    allowance = compute_allowance(foursome, config)

    # Match each contribution back to its member. The contributions are sorted
    # low to high — the order IS the rule, because the percentage is
    # positional — so a manual order would be a lie.
    by_handicap = {}
    for m in real:
        by_handicap.setdefault(m.course_handicap, []).append(m)

    members = []
    for c in allowance.contributions:
        if c.is_phantom:
            members.append({
                'player_id'       : phantom.player_id if phantom else None,
                'name'            : 'Phantom 4th',
                'course_handicap' : c.course_handicap,
                'pct'             : c.pct,
                'strokes'         : str(c.strokes),
                'is_phantom'      : True,
            })
            continue
        pool = by_handicap.get(c.course_handicap) or []
        m = pool.pop(0) if pool else None
        members.append({
            'player_id'       : m.player_id if m else None,
            'name'            : m.player.name if m else '',
            'course_handicap' : c.course_handicap,
            'pct'             : c.pct,
            'strokes'         : str(c.strokes),
            'is_phantom'      : False,
            'own_ball_handicap': (
                None if config.plays_one_ball
                else player_own_ball_handicap(c.course_handicap, c.pct)
            ),
            # The name this key had while a shamble was the only own-ball
            # format. Kept so a client that has not shipped yet still reads.
            'shamble_handicap': (
                None if config.plays_one_ball
                else player_own_ball_handicap(c.course_handicap, c.pct)
            ),
        })

    size   = config.team_size
    filled = len(real) + (1 if phantom else 0)

    return {
        'foursome_id'       : foursome.id,
        'group_number'      : foursome.group_number,
        'name'              : team_name(foursome, config, real),
        'colour'            : state.colour if state else '',
        'real_player_count' : len(real),
        'team_size'         : size,
        'has_phantom'       : phantom is not None,
        'seats_open'        : max(0, size - filled),
        'members'           : members,
        # Published once the team is full at ITS size — two for a pair. A team
        # still being built has no figure, because moving one man changes it.
        'team_handicap'     : allowance.strokes if filled >= size else None,
        'team_handicap_raw' : str(allowance.raw),
        'allowance'         : allowance_label(foursome, config),
        'drive'             : drive_state(foursome, config),
        'drive_control'     : drive_control_kind(config),
        'thru'              : thru_hole(foursome),
    }


def field_blocking(teams, config) -> list:
    """
    What stands between the TD and a playable field
    (docs/design-review/handoff-team-pairs/SPEC.md §3.1).

    Empty for a foursome event: the group sizes slice the whole field, a short
    team fields a phantom, and no golfer can be left over.

    **Pairs need an even field**, and there is no phantom to paper over an odd
    one — in fours the phantom is a handicap device for a team that still hits
    four balls; in pairs it would be an imaginary man taking half the shots in
    an alternate shot.  So the block is plain, and it **names the golfer** who
    has no partner rather than reporting a count: the fix is about one man and
    the TD needs to know which one is standing there.

    Two kinds:

    ``unpaired``    a team of one.  Three ways out, offered on the block —
                    add a golfer, take him out, or let one team play three.
                    **The third is best-ball only**: a third ball is just
                    another option to count, alternate shot and Chapman cannot
                    honour it at all, and in a scramble it is a straight
                    advantage.  Offering a choice four of the five formats
                    reject is worse than not offering it.
    ``three_ball``  a team of three outside best ball.  Same reason, the other
                    way round.
    """
    if not config.is_pairs:
        return []

    three_ok = config.counts_every_ball
    out = []
    for team in teams:
        real = team['real_player_count']
        if real == 0:
            continue
        if real < 2:
            golfer = team['members'][0] if team['members'] else None
            out.append({
                'kind'        : 'unpaired',
                'foursome_id' : team['foursome_id'],
                'golfer'      : golfer,
                'three_ball_available': three_ok,
                'detail'      : (
                    f"{golfer['name']} has no partner." if golfer
                    else 'A pair is short a golfer.'
                ),
            })
        elif real > 2 and not three_ok:
            out.append({
                'kind'        : 'three_ball',
                'foursome_id' : team['foursome_id'],
                'team'        : team['name'],
                'three_ball_available': False,
                'detail'      : (
                    f"{team['name']} has {real} golfers. Only best ball can "
                    f"play a three — a third ball is another option to count, "
                    f"and in the other formats it cannot work at all."
                ),
            })
    return out


def team_play_summary(tournament) -> dict:
    """
    Everything the wizard's later steps, the cards and the boards read.

    ``None`` when the tournament is not a Team Play event or has no config yet
    — nothing downstream may assume the shape exists.
    """
    config = getattr(tournament, 'team_play_config', None)
    if config is None or not tournament.is_team_play:
        return None

    round_obj = tournament.rounds.order_by('round_number').first()
    foursomes = list(round_obj.foursomes.order_by('group_number')) if round_obj else []
    teams     = [team_dict(f, config) for f in foursomes]

    golfers = sum(t['real_player_count'] for t in teams)
    pool    = float(config.entry_fee or 0) * golfers

    counts = resolve_ball_counts(config, hole_data(foursomes[0])) if (
        config.is_shamble and foursomes) else {}

    return {
        'configured'   : True,
        'format'       : config.team_format,
        'team_size'    : config.team_size,
        # The format list the size allows, and the drive rules the FORMAT
        # allows. Both are server-owned so the wizard cannot offer a
        # combination the scoring cannot honour.
        'formats'      : list(
            config.FORMATS_BY_SIZE.get(config.team_size, ())),
        'drive_rules'  : list(config.drive_rules_allowed),
        'drive_control': drive_control_kind(config),
        'requires_drive_pick': config.requires_drive_pick,
        'blocking'     : field_blocking(teams, config),
        'locked'       : config.is_locked,
        'handicap_mode': config.handicap_mode,
        'ball_counts'  : {str(k): v for k, v in counts.items()},
        'ball_count'   : ball_count_summary(counts) if counts else None,
        'drive_rule'   : config.drive_rule,
        'drive_penalty': config.drive_penalty,
        'entry_fee'    : float(config.entry_fee or 0),
        'places_paid'  : config.places_paid,
        'split_pcts'   : config.split_pcts or [],
        'field'        : {
            'golfers' : golfers,
            'teams'   : len(teams),
            'pool'    : round(pool, 2),
        },
        'teams'        : teams,
    }
