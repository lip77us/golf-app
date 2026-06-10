"""
api/watch_views.py
------------------
Public, unauthenticated read-only views that render an HTML leaderboard
page for spectators who don't have the app installed.  Linked from the
mobile app's "Share Watch Link" button.

Tokens live on Round (watch_token).  No auth, no CSRF, no JSON — just a
plain HTML page with a `<meta http-equiv="refresh">` so the spectator's
browser polls every 30s without any JavaScript.

A single token serves several views; the active view is chosen via the
`?view=` query string:
    matches  (default) — per-foursome cup match cards (Four Ball, Singles
                         Nassau, Singles 18, Irish Rumble).
    low_net            — Low Net championship standings.
    cup                — Tournament-wide cup point standings.

Tabs that have no data for the round/tournament are hidden.
"""
from __future__ import annotations

from django.http       import Http404
from django.shortcuts  import render

from tournament.models import Round


# ---------------------------------------------------------------------------
# Display-string helpers (cup matches view)
# ---------------------------------------------------------------------------

def _holes_up_text(margin: int, holes: int, t1: str, t2: str) -> str:
    """'Team1 2 UP thru 5' / 'AS thru 5' / 'Not started'."""
    if holes <= 0:
        return 'Not started'
    if margin == 0:
        return f'AS thru {holes}'
    leader = t1 if margin > 0 else t2
    return f'{leader} {abs(margin)} UP thru {holes}'


def _final_text(margin: int, t1: str, t2: str) -> str:
    """'Team1 2 UP' / 'Halved' for a resolved match."""
    if margin == 0:
        return 'Halved'
    winner = t1 if margin > 0 else t2
    return f'{winner} {abs(margin)} UP'


def _leader_from_margin(margin: int, result) -> str:
    """Which team's color should the display text wear?
    Returns 'team1' / 'team2' / '' (neutral: halved / AS / not started)."""
    if result == 'team1': return 'team1'
    if result == 'team2': return 'team2'
    if result == 'halved': return ''
    if margin > 0: return 'team1'
    if margin < 0: return 'team2'
    return ''


def _short_chip(margin: int, holes: int, result, seg_len: int = 18) -> str:
    """Compact chip text: '2&1' / '2 UP' / 'Halved' / 'AS thru 5' / 'Not started'.

    Used in the team-aligned cells; no player/team name (the chip already
    sits on the leading team's side).  `seg_len` is the number of holes
    in the segment (9 for Front/Back, 18 for Overall / Singles 18); when
    a segment is mathematically locked (|margin| > holes_left) we use
    the match-play "M&R" notation instead of "M UP"."""
    if result == 'halved':
        return 'Halved'
    abs_m      = abs(margin)
    holes_left = seg_len - holes if holes else seg_len
    if result in ('team1', 'team2'):
        if holes and holes < seg_len and abs_m > holes_left:
            return f'{abs_m}&{holes_left}'
        return f'{abs_m} UP' if abs_m else 'Halved'
    # in progress
    if holes <= 0:
        return ''
    if margin == 0:
        return f'AS thru {holes}'
    if holes_left > 0 and abs_m > holes_left:
        # Mathematically locked — treat as decided.
        return f'{abs_m}&{holes_left}'
    return f'{abs_m} UP'


def _seg_len(label: str) -> int:
    """Map a segment label to its hole count."""
    return 9 if label in ('Front 9', 'Back 9') else 18


# Glyph appended to resolved "M UP" wins so the spectator can tell a
# completed 1 UP win apart from an in-progress 1 UP lead.  "M&R"
# notation already implies the match is over, so it doesn't get the
# check; neither does a halved final (its own label is unambiguous).
_WIN_TICK = ' ✓'


def _resolved_or_short(result, margin, holes, seg_len,
                       decided_margin=None, decided_remaining=None) -> str:
    """Chip text for a Nassau-style segment.

    Prefers `decided_margin` / `decided_remaining` (set by nassau_summary
    at the moment the segment was locked) so "2&1" survives even when
    the players keep scoring past the decision hole.  Falls back to the
    live margin/holes view for in-progress sides."""
    if result == 'halved':
        return 'Halved'
    if result in ('team1', 'team2'):
        if decided_margin and decided_remaining and decided_remaining > 0:
            return f'{abs(decided_margin)}&{decided_remaining}'
        if margin:
            return f'{abs(margin)} UP{_WIN_TICK}'
        return 'Halved'
    return _short_chip(margin, holes, result, seg_len)


def _is_resolved(margin: int, holes: int, result, seg_len: int) -> bool:
    """True when this side has been decided — either the backend set a
    result OR the running margin is mathematically locked.  Used by the
    Cup tab to hide sides that have already rolled into the big score."""
    if result is not None:
        return True
    if holes <= 0:
        return False
    return abs(margin) > (seg_len - holes)


_TEAM_PALETTE = {
    # name → (fg/strong hex, bg/tint hex).  Matches the mobile app's
    # resolveTripleCupTeamColor() so the watch page reads the same as
    # what foursome members see in-app.  The tint is hand-picked at
    # roughly Material 50 weight for readable chip backgrounds.
    'red':    ('#B71C1C', '#FFEBEE'),
    'blue':   ('#0D47A1', '#E3F2FD'),
    'green':  ('#1B5E20', '#E8F5E9'),
    'gold':   ('#F57F17', '#FFF8E1'),
    'yellow': ('#F57F17', '#FFF8E1'),
    'orange': ('#E65100', '#FFF3E0'),
    'purple': ('#4A148C', '#F3E5F5'),
    'black':  ('#212121', '#F5F5F5'),
    'white':  ('#424242', '#FAFAFA'),
}

def _team_palette(colour_name, fallback_fg: str, fallback_bg: str) -> dict:
    """Resolve a cup TournamentTeam.colour string ("Green", "Purple",
    …) to {fg, bg} hex codes for CSS.  Returns the fallback when the
    name is empty or unknown — keeps casual rounds (no cup team) on
    the page's default orange/blue scheme."""
    name = (colour_name or '').strip().lower()
    fg, bg = _TEAM_PALETTE.get(name, (fallback_fg, fallback_bg))
    return {'fg': fg, 'bg': bg}


def _attach_team_palettes(summary: dict) -> None:
    """Populate summary['team1_palette'] / ['team2_palette'] from the
    summary's colour-name strings.  Called by every cup view that
    renders chips so the template can pull hex codes via CSS vars."""
    summary['team1_palette'] = _team_palette(
        summary.get('team1_colour'), '#b25400', '#fff1e1')
    summary['team2_palette'] = _team_palette(
        summary.get('team2_colour'), '#1a3a8e', '#e7ecf6')


def _seg_pts_from_result(result, pv: float) -> tuple[float, float]:
    """Per-segment points from a cup result code."""
    if result == 'team1': return pv, 0.0
    if result == 'team2': return 0.0, pv
    if result == 'halved': return pv / 2, pv / 2
    return 0.0, 0.0


