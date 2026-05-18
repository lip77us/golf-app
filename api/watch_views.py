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


# ---------------------------------------------------------------------------
# Tab discovery
# ---------------------------------------------------------------------------

def _has_cup_matches(round_obj) -> bool:
    return hasattr(round_obj, 'ryder_cup_config')

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

def _has_casual_multi_skins(round_obj) -> bool:
    return 'multi_skins' in (round_obj.active_games or [])

def _has_low_net(round_obj) -> bool:
    """True when the round (or its tournament) has any low-net offering.

    Mirrors the signals the mobile app uses to surface Low Net: prefer
    the canonical `active_games` array on round / tournament, fall back
    to the presence of an explicit setup record.  For casual rounds we
    always include Low Net — the tab doubles as the spectator scorecard
    view (the one game-specific leaderboards don't offer)."""
    if 'low_net_round' in (round_obj.active_games or []):
        return True
    if hasattr(round_obj, 'low_net_config'):
        return True
    tourney = round_obj.tournament
    if tourney:
        if 'low_net' in (tourney.active_games or []):
            return True
        if hasattr(tourney, 'low_net_championship_config'):
            return True
    if _is_casual_round(round_obj):
        return True
    return False

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
    if _has_cup_matches(round_obj):
        tabs.append({
            'key': 'matches', 'label': 'Matches',
            'url': base, 'active': current == 'matches',
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
    if _has_low_net(round_obj):
        tabs.append({
            'key': 'low_net', 'label': 'Low Net',
            'url': f'{base}?view=low_net', 'active': current == 'low_net',
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
            'hole'     : h.get('hole'),
            'par'      : h.get('par'),
            'gross'    : h.get('gross'),
            'gross_cls': _hole_to_par_class(h, 'gross'),
            'net'      : h.get('capped'),
            'net_cls'  : _hole_to_par_class(h, 'capped'),
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
    """Prefer the tournament-wide Low Net Championship view whenever the
    tournament has Low Net enabled (config record OR `'low_net'` in
    active_games).  Otherwise fall back to the round-level summary when
    the round itself enables Low Net.  Both summary helpers tolerate a
    missing config (default to NET / 100%)."""
    tourney = round_obj.tournament
    scope   = None   # 'championship' or 'round'
    summary = None

    tourney_has_low_net = bool(tourney) and (
        hasattr(tourney, 'low_net_championship_config')
        or 'low_net' in (tourney.active_games or [])
    )
    round_has_low_net = (
        hasattr(round_obj, 'low_net_config')
        or 'low_net_round' in (round_obj.active_games or [])
    )

    if tourney_has_low_net:
        from services.low_net_championship import low_net_championship_summary
        summary = low_net_championship_summary(tourney)
        scope   = 'championship'
    elif round_has_low_net or _is_casual_round(round_obj):
        # Casual rounds fall through here even without an explicit Low Net
        # config — the tab serves as the spectator scorecard view.
        from services.low_net_round import low_net_round_summary
        summary = low_net_round_summary(round_obj)
        scope   = 'round'

    if summary:
        _enrich_low_net(summary, scope)
    return render(request, 'watch/low_net.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   tourney,
        'summary':      summary,
        'scope':        scope,
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
    pending_matches = []
    live_summary    = cup_round_live_summary(round_obj)
    if live_summary is not None:
        _enrich_summary(live_summary)
        pending_matches = _filter_pending_matches(live_summary.get('matches', []))

    return render(request, 'watch/cup_standings.html', {
        'round':           round_obj,
        'course_name':     round_obj.course.name,
        'tournament':      tourney,
        'cup_name':        _cup_name(round_obj),
        'summary':         summary,
        'live_summary':    live_summary,
        'pending_matches': pending_matches,
        'refresh_secs':    30,
        'tabs':            tabs,
    })


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _render_casual_skins(request, round_obj, token: str, tabs: list):
    """Per-foursome Skins leaderboards — mirrors the in-app Skins tab."""
    from services.skins import skins_summary
    foursomes = list(
        round_obj.foursomes
        .prefetch_related('memberships__player')
        .order_by('group_number')
    )
    groups = [
        {
            'group_number': fs.group_number,
            'foursome_id' : fs.id,
            'summary'     : skins_summary(fs),
        }
        for fs in foursomes
    ]
    return render(request, 'watch/casual_skins.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'groups':       groups,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


def _render_casual_multi_skins(request, round_obj, token: str, tabs: list):
    """Multi-Group Skins standings — pool, mode, and per-player payouts.
    The scorecard view lives on the Low Net tab, mirroring how the
    mobile leaderboard splits the standings from the scorecard grid."""
    from services.multi_skins import multi_skins_summary
    summary = multi_skins_summary(round_obj)
    return render(request, 'watch/casual_multi_skins.html', {
        'round':        round_obj,
        'course_name':  round_obj.course.name,
        'tournament':   round_obj.tournament,
        'summary':      summary,
        'refresh_secs': 30,
        'tabs':         tabs,
    })


_VIEW_DISPATCH = {
    'matches':     _render_matches,
    'low_net':     _render_low_net,
    'cup':         _render_cup_standings,
    'skins':       _render_casual_skins,
    'multi_skins': _render_casual_multi_skins,
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
