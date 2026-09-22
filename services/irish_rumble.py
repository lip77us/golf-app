"""
services/irish_rumble.py
------------------------
Irish Rumble calculator.

Rules
~~~~~
* All foursomes in the round compete against each other as teams.
* The round is divided into segments (defined in IrishRumbleConfig.segments):
      Hole 1–6:   count best 1 score per group
      Hole 7–12:  count best 2 scores per group
      Hole 13–17: count best 3 scores per group
      Hole 18:    count best 4 scores (all) per group
  (Segments are fully configurable per round via IrishRumbleConfig.)
* For 3-some groups, balls_to_count is capped at real player count.
* Lowest total score in a segment wins that segment.
* Overall winner = lowest cumulative score across all segments.

Scoring
~~~~~~~
* Each player's per-hole score is adjusted for handicap per IrishRumbleConfig:
    - 'net'         : gross − strokes (playing_handicap × net_percent / 100)
    - 'gross'       : raw gross score
    - 'strokes_off' : gross − max(0, own_handicap − tournament_low_handicap),
                      strokes allocated by hole stroke_index.
  The reference for strokes_off is the lowest playing_handicap across ALL
  foursomes in the round (not just within each group).
* Net-double-bogey cap: when Round.net_max_double_bogey is on, every
  per-hole effective score is capped at par + 2 after handicap adjustment.
  When the flag is off, raw adjusted scores feed the segment math.  This
  damage limiter is opt-in per round (see the Settings toggle on the IR
  setup screen, or the Tournament bulk-admin action).
* Reported as net-to-par (sum of counting scores minus sum of hole pars).

Public API
~~~~~~~~~~
    results = calculate_irish_rumble(round_obj)
    summary = irish_rumble_summary(round_obj)
"""

from django.db import transaction

from core.handicap_math import round_half_up
from core.models import HandicapMode
from games.models import IrishRumbleConfig, IrishRumbleSegmentResult
from scoring.models import HoleScore
from scoring.handicap import _effective_hcp, _strokes_on_hole, effective_hcp_for
from tournament.models import Foursome


# ---------------------------------------------------------------------------
# Variant → per-hole balls-to-count
# ---------------------------------------------------------------------------
#
# Irish Rumble ships with four named variants.  Each variant maps every
# hole to a "balls to count" integer; the existing scoring code already
# walks the `segments` JSON, so we derive an equivalent list of
# {start_hole, end_hole, balls_to_count} segments from the variant's
# per-hole values, collapsing contiguous runs that share the same value.
#
#   * classic         — Holes 1–6 → 1, 7–12 → 2, 13–17 → 3, 18 → 4
#                       (the original/default variant — slow build-up to
#                        "everyone counts" on the closing hole).
#   * arizona_shuffle — Rotate 1/2/3 every 3 holes:
#                       H1-3:1, H4-6:2, H7-9:3, H10-12:1, H13-15:2, H16-18:3
#   * shuffle         — Par-driven: par 3 → 3 balls, par 4 → 2 balls,
#                       par 5 → 1 ball.  Rewards collective short-iron play
#                       and individual heroics on the long holes.
#   * custom          — TD picks the per-hole balls-to-count themselves
#                       (1-4 per hole, capped to group size at scoring time).
#

# Variant slugs — keep in sync with IrishRumbleConfig.VARIANT_CHOICES.
VARIANT_CLASSIC         = 'classic'
VARIANT_ARIZONA_SHUFFLE = 'arizona_shuffle'
VARIANT_SHUFFLE         = 'shuffle'
VARIANT_CUSTOM          = 'custom'

VARIANT_CHOICES = (
    (VARIANT_CLASSIC,         'Classic'),
    (VARIANT_ARIZONA_SHUFFLE, 'Arizona Shuffle'),
    (VARIANT_SHUFFLE,         'Shuffle (par-based)'),
    (VARIANT_CUSTOM,          'Custom (per-hole)'),
)


def _shuffle_balls_for_par(par):
    """Par-based variant: P3→3 balls, P4→2 balls, P5→1 ball, fallback 2."""
    if par == 3:
        return 3
    if par == 4:
        return 2
    if par == 5:
        return 1
    return 2  # par 6 or anything weird — treat like P4