def _enrich_summary(summary: dict) -> None:
    """Walk every segment / individual match and attach a `display` string
    plus `display_team` ('team1'/'team2'/'') so the template can color the
    live-progress text in the leading team's colour.

    For Singles Nassau, also expand each individual match into three
    F9 / B9 / All sub-rows (`sub_segments`) so the template can render
    them like Four Ball's segment rows."""
    t1 = summary.get('team1_name') or 'Team 1'
    t2 = summary.get('team2_name') or 'Team 2'

    max_holes_overall = 0
    for match in summary.get('matches', []):
        gtype = match.get('game_type', '')
        pv    = float(match.get('point_value') or 0)
        max_holes_in_match = 0

        for seg in match.get('segments', []):
            result = seg.get('result')

            if gtype == 'irish_rumble':
                def _vp(n):
                    if n is None:
                        return ''
                    if n == 0:
                        return 'E'
                    return f'+{n}' if n > 0 else f'{n}'
                a_vs_n = seg.get('a_vs_par')
                b_vs_n = seg.get('b_vs_par')
                a_vs = _vp(a_vs_n)
                b_vs = _vp(b_vs_n)
                a_h  = seg.get('a_holes_played') or 0
                b_h  = seg.get('b_holes_played') or 0
                if result is not None:
                    a_score = seg.get('a_score')
                    b_score = seg.get('b_score')
                    if a_score is not None and b_score is not None:
                        seg['display'] = f'{t1} {a_score} ({a_vs}) — {t2} {b_score} ({b_vs})'
                    else:
                        seg['display'] = 'Final'
                    seg['display_team'] = result if result in ('team1', 'team2') else ''
                elif a_h == 0 and b_h == 0:
                    seg['display']      = 'Not started'
                    seg['display_team'] = ''
                else:
                    seg['display'] = (
                        f'{t1} {a_vs} thru {a_h}  ·  {t2} {b_vs} thru {b_h}'
                    )
                    if a_vs_n is None or b_vs_n is None:
                        seg['display_team'] = ''
                    elif a_vs_n < b_vs_n:
                        seg['display_team'] = 'team1'
                    elif b_vs_n < a_vs_n:
                        seg['display_team'] = 'team2'
                    else:
                        seg['display_team'] = ''
                seg['resolved'] = result is not None
                if max(a_h, b_h) > max_holes_in_match:
                    max_holes_in_match = max(a_h, b_h)
                continue

            margin  = seg.get('margin') or 0
            holes   = seg.get('holes_played') or 0
            seg_len = _seg_len(seg.get('label') or '')
            dec_m   = seg.get('decided_margin')
            dec_r   = seg.get('decided_remaining')
            if result is None:
                seg['display'] = _holes_up_text(margin, holes, t1, t2)
            else:
                seg['display'] = _final_text(margin, t1, t2)
            seg['display_team']  = _leader_from_margin(margin, result)
            seg['short_display'] = _resolved_or_short(
                result, margin, holes, seg_len, dec_m, dec_r,
            )
            seg['resolved']      = _is_resolved(margin, holes, result, seg_len)
            if holes > max_holes_in_match: max_holes_in_match = holes

        for im in match.get('individual_matches', []):
            result      = im.get('result')
            margin      = im.get('overall_holes_up') or 0
            holes       = im.get('holes_played')     or 0
            finished_on = im.get('finished_on_hole')
            p1          = im.get('player1') or '?'
            p2          = im.get('player2') or '?'
            if result is None:
                im['display'] = _holes_up_text(margin, holes, p1, p2)
            else:
                im['display'] = _final_text(margin, p1, p2)
            im['display_team'] = _leader_from_margin(margin, result)
            # Singles 18 is an 18-hole match; honour finished_on_hole so
            # "won on 17" reads "M&1" rather than "M UP".  Resolved
            # matches that go to the 18th green pick up the win-tick so
            # they're distinguishable from an in-progress 1 UP lead.
            if result in ('team1', 'team2') and finished_on and finished_on < 18:
                im['short_display'] = f'{abs(margin)}&{18 - finished_on}'
            elif result in ('team1', 'team2'):
                im['short_display'] = (
                    f'{abs(margin)} UP{_WIN_TICK}' if margin else 'Halved'
                )
            else:
                im['short_display'] = _short_chip(margin, holes, result, 18)
            im['resolved']   = _is_resolved(margin, holes, result, 18)
            im['thru_label'] = f'thru {holes}' if holes > 0 else 'not started'
            # Compact live status for the Triple Cup expansion: "1 UP
            # thru 3" / "AS thru 2" — was just "thru 3", which left
            # spectators unable to tell who was winning without doing
            # the math.  Resolved matches use the chip elsewhere; this
            # only fires for in-progress (holes > 0 and result null).
            if holes > 0 and result is None:
                if abs(margin) == 0:
                    im['live_status_label'] = f'AS thru {holes}'
                else:
                    im['live_status_label'] = f'{abs(margin)} UP thru {holes}'
            else:
                im['live_status_label'] = im['thru_label']
            if holes > max_holes_in_match: max_holes_in_match = holes

            # Singles Nassau awards points per F9/B9/All segment.  Expand
            # those sub-matches into three rows the template can render.
            if gtype == 'singles_nassau':
                im['sub_segments'] = _build_singles_nassau_subsegments(
                    im, pv, p1, p2, holes,
                )
                # A singles-nassau matchup is "resolved" only when all
                # three of its sub-segments are decided.
                im['resolved'] = all(
                    s['resolved'] for s in im['sub_segments']
                )

        # Triple Cup foursome-level live status: combine the
        # in-progress sub-matches' "1 UP thru 3" / "AS thru 2" labels
        # so the watch page's foursome summary shows the same one-liner
        # the mobile leaderboard does — no need to expand to see who's
        # winning.  Each entry carries its leader team ('team1' /
        # 'team2' / '') so the template can colour each piece in the
        # right hue.  Skips resolved (already in the rollup score) and
        # pending matches (nothing meaningful to show).
        if gtype == 'triple_cup':
            live_bits = []
            for im in match.get('individual_matches', []) or []:
                played = im.get('holes_played') or 0
                if played == 0 or im.get('result') is not None:
                    continue
                margin = im.get('overall_holes_up') or 0
                if abs(margin) == 0:
                    text = f'AS thru {played}'
                    leader = ''
                else:
                    text = f'{abs(margin)} UP thru {played}'
                    leader = 'team1' if margin > 0 else 'team2'
                live_bits.append({'text': text, 'leader': leader})
            match['tc_live_bits'] = live_bits

    # Per-match aggregate "thru" label (max across segments/matchups).
        match['thru_label'] = (
            f'Thru {max_holes_in_match}' if max_holes_in_match > 0 else 'Not started'
        )
        if max_holes_in_match > max_holes_overall:
            max_holes_overall = max_holes_in_match
    summary['max_holes_overall'] = max_holes_overall


def _mp_to_cup(result):
    """Map raw _compute_sub_match result ('player1'/'player2'/'halved'/None)
    to cup-relative ('team1'/'team2'/'halved'/None).  Player1 is always
    team1 in Singles match play."""
    if result == 'player1': return 'team1'
    if result == 'player2': return 'team2'
    return result


def _build_singles_nassau_subsegments(
    im: dict, pv: float, p1: str, p2: str, overall_holes: int,
) -> list:
    """Three rows: Front 9 / Back 9 / Overall for one Singles Nassau match.

    `f9_result`/`b9_result` on the match dict come straight from
    `_compute_sub_match` as raw match-play codes; map them to cup codes
    here.  `result` (overall) is already cup-mapped upstream."""
    rows = []
    specs = [
        ('Front 9', _mp_to_cup(im.get('f9_result')),
                    im.get('f9_holes_up') or 0,
                    im.get('f9_finished_on_hole')),
        ('Back 9',  _mp_to_cup(im.get('b9_result')),
                    im.get('b9_holes_up') or 0,
                    im.get('b9_finished_on_hole')),
        ('Overall', im.get('result'),
                    im.get('overall_holes_up') or 0,
                    im.get('finished_on_hole')),
    ]
    for label, result, holes_up, finished_on in specs:
        seg_len = _seg_len(label)
        # `sub_holes` is the number of holes played WITHIN the segment.
        # For Back 9 we want a count in the range 0–9 once hole 10 lands.
        if label == 'Front 9':
            sub_holes = min(overall_holes, 9)
        elif label == 'Back 9':
            sub_holes = max(0, overall_holes - 9)
        else:
            sub_holes = overall_holes

        if result is None:
            display = _holes_up_text(holes_up, sub_holes, p1, p2)
        else:
            display = _final_text(holes_up, p1, p2)

        # If the segment finished early, prefer the actual M&R from
        # finished_on_hole; otherwise fall back to margin-vs-holes-played.
        # Resolved-at-the-final-hole wins pick up the check tick so
        # they don't read identically to an in-progress lead.
        if result in ('team1', 'team2') and finished_on:
            seg_end_hole = 9 if label == 'Front 9' else 18
            rem = max(0, seg_end_hole - finished_on)
            if rem > 0:
                short = f'{abs(holes_up)}&{rem}'
            else:
                short = f'{abs(holes_up)} UP{_WIN_TICK}' if holes_up else 'Halved'
        elif result in ('team1', 'team2'):
            short = f'{abs(holes_up)} UP{_WIN_TICK}' if holes_up else 'Halved'
        else:
            short = _short_chip(holes_up, sub_holes, result, seg_len)

        t1p, t2p = _seg_pts_from_result(result, pv)
        rows.append({
            'label'        : label,
            'result'       : result,
            'display'      : display,
            'display_team' : _leader_from_margin(holes_up, result),
            'short_display': short,
            'resolved'     : _is_resolved(holes_up, sub_holes, result, seg_len),
            't1_pts'       : t1p,
            't2_pts'       : t2p,
        })
    return rows


