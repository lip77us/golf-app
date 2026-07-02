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

from core.models import HandicapMode
from games.models import IrishRumbleConfig, IrishRumbleSegmentResult
from scoring.models import HoleScore
from scoring.handicap import _effective_hcp, _strokes_on_hole
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
    from tournament.models import FoursomeMembership
    from scoring.models import HoleScore
    from scoring.phantom import get_algorithm, CROSS_FOURSOME_ALGORITHM_ID
    from services.round_setup import _get_or_create_phantom

    if not IrishRumbleConfig.objects.filter(round=round_obj).exists():
        return 0

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

def _build_ir_score_index(round_obj, handicap_mode, net_percent):
    """
    Build {foursome_id: {player_id: {hole_number: capped_score}}} for all
    real players in the round.

    Applies the handicap adjustment.  The net-double-bogey cap (per-hole
    net par + 2) is only applied when the round's `net_max_double_bogey`
    flag is on.  For strokes_off mode, SO strokes are relative to the
    lowest playing_handicap across ALL foursomes in the round.
    """
    cap_enabled = bool(round_obj.net_max_double_bogey)
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
                eff = _effective_hcp(membership.playing_handicap, net_percent)
                adjusted = hs['gross_score'] - _strokes_on_hole(eff, si)

        else:  # STROKES_OFF
            if membership.tee_id is None:
                continue
            si       = membership.tee.hole(hole).get('stroke_index', 18)
            so       = max(0, membership.playing_handicap - low_hcp)
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
                    'group'     : f"Group {r.foursome.group_number}",
                    'score'     : r.total_net_score,
                    'net_to_par': (
                        r.total_net_score - seg_par
                        if r.total_net_score is not None else None
                    ),
                }
                for r in seg_results
            ],
        })

    # ── Overall: running totals built directly from per-hole scores ───────────
    # Correct Irish Rumble scoring:
    #   For each hole played, take the N best (lowest) net scores from the
    #   group (N = balls_to_count for that hole's segment).  Sum those across
    #   all holes played to get the running total.  net_to_par is compared
    #   against the par contribution for the same holes (balls × hole_par).
    #
    # This means the leaderboard is live from hole 1 — no need to wait for
    # a full segment to complete.

    foursomes = {fs.pk: fs for fs in Foursome.objects.filter(round=round_obj)}

    # player count per foursome (includes phantom)
    player_counts_dict = {
        fs.pk: fs.memberships.filter(player__is_phantom=False).count()
               + (1 if fs.has_phantom else 0)
        for fs in foursomes.values()
    }

    # hole → balls_to_count (from config segments)
    balls_by_hole: dict = {}
    for seg in config.segments:
        n = seg['balls_to_count']
        for h in range(seg['start_hole'], seg['end_hole'] + 1):
            balls_by_hole[h] = n

    # Build capped per-hole score index for the whole round
    score_index = _build_ir_score_index(
        round_obj, config.handicap_mode, config.net_percent
    )

    # Current (furthest) hole scored per foursome
    from django.db.models import Max
    hole_progress = {
        row['foursome_id']: row['max_hole']
        for row in (
            HoleScore.objects
            .filter(foursome__round=round_obj, player__is_phantom=False)
            .exclude(gross_score=None)
            .values('foursome_id')
            .annotate(max_hole=Max('hole_number'))
        )
    }

    # Compute running total for every foursome
    running: dict = {}  # fid → {'score': int, 'par': int}
    for fid in foursomes:
        fs_scores = score_index.get(fid, {})
        n_players = player_counts_dict.get(fid, 4)
        score_acc = 0
        par_acc   = 0
        has_any   = False
        for hole_num in range(1, 19):
            configured_n = balls_by_hole.get(hole_num, 1)
            balls        = min(configured_n, n_players)
            scores_on_hole = sorted([
                ph[hole_num]
                for ph in fs_scores.values()
                if hole_num in ph
            ])
            if not scores_on_hole:
                continue  # not yet scored
            score_acc += sum(scores_on_hole[:balls])
            par_acc   += par_by_hole.get(hole_num, 4) * balls
            has_any    = True
        if has_any:
            running[fid] = {'score': score_acc, 'par': par_acc}

    # Payout: entry_fee × num_players pool; split per explicit payouts list.
    from tournament.models import FoursomeMembership
    num_players  = FoursomeMembership.objects.filter(
                       foursome__round=round_obj, player__is_phantom=False
                   ).count()
    pool         = round(float(config.entry_fee) * num_players, 2)
    payouts_list = config.payouts or []
    payouts_dict = {int(p['place']): float(p['amount']) for p in payouts_list}

    # Sort: teams with scores first (lowest net-to-par wins), then unstarted
    def _ntp(fid):
        if fid not in running:
            return None
        r = running[fid]
        return r['score'] - r['par']

    scored   = sorted(
        [fid for fid in foursomes if fid in running],
        key=lambda fid: _ntp(fid),
    )
    unscored = [fid for fid in foursomes if fid not in running]

    rank = 1
    ranked_rows = []
    for i, fid in enumerate(scored):
        if i > 0 and _ntp(fid) > _ntp(scored[i - 1]):
            rank = i + 1
        ranked_rows.append({'foursome_id': fid, 'rank': rank})
    for fid in unscored:
        ranked_rows.append({'foursome_id': fid, 'rank': None})

    # Count groups at each paid rank so we can split tied payouts.
    count_at_rank = {}
    for row in ranked_rows:
        r = row['rank']
        if r is not None and r in payouts_dict:
            count_at_rank[r] = count_at_rank.get(r, 0) + 1

    def _payout_for(rank):
        if rank is None or rank not in payouts_dict:
            return 0.0
        n = count_at_rank.get(rank, 1)
        return round(payouts_dict[rank] / n, 2)

    overall_out = []
    for row in ranked_rows:
        fid      = row['foursome_id']
        fs       = foursomes[fid]
        r        = running.get(fid)
        ntp      = (r['score'] - r['par']) if r else None
        n_players = player_counts_dict.get(fid, 4)
        real_members = list(
            fs.memberships.filter(player__is_phantom=False)
                          .select_related('player')
                          .order_by('player__name')
        )
        players      = ', '.join(m.player.name for m in real_members)
        short_names  = ' / '.join(m.player.short_name or m.player.name
                                  for m in real_members)
        group_payout = _payout_for(row['rank'])
        # Borrowed-4th donor status (which donor feeds each hole + whether they
        # have posted yet → the "provisional total" lag).  None for full groups
        # and legacy intra-foursome phantoms.
        phantom_info = None
        if fs.has_phantom:
            from scoring.phantom import build_phantom_info
            phantom_info = build_phantom_info(fs, config.net_percent)

        # "Thru" — for a leveled threesome the borrowed-4th lags, so a hole
        # isn't complete until its donor has also posted.  Cap "thru" at the
        # last hole (contiguous from 1) where the phantom has a score too;
        # otherwise a group shows "thru 2" while still waiting on hole 2.
        current_hole = hole_progress.get(fid)
        if fs.has_phantom and current_hole:
            fs_scores  = score_index.get(fid, {})
            real_pids  = {m.player_id for m in real_members}
            phantom_scores = next(
                (h for pid, h in fs_scores.items() if pid not in real_pids), {}
            )
            complete_thru = 0
            for h in range(1, current_hole + 1):
                if h in phantom_scores:
                    complete_thru = h
                else:
                    break
            current_hole = complete_thru or None

        overall_out.append({
            'rank'             : row['rank'],
            'foursome_id'      : fid,
            'group'            : f"Group {fs.group_number}",
            'players'          : players,
            'short_names'      : short_names,
            'n_players'        : n_players,
            'has_phantom'      : fs.has_phantom,
            'phantom'          : phantom_info,
            'total_score'      : r['score'] if r else None,
            'net_to_par'       : ntp,
            'current_hole'     : current_hole,
            'payout'           : group_payout,
            'per_person_payout': round(group_payout / n_players, 2) if n_players else 0.0,
        })

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
