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
    phantom_course_handicap, player_shamble_handicap, scramble_allowance,
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
def ensure_phantom_fourth(foursome):
    """
    Give a three-man team its phantom 4th, handicapped at the average of the
    three real men — and take it away again if a fourth golfer lands.

    Nobody is ever borrowed.  A golfer from another team would be hitting shots
    for a team he is competing against, and every good one costs his own team
    the pot; there is no version of that a TD can defend at the scoring table.

    Returns the phantom membership, or None for a team that does not need one.
    """
    from services.round_setup import _get_or_create_phantom

    real = _real_memberships(foursome)
    existing = _phantom_membership(foursome)

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
    if created and not foursome.name:
        foursome.name = state.colour
        foursome.save(update_fields=['name'])
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
        ensure_phantom_fourth(foursome)
        state = ensure_team_state(foursome, index=foursome.group_number)
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
    """``{hole: balls}`` for this team's card. Scramble plays one ball, so the
    count is meaningless and the dict is empty."""
    if config.is_scramble:
        return {}
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

    if config.is_scramble:
        return scramble_allowance(
            handicaps,
            override_pct  = config.allowance_override_pct,
            phantom_index = phantom_index,
        )
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
    if config.is_scramble:
        return {
            'kind' : 'scramble_table',
            'pct'  : None,
            'table': [25, 20, 15, 10],
            'label': '25 / 20 / 15 / 10 of course handicap, lowest first',
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
        return {
            'rule'            : config.drive_rule,
            'windows'         : [],
            'pairs_set'       : bool(pairs),
            'rota'            : [
                {
                    'hole'          : h,
                    'pair'          : list(pair_on_hole(rota, h) or ()),
                    # "Gunst and Yau are up" — the one line a schedule needs
                    # on the tee.
                    'pair_names'    : [
                        names.get(pid, '')
                        for pid in (pair_on_hole(rota, h) or ())
                    ],
                    'phantom_cover' : phantom_cover_on_hole(rota, ids, h),
                    'phantom_cover_name': names.get(
                        phantom_cover_on_hole(rota, ids, h), ''),
                }
                for h in range(1, 19)
            ],
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


# ---------------------------------------------------------------------------
# 4. The read model
# ---------------------------------------------------------------------------

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
            'shamble_handicap': (
                None if config.is_scramble
                else player_shamble_handicap(c.course_handicap, c.pct)
            ),
        })

    return {
        'foursome_id'       : foursome.id,
        'group_number'      : foursome.group_number,
        'name'              : foursome.name or (state.colour if state else ''),
        'colour'            : state.colour if state else '',
        'real_player_count' : len(real),
        'has_phantom'       : phantom is not None,
        'seats_open'        : max(0, 4 - len(real) - (1 if phantom else 0)),
        'members'           : members,
        'team_handicap'     : allowance.strokes if len(real) + (1 if phantom else 0) >= 4 else None,
        'team_handicap_raw' : str(allowance.raw),
        'allowance'         : allowance_label(foursome, config),
        'drive'             : drive_state(foursome, config),
        'thru'              : thru_hole(foursome),
    }


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