# ---------------------------------------------------------------------------
# Cup-tab match filtering
# ---------------------------------------------------------------------------

def _filter_pending_matches(matches: list) -> list:
    """For the Cup tab: keep only matches with at least one unresolved
    side, and within each kept match drop the sides that are already in
    the big score.  Mirrors the mobile leaderboard's "Live Now" section
    which hides whole-match-resolved cards entirely.

    Returns a new list of shallow-copied match dicts with filtered
    `segments` / `individual_matches`.  The input is not mutated."""
    pending = []
    for m in matches:
        segs = [s for s in m.get('segments', []) if not s.get('resolved')]
        ims  = []
        for im in m.get('individual_matches', []):
            if im.get('sub_segments'):
                subs = [s for s in im['sub_segments'] if not s.get('resolved')]
                if subs:
                    new_im = dict(im)
                    new_im['sub_segments'] = subs
                    ims.append(new_im)
            elif not im.get('resolved'):
                ims.append(im)
        if segs or ims:
            new_m = dict(m)
            new_m['segments']           = segs
            new_m['individual_matches'] = ims
            pending.append(new_m)
    return pending


def _filter_completed_matches(matches: list) -> list:
    """For the Cup tab: keep only matches where every segment AND every
    individual match (or its sub_segments) is fully resolved.  Used to
    expose the final state of finished foursomes on the standings page,
    since the per-group detail otherwise has nowhere else to live."""
    completed = []
    for m in matches:
        segs = m.get('segments') or []
        ims  = m.get('individual_matches') or []
        if not segs and not ims:
            continue
        all_segs_done = all(s.get('resolved') for s in segs)
        all_ims_done = True
        for im in ims:
            if im.get('sub_segments'):
                if not all(s.get('resolved') for s in im['sub_segments']):
                    all_ims_done = False
                    break
            elif not im.get('resolved'):
                all_ims_done = False
                break
        if all_segs_done and all_ims_done:
            completed.append(m)
    return completed


# ---------------------------------------------------------------------------
# Tab discovery
# ---------------------------------------------------------------------------

def _has_cup_matches(round_obj) -> bool:
    return hasattr(round_obj, 'ryder_cup_config')

def _has_cup_four_ball(round_obj) -> bool:
    """True when the cup round contains at least one Four Ball (Nassau)
    foursome — drives the dedicated Four Ball tab."""
    try:
        rc = round_obj.ryder_cup_config
    except Exception:
        return False
    from core.models import GameType
    return rc.foursome_configs.filter(game_type=GameType.NASSAU).exists()


def _cup_has_non_four_ball_matches(round_obj) -> bool:
    """True when the cup has match types beyond Nassau Four Ball —
    Singles, Quota Nassau, Irish Rumble pairings, etc.  Used to
    decide whether the generic Matches tab is worth showing; when
    every cup match is Four Ball the dedicated Four Ball tab is a
    strict superset and Matches becomes redundant."""
    try:
        rc = round_obj.ryder_cup_config
    except Exception:
        return False
    from core.models import GameType
    if rc.foursome_configs.exclude(game_type=GameType.NASSAU).exists():
        return True
    try:
        if rc.irish_rumble_pairings.exists():
            return True
    except Exception:
        pass
    return False

def _has_cup_standings(round_obj) -> bool:
    """True when the tournament has a cup (team) competition configured."""
    tourney = round_obj.tournament
    return bool(tourney and hasattr(tourney, 'team_tournament'))

def _is_casual_round(round_obj) -> bool:
    """A round with no cup overlay — players just signed up for a few
    side games (Skins, Multi-Skins, Sixes, …)."""
    return not _has_cup_matches(round_obj) and not _has_cup_standings(round_obj)

def _has_casual_skins(round_obj) -> bool:
    return 'skins' in (round_obj.active_games or [])

def _has_casual_stableford(round_obj) -> bool:
    return 'stableford' in (round_obj.active_games or [])

def _has_stableford_championship(round_obj) -> bool:
    """Tournament-wide Stableford — total points across every round."""
    t = round_obj.tournament
    if not t:
        return False
    return ('stableford_championship' in (t.active_games or [])
            or hasattr(t, 'stableford_championship_config'))

def _has_casual_multi_skins(round_obj) -> bool:
    return 'multi_skins' in (round_obj.active_games or [])

def _has_casual_points_531(round_obj) -> bool:
    return 'points_531' in (round_obj.active_games or [])

def _has_casual_nassau(round_obj) -> bool:
    return 'nassau' in (round_obj.active_games or [])

def _has_casual_wolf(round_obj) -> bool:
    return 'wolf' in (round_obj.active_games or [])

def _render_casual_wolf(request, round_obj, token: str, tabs: list):
    """Wolf — summary points standings (per player) for spectators; the
    hole-by-hole wolf decisions live in the app."""
    from services.wolf import wolf_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        s = wolf_summary(fs)
        if not s:
            continue
        groups.append({'group_number': fs.group_number, 'summary': s})
    return render(request, 'watch/casual_wolf.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'thru':         _round_thru(round_obj),
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })

def _has_casual_triple_cup(round_obj) -> bool:
    """Casual One-Round Triple Cup (round-level active game)."""
    return 'triple_cup' in (round_obj.active_games or [])


def _tc_match_status(m: dict):
    """Live match score for a Triple Cup match — mirrors the mobile
    TripleCupMatch.statusDisplay ("AS thru 3", "2 UP thru 5", "3 & 2",
    "Halved").  Returns (text, leader) where leader is 'team1'|'team2'|''."""
    t1 = (m.get('team1') or {}).get('shorts') or []
    t2 = (m.get('team2') or {}).get('shorts') or []
    if not t1 or not t2:
        return ('Pending', '')
    holes = m.get('holes') or []
    if not holes:
        return ('—', '')
    played = len(holes)
    margin = holes[-1].get('margin') or 0
    abs_m  = abs(margin)
    total  = (m.get('end_hole') or 0) - (m.get('start_hole') or 0) + 1
    left   = max(total - played, 0)
    status = m.get('status')
    result = m.get('result')
    margin_leader = 'team1' if margin > 0 else 'team2' if margin < 0 else ''
    if status in ('complete', 'halved') or result:
        if result == 'halved':
            return ('Halved', '')
        leader = result if result in ('team1', 'team2') else margin_leader
        if left > 0:
            return (f'{abs_m} & {left}', leader)
        return (f'{abs_m} UP', leader) if abs_m else ('Halved', '')
    if status == 'in_progress':
        if margin == 0:
            return (f'AS thru {played}', '')
        return (f'{abs_m} UP thru {played}', margin_leader)
    return ('—', '')