def _balls_per_hole(variant, par_by_hole, custom_balls=None):
    """
    Return a dict {hole_number: balls_to_count} for all 18 holes given
    a variant + the course's par-by-hole map.  `custom_balls` is a list
    of 18 ints required when variant == 'custom'.
    """
    if variant == VARIANT_ARIZONA_SHUFFLE:
        # H1-3:1, H4-6:2, H7-9:3, H10-12:1, H13-15:2, H16-18:3
        pattern = [1, 2, 3, 1, 2, 3]
        return {h: pattern[(h - 1) // 3] for h in range(1, 19)}

    if variant == VARIANT_SHUFFLE:
        return {
            h: _shuffle_balls_for_par(par_by_hole.get(h, 4))
            for h in range(1, 19)
        }

    if variant == VARIANT_CUSTOM:
        if not custom_balls or len(custom_balls) != 18:
            raise ValueError(
                "custom variant requires custom_balls list of length 18"
            )
        return {h: int(custom_balls[h - 1]) for h in range(1, 19)}

    # classic (and fallback for unknown values)
    classic = {}
    for h in range(1, 19):
        if h <= 6:
            classic[h] = 1
        elif h <= 12:
            classic[h] = 2
        elif h <= 17:
            classic[h] = 3
        else:
            classic[h] = 4
    return classic


class IrishRumbleExcluded(Exception):
    """Irish Rumble and Better Ball are the same competition scored two ways.

    The mirror of :class:`services.better_ball.BetterBallExcluded` — see there
    for the argument. Both directions are guarded because a TD can reach the
    two setups in either order, and a rule enforced on one side only is a rule
    that holds until somebody clicks the other button first.
    """


def refuse_if_better_ball(round_obj) -> None:
    from games.models import BetterBallConfig
    if BetterBallConfig.objects.filter(round=round_obj).exists():
        raise IrishRumbleExcluded(
            'This round is already running Better Ball. Irish Rumble ranks '
            'the same groups the same way, so a round runs one or the other '
            '— turn Better Ball off first.')


def compute_segments(variant, par_by_hole, custom_balls=None):
    """
    Return the segments list for a given variant.  Contiguous holes
    that share the same balls_to_count are collapsed into a single
    segment so the existing UI breakdown stays readable (e.g. Shuffle on
    a course with three consecutive par-4s yields one "Holes N-(N+2)
    (best 2)" segment instead of three separate single-hole rows).

    Output matches IrishRumbleConfig.segments JSON shape:
        [{'start_hole': int, 'end_hole': int, 'balls_to_count': int}, ...]
    """
    per_hole = _balls_per_hole(variant, par_by_hole, custom_balls)
    segments = []
    seg_start = 1
    cur_balls = per_hole[1]
    for h in range(2, 19):
        if per_hole[h] != cur_balls:
            segments.append({
                'start_hole': seg_start,
                'end_hole': h - 1,
                'balls_to_count': cur_balls,
            })
            seg_start = h
            cur_balls = per_hole[h]
    # Final segment (always runs through hole 18)
    segments.append({
        'start_hole': seg_start,
        'end_hole': 18,
        'balls_to_count': cur_balls,
    })
    return segments


def par_by_hole_for_round(round_obj):
    """
    Public helper: returns {hole_number: par} for the round, using the
    first available tee.  Setup code uses this to compute segments at
    save time for variants that depend on course par.
    """
    return _par_index_for_round(round_obj)


# ---------------------------------------------------------------------------
# Threesome leveling — borrowed-4th phantom
# ---------------------------------------------------------------------------

@transaction.atomic
def ensure_irish_rumble_phantom(round_obj) -> int:
    """
    Idempotently give every *true threesome* in an Irish Rumble round a
    borrowed-4th phantom (the threesome-leveling design — see
    docs/irish-rumble.md, "Leveling mixed groups — chosen design").

    A true threesome = a foursome with exactly 3 real players and no existing
    phantom.  Each such group gets a phantom 4th whose per-hole gross is
    borrowed from a fixed, shuffled donor rotation over **every real player in
    every other group** (whole-field), via
    ``scoring.phantom.CrossFoursomeRotation``.  The phantom counts as a team
    member feeding the group's best-N pool (it is NOT an opponent — contrast
    Triple Cup, which uses the same machinery to fill an opponent slot).  Each
    borrowed hole is handicapped by that hole's donor (``donor_handicaps``),
    applied in :func:`_build_ir_score_index`.

    Safe to call repeatedly: groups that already have a phantom are left
    untouched (the rotation is built once and stays fixed).  Returns the number
    of phantoms created.

    No-op unless the round has an :class:`IrishRumbleConfig`.
    """
    if not IrishRumbleConfig.objects.filter(round=round_obj).exists():
        return 0
    return _ensure_borrowed_fourth(round_obj)


def _ensure_borrowed_fourth(round_obj) -> int:
    """The borrowed 4th itself, with no opinion about which game asked.

    Split out of :func:`ensure_irish_rumble_phantom` because **Better Ball owes
    a threesome the same ball**: a group of three counts a ball short on every
    hole against a field of foursomes whichever of the two games is being
    played, and levelling it is a property of the competition rather than of
    Rumble. The gate stays with each caller, since each knows its own config.
    """
    from tournament.models import FoursomeMembership
    from scoring.models import HoleScore
    from scoring.phantom import get_algorithm, CROSS_FOURSOME_ALGORITHM_ID
    from services.round_setup import _get_or_create_phantom

    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # {foursome_id: [(player_id, name, playing_handicap), ...]} — real players.
    real_by_fs = {
        fs.pk: [
            (m.player_id, m.player.name, m.playing_handicap or 0)
            for m in fs.memberships.all()
            if not m.player.is_phantom
        ]
        for fs in foursomes
    }

    # The borrowed-4th levels a threesome UP to the field's largest group.  When
    # every group is the same size (e.g. a 9-golfer 3-on-3-on-3 round), there is
    # no asymmetry to correct — all groups already count the same number of balls
    # — so no phantom is added.  Only pad a threesome when some group has ≥4 real
    # players to level up to.
    max_group_size = max((len(m) for m in real_by_fs.values()), default=0)
    if max_group_size < 4:
        return 0

    algo           = get_algorithm(CROSS_FOURSOME_ALGORITHM_ID)
    phantom_player = None
    created        = 0

    for fs in foursomes:
        real = real_by_fs[fs.pk]
        if len(real) != 3:
            continue

        # A threesome may already carry a phantom membership from another game's
        # pad-to-4 (e.g. Pink Ball / Sixes), created as an INTRA-foursome rotating
        # phantom.  Irish Rumble's borrowed-4th is a CROSS-foursome phantom, so we
        # CONVERT that membership rather than skip it.  An already-converted
        # borrowed-4th is left untouched (don't reshuffle its rotation).
        existing_phantom_m = next(
            (m for m in fs.memberships.all() if m.player.is_phantom), None
        )
        if (existing_phantom_m
                and existing_phantom_m.phantom_algorithm == CROSS_FOURSOME_ALGORITHM_ID):
            continue

        # Donor pool = every real player in every OTHER group (whole field),
        # finished or not — unfinished donors resolve once they post.
        donors = [
            (pid, name, hcp)
            for other_id, members in real_by_fs.items()
            if other_id != fs.pk
            for (pid, name, hcp) in members
        ]
        if not donors:
            continue  # single-group round — nothing to borrow from.

        config = algo.initial_config_with_names(
            [(pid, name) for pid, name, _ in donors]
        )
        # Per-donor handicaps drive the per-hole borrowed-ball adjustment.
        config['donor_handicaps'] = {str(pid): hcp for pid, _, hcp in donors}

        # Phantom plays from a real member's tee (for SI lookups); scratch
        # handicap — the rotating donor's handicap drives each borrowed hole.
        first_real_m = next(
            (m for m in fs.memberships.all()
             if not m.player.is_phantom and m.tee_id is not None),
            None,
        )
        phantom_tee = first_real_m.tee if first_real_m else None

        if existing_phantom_m is not None:
            # Convert the pad-to-4 phantom into the borrowed-4th in place.
            existing_phantom_m.phantom_algorithm = CROSS_FOURSOME_ALGORITHM_ID
            existing_phantom_m.phantom_config     = config
            existing_phantom_m.course_handicap    = 0
            existing_phantom_m.playing_handicap   = 0
            if existing_phantom_m.tee_id is None and phantom_tee is not None:
                existing_phantom_m.tee = phantom_tee
            existing_phantom_m.save(update_fields=[
                'phantom_algorithm', 'phantom_config',
                'course_handicap', 'playing_handicap', 'tee',
            ])
            phantom_for_cleanup = existing_phantom_m.player
        else:
            if phantom_player is None:
                phantom_player = _get_or_create_phantom(round_obj.account)
            FoursomeMembership.objects.create(
                foursome          = fs,
                player            = phantom_player,
                tee               = phantom_tee,
                course_handicap   = 0,
                playing_handicap  = 0,
                phantom_algorithm = CROSS_FOURSOME_ALGORITHM_ID,
                phantom_config    = config,
            )
            phantom_for_cleanup = phantom_player

        # IR reads donor scores live (provider.phantom_gross_scores) — drop any
        # pre-populated filler (pad-to-4 phantoms carry bogey scores) so the
        # borrowed ball stays empty until its donor posts.
        HoleScore.objects.filter(foursome=fs, player=phantom_for_cleanup).delete()

        if not fs.has_phantom:
            fs.has_phantom = True
            fs.save(update_fields=['has_phantom'])

        created += 1

    return created


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _build_ir_score_index(round_obj, handicap_mode, net_percent, *,
                          force_cap=False):
    """
    Build {foursome_id: {player_id: {hole_number: capped_score}}} for all
    real players in the round.

    Applies the handicap adjustment.  The net-double-bogey cap (per-hole
    net par + 2) is only applied when the round's `net_max_double_bogey`
    flag is on.  For strokes_off mode, SO strokes are relative to the
    lowest playing_handicap across ALL foursomes in the round.

    `force_cap` applies it regardless — for Better Ball, where the cap is a
    RULE of individual play rather than the round's own opt-in setting. Same
    call `low_net_round` makes. Rumble does not pass it, so its behaviour is
    unchanged.
    """
    cap_enabled = force_cap or bool(round_obj.net_max_double_bogey)
    foursomes = list(
        Foursome.objects
        .filter(round=round_obj)
        .prefetch_related('memberships__player', 'memberships__tee')
    )

    # Build membership lookup: {foursome_id: {player_id: membership}}
    membership_index = {}
    for fs in foursomes:
        membership_index[fs.pk] = {
            m.player_id: m
            for m in fs.memberships.all()
            if not m.player.is_phantom
        }

    # Build par lookup: {foursome_id: {hole_number: par}}
    # Use the first tee found for each foursome (par is the same across tees
    # at the same course for the purposes of the cap).
    par_index = {}
    for fs in foursomes:
        first_m = next(
            (m for m in fs.memberships.all() if m.tee_id is not None), None
        )
        if first_m:
            par_index[fs.pk] = {h['number']: h['par'] for h in first_m.tee.holes}

    # For strokes_off: tournament-wide lowest playing_handicap (real players only)
    low_hcp = 0
    if handicap_mode == HandicapMode.STROKES_OFF:
        all_hcps = [
            m.playing_handicap
            for ms in membership_index.values()
            for m in ms.values()
        ]
        low_hcp = min(all_hcps) if all_hcps else 0

    # Fetch all relevant hole scores in one query
    qs = (
        HoleScore.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .exclude(gross_score=None)
        .values('foursome_id', 'player_id', 'hole_number',
                'gross_score', 'net_score')
    )

    result = {}
    for hs in qs:
        fid  = hs['foursome_id']
        pid  = hs['player_id']
        hole = hs['hole_number']

        membership = membership_index.get(fid, {}).get(pid)
        if membership is None:
            continue

        # ── Handicap adjustment ─────────────────────────────────────────────
        if handicap_mode == HandicapMode.GROSS:
            adjusted = hs['gross_score']

        elif handicap_mode == HandicapMode.NET:
            if net_percent == 100 and hs['net_score'] is not None:
                # Re-use stored value — fast path
                adjusted = hs['net_score']
            else:
                if membership.tee_id is None:
                    continue
                si  = membership.tee.hole(hole).get('stroke_index', 18)
                eff = effective_hcp_for(membership, net_percent)
                adjusted = hs['gross_score'] - _strokes_on_hole(eff, si)

        else:  # STROKES_OFF
            if membership.tee_id is None:
                continue
            si       = membership.tee.hole(hole).get('stroke_index', 18)
            # Scale the strokes-off differential by net_percent, matching every
            # other game (nassau.py / sixes.py / rabbit.py / low_net_round.py)
            # and the 'Strokes Off Low (90%)' chip the setup screen renders.
            so       = round_half_up(
                max(0, membership.playing_handicap - low_hcp)
                * net_percent / 100)
            adjusted = hs['gross_score'] - _strokes_on_hole(so, si)

        # ── Net-double-bogey cap (round-level toggle) ───────────────────────
        if cap_enabled:
            par     = par_index.get(fid, {}).get(hole, 4)
            adjusted = min(adjusted, par + 2)

        result.setdefault(fid, {}).setdefault(pid, {})[hole] = adjusted

    # ── Inject phantom scores ───────────────────────────────────────────────
    # A phantom's per-hole gross is borrowed from a donor.  For a cross-foursome
    # (borrowed-4th) phantom — the Irish Rumble threesome-leveling design — each
    # borrowed hole is handicapped by THAT HOLE'S donor (donor_handicaps), so the
    # borrowed ball is the donor's own net/gross/strokes-off under the round's IR
    # mode.  Legacy intra-foursome (rotating_player_scores) phantoms keep their
    # averaged playing handicap.
    from scoring.phantom import PhantomScoreProvider, get_algorithm

    # player_id → membership (with tee) across the whole round.  A borrowed-4th
    # phantom scores each hole AS its rotating donor, so the donor's own tee
    # drives stroke-index allocation + par — courses where the men's/women's SI
    # tables differ (e.g. Tilden Park) would mis-allocate against any other tee.
    member_by_pid = {
        m.player_id: m
        for fs in foursomes
        for m in fs.memberships.all()
        if not m.player.is_phantom
    }

    for fs in foursomes:
        if not fs.has_phantom:
            continue
        provider = PhantomScoreProvider(fs)
        if not provider.has_phantom:
            continue
        phantom_m = next(
            (m for m in fs.memberships.all() if m.player.is_phantom), None
        )
        if phantom_m is None:
            continue
        phantom_gross = provider.phantom_gross_scores()
        phantom_pid   = phantom_m.player_id
        is_cross      = provider.is_cross_foursome
        phantom_hcp   = None if is_cross else provider.phantom_playing_handicap()
        donor_algo    = get_algorithm(phantom_m.phantom_algorithm) if is_cross else None
        donor_cfg     = (phantom_m.phantom_config or {}) if is_cross else {}

        # Fallback tee (legacy phantom, or donor with no tee) — phantom's own,
        # else the first real member's.
        fallback_tee = phantom_m.tee or next(
            (m.tee for m in fs.memberships.all()
             if not m.player.is_phantom and m.tee_id), None
        )
        if fallback_tee is None and not is_cross:
            continue

        # Only borrow a 4th ball on holes the group has actually PLAYED (some
        # real player scored).  A donor who is ahead of the threesome must not
        # add "future" holes to the group total or advance its "thru".
        real_holes = set()
        for holes_map in result.get(fs.pk, {}).values():
            real_holes.update(holes_map.keys())

        for hole, gross in phantom_gross.items():
            if hole not in real_holes:
                continue
            if is_cross:
                # Borrowed ball is fully the donor's hole: donor's own tee for
                # SI + par, and the donor's individual handicap for this hole.
                donor_pid = donor_algo.get_source_player_id(hole, donor_cfg)
                donor_m   = member_by_pid.get(donor_pid)
                hole_tee  = (donor_m.tee if (donor_m and donor_m.tee_id)
                             else fallback_tee)
                hcp       = donor_algo.donor_handicap(hole, donor_cfg)
            else:
                hole_tee  = fallback_tee
                hcp       = phantom_hcp
            if hole_tee is None:
                continue
            hd       = hole_tee.hole(hole)
            si       = hd.get('stroke_index', 18)
            hole_par = hd.get('par', 4)
            if hcp is None:
                hcp = 0

            if handicap_mode == HandicapMode.GROSS:
                adjusted = gross
            elif handicap_mode == HandicapMode.NET:
                eff = _effective_hcp(hcp, net_percent)
                adjusted = gross - _strokes_on_hole(eff, si)
            else:  # STROKES_OFF
                so = max(0, hcp - low_hcp)
                adjusted = gross - _strokes_on_hole(so, si)

            # Net-double-bogey cap, gated like the real players above.
            if cap_enabled:
                # Legacy phantom keeps the receiving foursome's par; a borrowed
                # ball uses the donor's own tee par (computed above).
                par      = hole_par if is_cross else par_index.get(fs.pk, {}).get(hole, 4)
                adjusted = min(adjusted, par + 2)

            result.setdefault(fs.pk, {}).setdefault(phantom_pid, {})[hole] = adjusted

    return result


def _par_index_for_round(round_obj):
    """
    Return {hole_number: par} using the first tee found in the round.
    Used for computing net-to-par totals in the summary.
    """
    fs = Foursome.objects.filter(round=round_obj).prefetch_related(
        'memberships__tee'
    ).first()
    if fs is None:
        return {}
    first_m = next(
        (m for m in fs.memberships.all() if m.tee_id is not None), None
    )
    if first_m is None:
        return {}
    return {h['number']: h['par'] for h in first_m.tee.holes}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

@transaction.atomic
def calculate_irish_rumble(round_obj) -> list:
    """
    Calculate IrishRumbleSegmentResult rows for every foursome × segment.

    Requires an IrishRumbleConfig for this round. Safe to call repeatedly —
    previous results are replaced.

    Returns a flat list of IrishRumbleSegmentResult instances.
    """
    config = IrishRumbleConfig.objects.filter(round=round_obj).first()
    if config is None:
        return []

    # Auto-apply the borrowed-4th here (not just at setup) so an existing round
    # picks it up on the next score submit — no IR-setup re-save required.
    # Idempotent: no-op once every true threesome already carries it.
    ensure_irish_rumble_phantom(round_obj)

    handicap_mode = config.handicap_mode
    net_percent   = config.net_percent

    foursomes = list(Foursome.objects.filter(round=round_obj).order_by('group_number'))

    # Build the capped score index for the whole round
    score_index = _build_ir_score_index(round_obj, handicap_mode, net_percent)

    # Player counts per foursome (including phantom)
    player_counts = {
        fs.pk: fs.memberships.filter(player__is_phantom=False).count()
               + (1 if fs.has_phantom else 0)
        for fs in foursomes
    }

    IrishRumbleSegmentResult.objects.filter(round=round_obj).delete()
    saved = []

    for seg_idx, seg in enumerate(config.segments):
        start_hole = seg['start_hole']
        end_hole   = seg['end_hole']
        configured = seg['balls_to_count']
        holes_in_seg = list(range(start_hole, end_hole + 1))

        seg_results = []

        for foursome in foursomes:
            player_count = player_counts[foursome.pk]
            balls        = min(configured, player_count)
            fs_scores    = score_index.get(foursome.pk, {})

            # For each hole in the segment, take the N best (lowest) scores
            # from the group and sum them.  The segment total is the sum of
            # those per-hole N-best amounts across all holes in the segment.
            hole_totals = []
            all_holes_present = True
            for hole_num in holes_in_seg:
                scores_on_hole = sorted([
                    player_holes[hole_num]
                    for player_holes in fs_scores.values()
                    if hole_num in player_holes
                ])
                if scores_on_hole:
                    hole_totals.append(sum(scores_on_hole[:balls]))
                else:
                    all_holes_present = False
                    break

            if all_holes_present and len(hole_totals) == len(holes_in_seg):
                total = sum(hole_totals)
            else:
                total = None  # segment incomplete

            seg_results.append({
                'foursome' : foursome,
                'balls'    : balls,
                'total'    : total,
            })

        # Rank within this segment (lowest wins; None = unranked)
        completed = sorted(
            [r for r in seg_results if r['total'] is not None],
            key=lambda r: r['total'],
        )
        rank_map: dict = {}
        rank = 1
        for i, r in enumerate(completed):
            if i > 0 and r['total'] > completed[i - 1]['total']:
                rank = i + 1
            rank_map[r['foursome'].pk] = rank

        for r in seg_results:
            saved.append(IrishRumbleSegmentResult(
                round           = round_obj,
                foursome        = r['foursome'],
                segment_index   = seg_idx,
                balls_counted   = r['balls'],
                total_net_score = r['total'],
                rank            = rank_map.get(r['foursome'].pk),
            ))

    IrishRumbleSegmentResult.objects.bulk_create(saved)
    return saved


def irish_rumble_summary(round_obj) -> dict:
    """
    Return a serialisable dict:
        {
          'handicap_mode': str,
          'net_percent'  : int,
          'entry_fee'    : float,
          'payouts'      : [{'place': int, 'amount': float}, ...],
          'pool'         : float,
          'segments'     : [
              {
                'label'  : "Holes 1-6 (best 1)",
                'results': [{'rank', 'group', 'score', 'net_to_par'}, ...]
              }, ...
          ],
          'overall': [
              {'rank', 'group', 'players', 'total_score', 'net_to_par',
               'current_hole', 'payout'}, ...
          ]
        }
    """
    try:
        config = round_obj.irish_rumble_config
    except IrishRumbleConfig.DoesNotExist:
        return {'configured': False, 'segments': [], 'overall': []}

    par_by_hole = _par_index_for_round(round_obj)

    results = (
        IrishRumbleSegmentResult.objects
        .filter(round=round_obj)
        .select_related('foursome')
        .order_by('segment_index', 'rank')
    )

    by_seg: dict = {}
    for r in results:
        by_seg.setdefault(r.segment_index, []).append(r)

    segments_out = []
    for seg_idx, seg in enumerate(config.segments):
        seg_results  = by_seg.get(seg_idx, [])
        holes_in_seg = list(range(seg['start_hole'], seg['end_hole'] + 1))
        seg_par      = sum(par_by_hole.get(h, 4) for h in holes_in_seg)
        label        = (
            f"Holes {seg['start_hole']}-{seg['end_hole']} "
            f"(best {seg['balls_to_count']})"
        )
        segments_out.append({
            'label'  : label,
            'results': [
                {
                    'rank'      : r.rank,
                    'group'     : r.foursome.display_name,
                    'score'     : r.total_net_score,
                    'net_to_par': (
                        r.total_net_score - seg_par
                        if r.total_net_score is not None else None
                    ),
                }
                for r in seg_results
            ],
        })

    # ── Overall: the shared group-vs-field board ─────────────────────────────
    # The running total, the tie rule and the pool split live in
    # `services.group_field` because Better Ball owes every one of them too,
    # and the thing two copies would eventually disagree about is money.
    #
    # The board is live from hole 1 — built from per-hole scores rather than
    # from completed segments, so a group ranks after one hole instead of six.
    from services.group_field import (balls_by_hole_from_segments, field_pool,
                                      group_standings)

    score_index = _build_ir_score_index(
        round_obj, config.handicap_mode, config.net_percent
    )
    pool         = field_pool(round_obj, config.entry_fee)
    payouts_list = config.payouts or []
    overall_out  = group_standings(
        round_obj,
        balls_by_hole = balls_by_hole_from_segments(config.segments),
        score_index   = score_index,
        par_by_hole   = par_by_hole,
        entry_fee     = config.entry_fee,
        payouts       = payouts_list,
        net_percent   = config.net_percent,
    )

    # Extract balls_to_count from first segment (all segments may differ, but
    # expose the dominant value so the UI can show e.g. "Best 2 of 4 count").
    balls_to_count = config.segments[0]['balls_to_count'] if config.segments else None

    return {
        'configured'   : True,
        'handicap_mode': config.handicap_mode,
        'net_percent'  : config.net_percent,
        'entry_fee'    : float(config.entry_fee),
        'payouts'      : payouts_list,
        'pool'         : pool,
        'balls_to_count': balls_to_count,
        'variant'      : config.variant,
        'segments'     : segments_out,
        'overall'      : overall_out,
    }
