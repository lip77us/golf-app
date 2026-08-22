"""
services/shared_scorecard.py
----------------------------
View model for the shared scorecard page — the page a link.halved.golf tap
opens (handoff-shared-scorecard).

This page is a MIRROR. It renders what the app computes and nothing else: if
it can produce a different answer from the app, that is a bug, not a feature.
So everything here is presentation — picking names, grouping holes, deciding
what is worth showing — and no scoring.

It replaces the shared scorecard PNG, which titled itself with the course,
called one golfer two different names, printed the same result three times,
and carried no Halved anywhere.
"""
from __future__ import annotations


# ---------------------------------------------------------------------------
# Names — one form, used everywhere on the page
# ---------------------------------------------------------------------------

def _first(name: str) -> str:
    return (name or '').strip().split(' ')[0]


def _first_initial(name: str) -> str:
    parts = (name or '').strip().split()
    if len(parts) < 2:
        return parts[0] if parts else ''
    return f'{parts[0]} {parts[-1][0].upper()}.'


def familiar_names(full_names) -> dict:
    """
    Shortest form that still tells this group apart: first name, escalating to
    'Paul L.' and then to the full name only when it has to.

    The old page showed "Paul L." in the grid and "Paul Lipkin" in the net
    table -- two names for one golfer on one screen. One form is chosen here
    and used in the title AND the grid, so that cannot recur.
    """
    names = [n.strip() for n in full_names if (n or '').strip()]
    uniq  = list(dict.fromkeys(names))

    def count(form, value):
        v = value.lower()
        return sum(1 for n in uniq if form(n).lower() == v)

    out = {}
    for n in uniq:
        f = _first(n)
        if count(_first, f) == 1:
            out[n] = f
            continue
        fi = _first_initial(n)
        if count(_first_initial, fi) == 1:
            out[n] = fi
            continue
        out[n] = n
    return out


def page_title(player_names, host_name: str, course_name: str) -> str:
    """
    The match is the story; the course is the setting. Singles reads as a
    matchup; anything larger is named for whoever set it up, which matches the
    og:title on the card that got the reader here.
    """
    short = familiar_names(player_names)
    ordered = [short[n] for n in dict.fromkeys(
        [p.strip() for p in player_names if (p or '').strip()])]
    if len(ordered) == 2:
        return f'{ordered[0]} vs {ordered[1]}'
    host = _first(host_name)
    if host and course_name:
        return f'{host}’s round at {course_name}'
    if course_name:
        return f'A round at {course_name}'
    return 'A round on Halved'


# ---------------------------------------------------------------------------
# Score notation — the app's own symbols
# ---------------------------------------------------------------------------

def score_class(score, par) -> str:
    """
    CSS class for a score cell: the paper-scorecard notation. Empty string for
    par and for a missing score -- an unplayed hole is BLANK, not a dash. The
    gridline already says the hole exists.
    """
    if score is None or par is None:
        return ''
    d = score - par
    if d <= -3:
        return 'albatross'
    if d == -2:
        return 'eagle'
    if d == -1:
        return 'birdie'
    if d == 1:
        return 'bogey'
    if d >= 2:
        return 'double'
    return ''


def build_page(foursome, mode: str = 'gross') -> dict:
    """
    Everything the template needs, for one foursome.

    `mode` is 'gross' or 'net'. Both come straight from stored per-hole values
    -- gross_score and net_score -- so neither is computed here. Strokes-off is
    deliberately absent: it re-allocates strokes (the low handicap plays to 0)
    and no per-hole SO value is stored, so offering it would mean this page
    doing its own scoring. When the ROUND itself is in strokes-off mode the
    stored net already is the SO net, and the label says so.
    """
    from api.views import _build_scorecard

    card    = _build_scorecard(foursome)
    round_o = foursome.round
    holes   = card.get('holes') or []

    members = list(foursome.memberships.select_related('player').all())
    full    = [m.player.name for m in members]
    short   = familiar_names(full)

    hmode = getattr(round_o, 'handicap_mode', '') or ''
    net_label = 'SO Low' if hmode == 'strokes_off' else 'Net'

    def cell(hole, pid):
        for s in hole.get('scores') or []:
            if s.get('player_id') == pid:
                return s
        return {}

    def row_for(m):
        pid   = m.player_id
        cells = []
        for h in holes:
            s   = cell(h, pid)
            par = h.get('par')
            val = s.get('gross_score') if mode == 'gross' else s.get('net_score')
            cells.append({
                'hole' : h.get('hole_number'),
                'value': val,
                'cls'  : score_class(val, par),
                'under': (val is not None and par is not None and val < par),
            })
        return {'name': short.get(m.player.name, m.player.name), 'cells': cells}

    rows  = [row_for(m) for m in members]
    front = [h.get('hole_number') for h in holes if (h.get('hole_number') or 0) <= 9]
    back  = [h.get('hole_number') for h in holes if (h.get('hole_number') or 0) > 9]

    # The back nine stays collapsed to par-only until a score lands on hole 10.
    # Fifteen empty columns made a live match look abandoned.
    back_started = any(
        c['value'] is not None
        for r in rows for c in r['cells'] if (c['hole'] or 0) > 9
    )

    def total(row, lo, hi):
        vals = [c['value'] for c in row['cells']
                if c['value'] is not None and lo <= (c['hole'] or 0) <= hi]
        return sum(vals) if vals else None

    for r in rows:
        # 'in' would collide with the template's `in` operator, so the keys
        # are spelled out.
        r['out_total'] = total(r, 1, 9)
        r['in_total']  = total(r, 10, 18)
        r['tot_total'] = total(r, 1, 18)
        r['front_cells'] = [c for c in r['cells'] if (c['hole'] or 0) <= 9]
        r['back_cells']  = [c for c in r['cells'] if (c['hole'] or 0) > 9]

    pars = {h.get('hole_number'): h.get('par') for h in holes}
    thru = max(
        [c['hole'] for r in rows for c in r['cells'] if c['value'] is not None]
        or [0])

    return {
        'title'       : page_title(full, str(getattr(round_o, 'created_by', '') or ''),
                                   round_o.course.name if round_o.course_id else ''),
        'course'      : round_o.course.name if round_o.course_id else '',
        'date'        : round_o.date,
        'rows'        : rows,
        # Columns carry their own par: Django has no dict-lookup-by-variable
        # filter, and inventing one just to read pars[hole] is more machinery
        # than pairing them here.
        'front_cols'  : [{'hole': h, 'par': pars.get(h)} for h in front],
        'back_cols'   : [{'hole': h, 'par': pars.get(h)} for h in back],
        'back_started': back_started,
        'pars'        : pars,
        'par_out'     : sum(p for h, p in pars.items() if h <= 9 and p) or None,
        'par_in'      : sum(p for h, p in pars.items() if h > 9 and p) or None,
        'par_tot'     : sum(p for p in pars.values() if p) or None,
        'thru'        : thru,
        'mode'        : mode,
        'net_label'   : net_label,
        'is_live'     : getattr(round_o, 'status', '') == 'in_progress',
        'group_number': foursome.group_number,
    }