def _render_casual_triple_cup(request, round_obj, token: str, tabs: list):
    """Triple Cup OVERVIEW — the cup scoreboard (team points, W/W/H, rosters)
    for spectators; the match-by-match detail + hole scoring live in the app."""
    from services.triple_cup import triple_cup_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        s = triple_cup_summary(fs)
        if not s:
            continue
        overall = s.get('overall', {})
        # One box per match with its live score as it progresses.
        matches = []
        for m in s.get('matches', []):
            status_text, leader = _tc_match_status(m)
            matches.append({
                'label'    : m.get('label', ''),
                't1_names' : ' & '.join((m.get('team1') or {}).get('shorts') or []),
                't2_names' : ' & '.join((m.get('team2') or {}).get('shorts') or []),
                'status'   : status_text,
                'leader'   : leader,   # 'team1' | 'team2' | ''
            })
        groups.append({
            'group_number': fs.group_number,
            't1_name'   : (s.get('team1_name') or 'Blue'),
            't2_name'   : (s.get('team2_name') or 'Orange'),
            't1_points' : overall.get('team1_points', 0),
            't2_points' : overall.get('team2_points', 0),
            'possible'  : overall.get('points_available', 0),
            't1_wins'   : overall.get('team1_wins', 0),
            't2_wins'   : overall.get('team2_wins', 0),
            'halves'    : overall.get('halves', 0),
            'matches'   : matches,
        })
    return render(request, 'watch/casual_triple_cup.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'thru':         _round_thru(round_obj),
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _nassau_is_match(round_obj) -> bool:
    """True when the casual Nassau is Overall-only — a straight 18-hole match."""
    from games.models import NassauGame
    g = NassauGame.objects.filter(foursome__round=round_obj).first()
    return bool(g and not g.play_front and not g.play_back and g.play_overall)

def _has_casual_match_play(round_obj) -> bool:
    """A non-cup match-play bracket (single-elim or three-player) on any
    foursome. (Cup match play renders under the cup's Matches/Four Ball tabs.)"""
    from games.models import MatchPlayBracket
    return MatchPlayBracket.objects.filter(
        foursome__round=round_obj,
        bracket_type__in=['single_elim', 'three_player_points'],
    ).exists()


def _match_play_watch_row(m: dict, r1_done: bool, bracket_type: str) -> dict:
    """Display row for one match — label, the two players, and the status text
    ("Name 2 UP thru 5" / "Name 3 UP" / "Halved" / "Not started")."""
    label  = m.get('label', '')
    p1, p2 = m.get('player1', 'Player 1'), m.get('player2', 'Player 2')

    # Final / 3rd-place carry placeholder players until both semis resolve —
    # show the matchup as TBD rather than the seed-order stand-ins.
    if (m.get('round') == 2 and not r1_done
            and bracket_type == 'single_elim'):
        if label == 'Final':
            p1, p2 = 'Semi 1 Winner', 'Semi 2 Winner'
        else:
            p1, p2 = 'Semi 1 Loser', 'Semi 2 Loser'
        return {'label': label, 'p1': p1, 'p2': p2, 'text': 'TBD', 'leader': ''}

    holes  = m.get('holes', [])
    thru   = len(holes)
    margin = holes[-1]['margin'] if holes else 0          # + = player1 up
    result = m.get('result')
    if thru == 0:
        text, leader = 'Not started', ''
    elif result is not None:
        text   = _final_text(margin, p1, p2)
        leader = _leader_from_margin(margin, result)
    else:
        text   = _holes_up_text(margin, thru, p1, p2)
        leader = _leader_from_margin(margin, None)
    # Map team1/team2 → player1/player2 for colouring.
    leader = {'team1': 'p1', 'team2': 'p2'}.get(leader, '')
    return {'label': label, 'p1': p1, 'p2': p2, 'text': text, 'leader': leader}


def _render_casual_match_play(request, round_obj, token: str, tabs: list):
    """Match Play — summary-only spectator view: each match's players + status
    score. The hole-by-hole detail lives in the app."""
    from services.match_play import match_play_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        s = match_play_summary(fs)
        if not s or s.get('bracket_type') not in (
                'single_elim', 'three_player_points'):
            continue
        matches = s.get('matches', [])
        r1 = [m for m in matches if m.get('round') == 1]
        r1_done = bool(r1) and all(m.get('result') is not None for m in r1)
        btype = s.get('bracket_type')
        groups.append({
            'group_number': fs.group_number,
            'winner'      : s.get('winner'),
            'matches'     : [_match_play_watch_row(m, r1_done, btype)
                             for m in matches],
        })
    return render(request, 'watch/casual_match_play.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'thru':         _round_thru(round_obj),
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _round_thru(round_obj) -> int:
    """Highest hole number scored anywhere in the round — a round-level 'thru'
    for the spectator sub-line. Game-agnostic: read straight from HoleScore so
    it works on every casual page regardless of the game summary's shape."""
    from django.db.models import Max
    from scoring.models import HoleScore
    return HoleScore.objects.filter(
        foursome__round=round_obj, gross_score__gt=0
    ).aggregate(m=Max('hole_number'))['m'] or 0

def _has_casual_sixes(round_obj) -> bool:
    return 'sixes' in (round_obj.active_games or [])

def _has_casual_pink_ball(round_obj) -> bool:
    return 'pink_ball' in (round_obj.active_games or [])

def _has_casual_irish_rumble(round_obj) -> bool:
    """Irish Rumble as a casual / tournament side game (not a cup
    match — cup IR is rendered inside Matches/Four Ball)."""
    if _has_cup_matches(round_obj):
        return False
    return 'irish_rumble' in (round_obj.active_games or [])

def _has_low_net_championship(round_obj) -> bool:
    """Tournament-wide Low Net (a.k.a. Stroke Play in the in-app
    leaderboard) — aggregates across every round in the tournament."""
    t = round_obj.tournament
    if not t:
        return False
    if 'low_net' in (t.active_games or []):
        return True
    return hasattr(t, 'low_net_championship_config')

def _has_low_net_round(round_obj) -> bool:
    """Round-only Low Net.  Two paths:
      * explicit round-level Low Net (active_games or low_net_config), or
      * casual fallback — every casual round gets a "Low Net" tab that
        doubles as the spectator scorecard view.

    Tournament rounds with championship Low Net only (no round-level
    competition) intentionally don't show this tab; the Stroke Play
    tab covers that case and the spectator would otherwise see two
    near-identical leaderboards."""
    if 'low_net_round' in (round_obj.active_games or []):
        return True
    if hasattr(round_obj, 'low_net_config'):
        return True
    # Triple Cup is alternate-shot through the middle six holes — a round-wide
    # stroke-play / low-net board is meaningless, so suppress the casual
    # fallback Stroke Play tab for it.
    if 'triple_cup' in (round_obj.active_games or []):
        return False
    if _is_casual_round(round_obj):
        return True
    return False

def _has_low_net(round_obj) -> bool:
    """Backward-compat union — True when either Low-Net tab applies."""
    return _has_low_net_championship(round_obj) or _has_low_net_round(round_obj)

def _stroke_play_label(round_obj) -> str:
    """Tab label for the championship Low Net (Stroke Play) tab.

    * Cup tournaments → "Low Net".  Using tournament.name here would
      collide with the cup-standings tab (which already uses
      team_tournament.cup_name) — both would read "ETC Cup".
    * Non-cup tournaments → tournament.name, so a stroke-play
      championship reads e.g. "Pacific Grove Open".
    * Fallback → "Stroke Play"."""
    if _has_cup_matches(round_obj):
        return 'Stroke Play'
    t = round_obj.tournament
    return (t.name if t and t.name else 'Stroke Play')

def _red_ball_label(round_obj) -> str:
    """Tab label for the Pink/Red Ball tab — picks up the configured
    ball colour (e.g. "Red Ball" for a red-ball game, "Pink Ball"
    when the colour is left at the default)."""
    try:
        colour = round_obj.pink_ball_config.ball_color
        if colour:
            return f'{colour} Ball'
    except Exception:
        pass
    return 'Pink Ball'

def _cup_name(round_obj) -> str:
    """Display name for the cup tab — 'Ryder Cup' / 'ETC Cup' / etc."""
    tourney = round_obj.tournament
    if tourney and hasattr(tourney, 'team_tournament'):
        return tourney.team_tournament.cup_name or 'Cup'
    return 'Cup'

def _build_tabs(round_obj, token: str, current: str) -> list:
    """Returns [{key, label, url, active}] for tabs that have data.

    Order: cup-Matches, casual-game tabs, Low Net, cup standings.  The
    first entry becomes the default landing tab when no `?view=` is
    supplied — for cup rounds that's Matches, for casual rounds it's
    the most prominent game (Multi-Skins or Skins).  Pure Low-Net
    rounds collapse to a single Low Net tab."""
    base = f'/watch/{token}/'
    tabs = []
    # Matches tab only when the cup has non-Four-Ball match types
    # (Singles, Quota Nassau, IR pairings).  An all-Four-Ball cup
    # round has its content fully rendered by the Four Ball tab, so
    # Matches would just duplicate the chip rows.
    if _has_cup_matches(round_obj) and _cup_has_non_four_ball_matches(round_obj):
        tabs.append({
            'key': 'matches', 'label': 'Matches',
            'url': base, 'active': current == 'matches',
        })
    if _has_cup_four_ball(round_obj):
        tabs.append({
            'key': 'four_ball', 'label': 'Four Ball',
            'url': f'{base}?view=four_ball',
            'active': current == 'four_ball',
        })
    if _has_casual_multi_skins(round_obj):
        tabs.append({
            'key': 'multi_skins', 'label': 'Multi-Skins',
            'url': f'{base}?view=multi_skins',
            'active': current == 'multi_skins',
        })
    if _has_casual_skins(round_obj):
        tabs.append({
            'key': 'skins', 'label': 'Skins',
            'url': f'{base}?view=skins',
            'active': current == 'skins',
        })
    if _has_casual_stableford(round_obj):
        tabs.append({
            'key': 'stableford', 'label': 'Stableford',
            'url': f'{base}?view=stableford',
            'active': current == 'stableford',
        })
    if _has_casual_points_531(round_obj):
        tabs.append({
            'key': 'points_531', 'label': 'Points 5-3-1',
            'url': f'{base}?view=points_531',
            'active': current == 'points_531',
        })
    if _has_casual_nassau(round_obj):
        tabs.append({
            'key': 'nassau',
            'label': '18-Hole Match' if _nassau_is_match(round_obj) else 'Nassau',
            'url': f'{base}?view=nassau',
            'active': current == 'nassau',
        })
    if _has_casual_triple_cup(round_obj):
        tabs.append({
            'key': 'triple_cup', 'label': 'Triple Cup',
            'url': f'{base}?view=triple_cup',
            'active': current == 'triple_cup',
        })
    if _has_casual_wolf(round_obj):
        tabs.append({
            'key': 'wolf', 'label': 'Wolf',
            'url': f'{base}?view=wolf',
            'active': current == 'wolf',
        })
    if _has_casual_match_play(round_obj):
        tabs.append({
            'key': 'match_play', 'label': 'Match Play',
            'url': f'{base}?view=match_play',
            'active': current == 'match_play',
        })
    if _has_casual_sixes(round_obj):
        tabs.append({
            'key': 'sixes', 'label': 'Sixes',
            'url': f'{base}?view=sixes',
            'active': current == 'sixes',
        })
    if _has_casual_pink_ball(round_obj):
        tabs.append({
            'key': 'red_ball', 'label': _red_ball_label(round_obj),
            'url': f'{base}?view=red_ball',
            'active': current == 'red_ball',
        })
    if _has_casual_irish_rumble(round_obj):
        tabs.append({
            'key': 'irish_rumble', 'label': 'Irish Rumble',
            'url': f'{base}?view=irish_rumble',
            'active': current == 'irish_rumble',
        })
    if _has_low_net_championship(round_obj):
        tabs.append({
            'key': 'stroke_play', 'label': _stroke_play_label(round_obj),
            'url': f'{base}?view=stroke_play',
            'active': current == 'stroke_play',
        })
    if _has_stableford_championship(round_obj):
        tabs.append({
            'key': 'stableford_championship', 'label': 'Stableford',
            'url': f'{base}?view=stableford_championship',
            'active': current == 'stableford_championship',
        })
    if _has_low_net_round(round_obj):
        tabs.append({
            'key': 'low_net', 'label': 'Stroke Play',
            'url': f'{base}?view=low_net',
            'active': current == 'low_net',
        })
    if _has_cup_standings(round_obj):
        tabs.append({
            'key': 'cup', 'label': _cup_name(round_obj),
            'url': f'{base}?view=cup', 'active': current == 'cup',
        })
    return tabs


# ---------------------------------------------------------------------------
# Low Net display enrichment
# ---------------------------------------------------------------------------

def _net_handicap_label(raw_hcp: int, mode: str, net_percent: int) -> str:
    """Format the net playing index shown in parens after the name.

    Net   → round(raw × pct/100)
    Gross → raw playing index
    Strokes-off → raw playing index (the round-wide low player plays to 0;
                  the per-player number shown is still their own index)."""
    if raw_hcp is None:
        return ''
    try:
        raw = int(raw_hcp)
    except (TypeError, ValueError):
        return ''
    if mode == 'net':
        return f'{round(raw * (net_percent or 100) / 100.0)}'
    return f'{raw}'


def _hole_to_par_class(hole: dict, key: str) -> str:
    """Return 'under' / 'over' / '' for colouring a gross/net cell vs par."""
    val = hole.get(key)
    par = hole.get('par')
    if val is None or par is None:
        return ''
    diff = val - par
    if diff < 0: return 'under'
    if diff > 0: return 'over'
    return ''


def _build_nine_grid(holes: list, is_front: bool, show_net: bool) -> dict:
    """Compact 9-hole scorecard data block for templates.

    Returns: {label, headers, rows[{hole,par,gross,gross_cls,net,net_cls}],
              totals{label,par,gross,net,net_to_par,net_cls}}"""
    segment = [
        h for h in holes
        if (is_front and (h.get('hole') or 0) <= 9)
        or (not is_front and (h.get('hole') or 0) > 9)
    ]
    rows = []
    tot_par = tot_gross = tot_net = 0
    for h in segment:
        rows.append({
            'hole'        : h.get('hole'),
            'par'         : h.get('par'),
            'stroke_index': h.get('stroke_index'),
            'gross'       : h.get('gross'),
            'gross_cls'   : _hole_to_par_class(h, 'gross'),
            'net'         : h.get('capped'),
            'net_cls'     : _hole_to_par_class(h, 'capped'),
        })
        tot_par   += h.get('par')    or 0
        tot_gross += h.get('gross')  or 0
        tot_net   += h.get('capped') or 0

    net_to_par = (tot_net - tot_par) if segment else None
    if net_to_par is None:
        ntp_label, ntp_cls = '—', ''
    elif net_to_par == 0:
        ntp_label, ntp_cls = 'E', ''
    elif net_to_par < 0:
        ntp_label, ntp_cls = f'{net_to_par}', 'under'
    else:
        ntp_label, ntp_cls = f'+{net_to_par}', 'over'

    return {
        'label'   : 'Front 9' if is_front else 'Back 9',
        'rows'    : rows,
        'show_net': show_net,
        'totals'  : {
            'label'     : 'Out' if is_front else 'In',
            'par'       : tot_par   if segment else None,
            'gross'     : tot_gross if segment else None,
            'net_label' : ntp_label,
            'net_cls'   : ntp_cls,
            'net_total' : tot_net   if segment else None,
        },
        'empty'   : not segment,
    }


def _enrich_low_net(summary: dict, scope: str) -> None:
    """Attach `net_handicap_label` to each row and pre-build per-round
    F9/B9 scorecard grids so the template stays declarative."""
    mode  = summary.get('handicap_mode') or 'net'
    npct  = summary.get('net_percent') or 100
    show_net = mode != 'gross'
    summary['show_net'] = show_net
    for row in summary.get('results') or []:
        row['net_handicap_label'] = _net_handicap_label(
            row.get('handicap'), mode, npct,
        )
        if scope == 'championship':
            # `round_holes` is a list of per-round hole lists; build a grid
            # per round so the template can label them R1, R2, …
            rh     = row.get('round_holes')  or []
            labels = row.get('round_labels') or []
            cards  = []
            for label, holes in zip(labels, rh):
                cards.append({
                    'label' : label,
                    'front' : _build_nine_grid(holes, is_front=True,  show_net=show_net),
                    'back'  : _build_nine_grid(holes, is_front=False, show_net=show_net),
                })
            row['scorecards']    = cards
            row['has_scorecard'] = bool(cards)
        else:
            holes = row.get('holes') or []
            row['scorecards'] = [{
                'label': None,
                'front': _build_nine_grid(holes, is_front=True,  show_net=show_net),
                'back' : _build_nine_grid(holes, is_front=False, show_net=show_net),
            }] if holes else []
            row['has_scorecard'] = bool(holes)


# ---------------------------------------------------------------------------
# Per-view render helpers
# ---------------------------------------------------------------------------

def _render_matches(request, round_obj, token: str, tabs: list):
    from services.cup_standings import cup_round_live_summary
    summary = cup_round_live_summary(round_obj)
    if summary is None:
        return render(request, 'watch/unsupported.html', {
            'round': round_obj, 'tabs': tabs,
        })
    _enrich_summary(summary)
    _attach_team_palettes(summary)
    # to_win for the round: same formula as cup_standings_summary
    total_possible = float(summary.get('total_possible') or 0)
    summary['to_win'] = round(total_possible / 2 + 0.5, 2) if total_possible > 0 else None
    return render(request, 'watch/cup_round.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'cup_name':     _cup_name(round_obj),
        'summary':      summary,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_low_net(request, round_obj, token: str, tabs: list):
    """Round-only Low Net tab — uses low_net_round_summary so a 2-round
    tournament's round-2 best-of-the-day stays distinct from the
    championship-wide Stroke Play tab.  Also serves as the casual-round
    scorecard view when no explicit Low Net config exists."""
    from services.low_net_round import low_net_round_summary
    summary = low_net_round_summary(round_obj)
    if summary:
        _enrich_low_net(summary, 'round')
    return render(request, 'watch/low_net.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      summary,
        'scope':        'round',
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_tournament_stroke_play(request, round_obj, token: str, tabs: list):
    """Tournament-wide Stroke Play (Low Net Championship) tab.  Tab
    label tracks the tournament's name (set in _stroke_play_label)."""
    from services.low_net_championship import low_net_championship_summary
    tourney = round_obj.tournament
    summary = low_net_championship_summary(tourney) if tourney else None
    if summary:
        _enrich_low_net(summary, 'championship')
    return render(request, 'watch/low_net.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   tourney,
        'summary':      summary,
        'scope':        'championship',
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_casual_stableford(request, round_obj, token: str, tabs: list):
    """Stableford spectator tab — ranked points + payouts (pool or per-point)."""
    from services.stableford import stableford_summary
    return render(request, 'watch/stableford.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      stableford_summary(round_obj),
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_stableford_championship(request, round_obj, token: str, tabs: list):
    """Tournament-wide Stableford — total points across every round."""
    from services.stableford_championship import stableford_championship_summary
    tourney = round_obj.tournament
    summary = stableford_championship_summary(tourney) if tourney else None
    return render(request, 'watch/stableford_championship.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   tourney,
        'summary':      summary,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_casual_red_ball(request, round_obj, token: str, tabs: list):
    """Red / Pink Ball spectator tab — ranked per-foursome results
    pulled from red_ball_summary."""
    from services.red_ball import red_ball_summary
    summary = red_ball_summary(round_obj)
    return render(request, 'watch/casual_red_ball.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      summary,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_casual_irish_rumble(request, round_obj, token: str, tabs: list):
    """Irish Rumble spectator tab (non-cup).  Reuses
    irish_rumble_summary — overall standings plus a section per
    scoring segment."""
    from services.irish_rumble import irish_rumble_summary
    summary = irish_rumble_summary(round_obj)
    return render(request, 'watch/casual_irish_rumble.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      summary,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_cup_standings(request, round_obj, token: str, tabs: list):
    from services.cup_standings import cup_standings_summary, cup_round_live_summary
    tourney = round_obj.tournament
    summary = cup_standings_summary(tourney) if tourney else None

    # Mirror the app's Cup tab — show the live "in progress" match cards
    # alongside the cumulative scoreboard, with already-decided sides
    # filtered out so the user sees only what hasn't yet landed in the
    # big score.
    pending_matches   = []
    completed_matches = []
    live_summary      = cup_round_live_summary(round_obj)
    if live_summary is not None:
        _enrich_summary(live_summary)
        _attach_team_palettes(live_summary)
        all_matches       = live_summary.get('matches', [])
        pending_matches   = _filter_pending_matches(all_matches)
        completed_matches = _filter_completed_matches(all_matches)
    if summary is not None:
        _attach_team_palettes(summary)

    return render(request, 'watch/cup_standings.html', {
        'round':             round_obj,
        'course_name':       round_obj.course.name,
        'tournament':        tourney,
        'cup_name':          _cup_name(round_obj),
        'summary':           summary,
        'live_summary':      live_summary,
        'pending_matches':   pending_matches,
        'completed_matches': completed_matches,
        'refresh_secs':      30,
        'tabs':              tabs,
    })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _render_casual_skins(request, round_obj, token: str, tabs: list):
    """Per-foursome Skins standings — bare-bones spectator view.

    Standings only (skins won + payout per player); the per-hole gross
    scorecard is intentionally left to the app to keep the web view light."""
    from services.skins import skins_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        summary = skins_summary(fs)
        groups.append({
            'group_number': fs.group_number,
            'foursome_id' : fs.id,
            'summary'     : summary,
        })
    return render(request, 'watch/casual_skins.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'groups':       groups,
        'thru':         _round_thru(round_obj),
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _build_ms_scorecard(summary: dict) -> dict:
    """Pre-compute the Multi-Skins scorecard grid for the template.

    Returns:
      {
        'hole_headers': [{'num', 'par', 'is_dead'}, ...],     # 18 items
        'rows'        : [
            {'name', 'cells': [{'gross', 'strokes', 'is_winner'}, ...]},
            ...
        ],
      }

    Cells without a score show empty.  Dead holes (played but tied —
    no skin awarded) get a grey header.  Winner cells are flagged so
    the template can paint them green."""
    holes_in  = summary.get('holes')   or []
    players   = summary.get('players') or []
    by_num    = {h.get('hole'): h for h in holes_in}
    nums      = list(range(1, 19))

    hole_headers = [
        {
            'num'    : n,
            'par'    : (by_num.get(n) or {}).get('par'),
            'is_dead': (by_num.get(n) or {}).get('is_dead', False),
        }
        for n in nums
    ]

    rows = []
    for p in players:
        pid = p.get('player_id')
        cells = []
        for n in nums:
            entry = by_num.get(n)
            cell  = {'gross': None, 'strokes': 0, 'is_winner': False}
            if entry:
                for s in entry.get('scores') or []:
                    if s.get('player_id') == pid:
                        cell['gross']     = s.get('gross')
                        cell['strokes']   = s.get('strokes') or 0
                        cell['is_winner'] = entry.get('winner_id') == pid
                        break
            cells.append(cell)
        rows.append({
            'name'         : p.get('short_name') or p.get('name') or '',
            # Net strokes this player is receiving in the game (set by
            # skins_summary / multi_skins_summary).  Shown in parens
            # after the name so observers can read each row's adjusted
            # handicap at a glance.
            'phcp_in_play' : p.get('phcp_in_play'),
            'cells'        : cells,
        })

    return {'hole_headers': hole_headers, 'rows': rows}


def _render_casual_multi_skins(request, round_obj, token: str, tabs: list):
    """Multi-Group Skins standings — bare-bones spectator view.

    Just the standings table (pool, skins, payout per player). The
    per-hole skin-winner scorecard is intentionally left out of the web
    view to keep it light and steer watchers to the app for the detail."""
    from services.multi_skins import multi_skins_summary
    summary = multi_skins_summary(round_obj)
    return render(request, 'watch/casual_multi_skins.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      summary,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _sixes_segment_score(seg: dict) -> str:
    """Plain-English score for one Sixes segment — mirrors the
    in-app _SixesGroupCard._segmentScore so the same language shows
    up in the spectator view.

    Examples:
      "4 and 2"        — match decided early, won 4-up with 2 to play
      "3 UP"           — ran the full segment, won by 3
      "Halved"         — segment finished tied
      "AS thru 4"      — still in progress, all square through 4
      "2 UP thru 5"    — still in progress, leader 2 up through 5
      "Pending"        — not started
    """
    status = seg.get('status', 'pending')
    winner = seg.get('winner') or '—'
    holes  = seg.get('holes') or []
    start  = int(seg.get('start_hole') or 1)
    end    = int(seg.get('end_hole')   or start)
    played = len(holes)
    last_margin = 0
    if holes:
        last = holes[-1]
        last_margin = int(last.get('margin') or 0)
    abs_m = abs(last_margin)
    total_h     = end - start + 1
    holes_left  = total_h - played

    if status in ('complete', 'halved'):
        if winner == 'Halved':
            return 'Halved'
        if holes_left > 0:
            return f'{abs_m} and {holes_left}'
        return f'{abs_m} UP' if abs_m else 'Halved'
    if status == 'in_progress':
        if last_margin == 0:
            return f'AS thru {played}'
        return f'{abs_m} UP thru {played}'
    return 'Pending'


def _sixes_segment_subtitle(seg: dict) -> dict:
    """Team line under each segment, broken into parts so the template
    can highlight the leading / winning team in a distinct style.

    Returns:
      {
        'leader' : 'Paul & Mike',     # the team to emphasise (or None)
        'joiner' : 'beat' | 'vs' | 'Halved — ',
        'trailer': 'Jul & Larry',
        'tone'   : 'won' | 'leading' | 'halved' | 'pending',
      }

    Rules:
      • Complete win  → leader = winning team, joiner = 'beat'.
      • In-progress lead (margin != 0) → leader = leading team, joiner = 'vs'.
      • Halved        → no leader, joiner = 'Halved — '.
      • AS / pending  → no leader, joiner = 'vs'.
    """
    t1 = ((seg.get('team1') or {}).get('players') or [])
    t2 = ((seg.get('team2') or {}).get('players') or [])

    def _join(team):
        names = [str(p) for p in team]
        if not names:        return '—'
        if len(names) == 2:  return f'{names[0]} & {names[1]}'
        return ', '.join(names)

    t1s = _join(t1)
    t2s = _join(t2)
    winner = (seg.get('winner') or '').strip()
    status = seg.get('status') or 'pending'

    if winner == 'Team 1':
        return {'leader': t1s, 'joiner': 'beat', 'trailer': t2s, 'tone': 'won'}
    if winner == 'Team 2':
        return {'leader': t2s, 'joiner': 'beat', 'trailer': t1s, 'tone': 'won'}
    if winner == 'Halved':
        return {'leader': None, 'joiner': 'Halved — ',
                'trailer': f'{t1s} vs {t2s}', 'tone': 'halved'}

    # Pending or in-progress.  Pull the last recorded margin to detect a
    # leader: +ve → team1 leading, −ve → team2 leading, 0 → all square.
    last_margin = 0
    holes = seg.get('holes') or []
    if holes:
        last_margin = int((holes[-1].get('margin')) or 0)

    if status == 'in_progress' and last_margin > 0:
        return {'leader': t1s, 'joiner': 'vs', 'trailer': t2s, 'tone': 'leading'}
    if status == 'in_progress' and last_margin < 0:
        return {'leader': t2s, 'joiner': 'vs', 'trailer': t1s, 'tone': 'leading'}

    return {'leader': None, 'joiner': '', 'trailer': f'{t1s} vs {t2s}',
            'tone': 'pending'}


def _render_casual_sixes(request, round_obj, token: str, tabs: list):
    """Per-foursome Sixes leaderboards — per-match score line ("4 and 2"
    / "AS thru 3" / etc.) with the team composition underneath, plus
    the running per-player money totals.  Mirrors _SixesGroupCard."""
    from services.sixes import sixes_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        summary = sixes_summary(fs)
        # Pre-compute the plain-English status text once per segment so
        # the template stays free of conditionals.
        if summary:
            for seg in summary.get('segments') or []:
                seg['score_text']     = _sixes_segment_score(seg)
                seg['subtitle_parts'] = _sixes_segment_subtitle(seg)
        groups.append({
            'group_number': fs.group_number,
            'foursome_id' : fs.id,
            'summary'     : summary,
        })
    return render(request, 'watch/casual_sixes.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _build_p531_progress(summary: dict) -> dict:
    """Build the per-hole progress grid for a Points 5-3-1 foursome.

    Mirrors the in-app score-entry progress card: hole-number row,
    par row, then for each player a paired (gross, points-awarded)
    row.  Cells with strokes carry a stroke-dot indicator just like
    the Multi-Skins / Skins scorecards."""
    holes_in = summary.get('holes')   or []
    players  = summary.get('players') or []
    by_num   = {h.get('hole'): h for h in holes_in}

    hole_headers = [
        {'num': n, 'par': (by_num.get(n) or {}).get('par')}
        for n in range(1, 19)
    ]

    rows = []
    for p in players:
        pid     = p.get('player_id')
        scores  = []
        points  = []
        for n in range(1, 19):
            entry = by_num.get(n)
            score_cell  = {'gross': None, 'strokes': 0}
            points_cell = {'value': None, 'is_winner': False}
            if entry:
                for e in entry.get('entries') or []:
                    if e.get('player_id') == pid:
                        score_cell['gross']    = e.get('gross')
                        score_cell['strokes']  = e.get('strokes') or 0
                        pts = e.get('points')
                        points_cell['value']   = pts
                        # The "5" award is always the outright top score
                        # on the hole.  Awards of 4 / 3.5 are ties and
                        # not "winners" in the same visual sense.
                        points_cell['is_winner'] = (pts == 5)
                        break
            scores.append(score_cell)
            points.append(points_cell)
        rows.append({
            'name'         : p.get('short_name') or p.get('name') or '',
            'phcp_in_play' : p.get('phcp_in_play'),
            'scores'       : scores,
            'points'       : points,
        })

    return {'hole_headers': hole_headers, 'rows': rows}


def _render_casual_points_531(request, round_obj, token: str, tabs: list):
    """Per-foursome Points 5-3-1 cards — leaderboard totals on top,
    horizontal hole-by-hole progress grid (gross + per-hole award) on
    the bottom."""
    from services.points_531 import points_531_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        summary = points_531_summary(fs)
        groups.append({
            'group_number': fs.group_number,
            'foursome_id' : fs.id,
            'summary'     : summary,
            'progress'    : _build_p531_progress(summary) if summary else None,
        })
    return render(request, 'watch/casual_points_531.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _nassau_watch_card(s: dict) -> dict:
    """Teaser-level summary for the casual Nassau / 18-Hole Match watch tab —
    matchup + match status + the leader's money, no per-hole grid (that's the
    reason to open the app)."""
    def names(team):
        return ' & '.join((p['name'] or p['short_name'])
                          for p in s['teams'].get(team, [])) or team
    t1, t2 = names('team1'), names('team2')
    is_match = (not s.get('play_front') and not s.get('play_back')
                and s.get('play_overall'))
    bet = float(s.get('bet_unit') or 0)
    ov  = s.get('overall', {})
    thru = ov.get('holes_played') or 0
    card = {'t1': t1, 't2': t2, 'thru': thru, 'is_match': is_match,
            'status': '', 'leader': '', 'money': '', 'segments': []}

    if is_match:
        margin = ov.get('margin') or 0
        result = ov.get('result')
        card['leader'] = _leader_from_margin(margin, result)
        leader_name = t1 if margin > 0 else (t2 if margin < 0 else '')
        if result is not None:
            left = 18 - thru
            if margin == 0:
                card['status'] = 'Halved'
            elif left > 0:
                card['status'] = f'{leader_name} wins {abs(margin)}&{left}'
            else:
                card['status'] = f'{leader_name} wins {abs(margin)} up'
        elif margin == 0:
            card['status'] = 'All Square'
        else:
            card['status'] = f'{leader_name} {abs(margin)} UP'
        if bet and margin != 0:
            card['money'] = f'{leader_name}  +${bet:g}'
        elif margin == 0:
            card['money'] = 'All square — no money'
    else:
        def seg(label, d, seg_len):
            margin = d.get('margin') or 0
            holes  = d.get('holes_played') or 0
            result = d.get('result')
            if holes <= 0:
                text = 'Not started'
            elif result is not None:
                text = _final_text(margin, t1, t2)
            else:
                text = _holes_up_text(margin, holes, t1, t2)
            return {'label': label, 'text': text,
                    'leader': _leader_from_margin(margin, result)}
        if s.get('play_front'):   card['segments'].append(seg('Front 9', s['front9'], 9))
        if s.get('play_back'):    card['segments'].append(seg('Back 9',  s['back9'],  9))
        if s.get('play_overall'): card['segments'].append(seg('Overall', s['overall'], 18))
    return card


def _render_casual_nassau(request, round_obj, token: str, tabs: list):
    """Casual Nassau / 18-Hole Match — summary-only watch view (a teaser that
    points spectators to the app for the full hole-by-hole action)."""
    from services.nassau import nassau_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = []
    for fs in foursomes:
        s = nassau_summary(fs)
        if not s:
            continue
        groups.append({
            'group_number': fs.group_number,
            'card':         _nassau_watch_card(s),
        })
    return render(request, 'watch/casual_nassau.html', {
        'thru':         _round_thru(round_obj),
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'is_match':     _nassau_is_match(round_obj),
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _build_nassau_progress(ns_summary: dict) -> dict:
    """Build the hole-by-hole progress grid for a Four Ball match.

    Mirrors the in-app Nassau Progress card on the score-entry screen:
      hole-number row, par row, one row per player (gross + stroke
      dots, team-coloured name with playing handicap), and a "Won by"
      row showing T1 / T2 / = for each completed hole.

    Returns:
      {
        'hole_headers': [{'num': n, 'par': p}, ...],            # 18
        'player_rows' : [
            {'name', 'team': 1|2, 'phcp_in_play',
             'cells': [{'gross', 'strokes'}, ...]},
            ...
        ],
        'won_by'      : ['team1'|'team2'|'halved'|None, ...],   # 18
      }
    """
    holes_in   = ns_summary.get('holes') or []
    teams      = ns_summary.get('teams') or {}
    t1_players = teams.get('team1') or []
    t2_players = teams.get('team2') or []
    by_num     = {h.get('hole'): h for h in holes_in}

    hole_headers = [
        {'num': n, 'par': (by_num.get(n) or {}).get('par')}
        for n in range(1, 19)
    ]
    won_by = [(by_num.get(n) or {}).get('winner') for n in range(1, 19)]

    def _player_row(p: dict, team_num: int) -> dict:
        pid   = p.get('player_id')
        cells = []
        for n in range(1, 19):
            entry = by_num.get(n) or {}
            cell  = {'gross': None, 'strokes': 0}
            for s in entry.get('scores') or []:
                if s.get('player_id') == pid:
                    cell['gross']   = s.get('gross')
                    cell['strokes'] = s.get('strokes') or 0
                    break
            cells.append(cell)
        return {
            'name'         : p.get('short_name') or p.get('name') or '',
            'team'         : team_num,
            'phcp_in_play' : p.get('phcp_in_play'),
            'cells'        : cells,
        }

    player_rows = (
        [_player_row(p, 1) for p in t1_players] +
        [_player_row(p, 2) for p in t2_players]
    )
    return {
        'hole_headers': hole_headers,
        'player_rows' : player_rows,
        'won_by'      : won_by,
    }


def _render_cup_four_ball(request, round_obj, token: str, tabs: list):
    """Per-foursome Four Ball cards — F9 / B9 / Overall result chips on
    top (reuses _match_card.html) plus a horizontal hole-by-hole
    progress grid on the bottom (gross scores per player with stroke
    dots, team-coloured names, and a Won-by row)."""
    from services.cup_standings import cup_round_live_summary
    from services.nassau       import nassau_summary
    from core.models           import GameType

    summary = cup_round_live_summary(round_obj)
    if summary is None:
        return render(request, 'watch/unsupported.html', {
            'round': round_obj, 'tabs': tabs,
        })
    _enrich_summary(summary)
    _attach_team_palettes(summary)

    # Map foursome_id → groups for nassau matches, so we can pair each
    # cup-summary match card with its progress grid.
    rc           = round_obj.ryder_cup_config
    nassau_cfgs  = list(
        rc.foursome_configs
        .filter(game_type=GameType.NASSAU)
        .select_related('foursome')
    )
    progress_by_group: dict = {}
    for cfg in nassau_cfgs:
        try:
            ns = nassau_summary(cfg.foursome)
        except Exception:
            ns = None
        if ns is None:
            continue
        progress_by_group[cfg.foursome.group_number] = _build_nassau_progress(ns)

    # Filter the cup summary down to nassau matches and pair each with
    # the corresponding progress grid (matched by group number).
    cards = []
    for m in summary.get('matches', []):
        if m.get('game_type') != 'nassau':
            continue
        groups = m.get('groups') or []
        progress = progress_by_group.get(groups[0]) if groups else None
        cards.append({'match': m, 'progress': progress})

    return render(request, 'watch/cup_four_ball.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      summary,
        'cards':        cards,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


_VIEW_DISPATCH = {
    'matches':      _render_matches,
    'low_net':      _render_low_net,
    'stroke_play':  _render_tournament_stroke_play,
    'cup':          _render_cup_standings,
    'skins':        _render_casual_skins,
    'stableford':   _render_casual_stableford,
    'stableford_championship': _render_stableford_championship,
    'multi_skins':  _render_casual_multi_skins,
    'points_531':   _render_casual_points_531,
    'nassau':       _render_casual_nassau,
    'triple_cup':   _render_casual_triple_cup,
    'wolf':         _render_casual_wolf,
    'match_play':   _render_casual_match_play,
    'sixes':        _render_casual_sixes,
    'red_ball':     _render_casual_red_ball,
    'irish_rumble': _render_casual_irish_rumble,
    'four_ball':    _render_cup_four_ball,
}


def watch_cup_round(request, token: str):
    """
    GET /watch/<token>/[?view=matches|low_net|cup]

    Public spectator page.  Dispatches to one of three views based on the
    `view` query param.  Defaults to the cup matches view.
    """
    try:
        round_obj = (
            Round.objects
            .select_related('course', 'tournament', 'tournament__team_tournament')
            .get(watch_token=token)
        )
    except Round.DoesNotExist:
        raise Http404("Unknown watch link.")

    requested = (request.GET.get('view') or 'matches').lower()
    if requested not in _VIEW_DISPATCH:
        requested = 'matches'

    tabs = _build_tabs(round_obj, token, requested)
    # If the requested view's tab isn't actually available, fall back to
    # the first available tab (or the unsupported page if none).
    if not any(t['key'] == requested and t['active'] for t in tabs):
        if tabs:
            requested = tabs[0]['key']
            for t in tabs:
                t['active'] = (t['key'] == requested)
        else:
            return render(request, 'watch/unsupported.html', {
                'round': round_obj, 'tabs': [],
            })

    return _VIEW_DISPATCH[requested](request, round_obj, token, tabs)
