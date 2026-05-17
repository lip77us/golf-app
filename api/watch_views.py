"""
api/watch_views.py
------------------
Public, unauthenticated read-only views that render an HTML leaderboard
page for spectators who don't have the app installed.  Linked from the
mobile app's "Share Watch Link" button.

Tokens live on Round (watch_token).  No auth, no CSRF, no JSON — just a
plain HTML page with a `<meta http-equiv="refresh">` so the spectator's
browser polls every 30s without any JavaScript.

Currently supports Ryder Cup rounds (Four Ball / Singles Nassau / 18-
Hole Singles).  Other round types render a "not yet supported" page.
"""
from __future__ import annotations

from django.http       import Http404
from django.shortcuts  import render
from django.utils.html import escape

from tournament.models import Round


# ---------------------------------------------------------------------------
# Round-level cup leaderboard
# ---------------------------------------------------------------------------

def watch_cup_round(request, token: str):
    """
    GET /watch/<token>/

    Public spectator page.  Looks up the Round by watch_token, computes
    the live cup standings (team points + per-foursome match cards), and
    renders a phone-friendly HTML page that auto-refreshes every 30s.
    """
    try:
        round_obj = (
            Round.objects
            .select_related('course', 'tournament')
            .get(watch_token=token)
        )
    except Round.DoesNotExist:
        raise Http404("Unknown watch link.")

    from services.cup_standings import cup_round_live_summary
    summary = cup_round_live_summary(round_obj)

    if summary is None:
        # Non-cup round — public mode not supported yet.
        return render(request, 'watch/unsupported.html', {
            'round': round_obj,
        })

    context = {
        'round':          round_obj,
        'course_name':    round_obj.course.name,
        'tournament':     round_obj.tournament,
        'summary':        summary,
        # Phone-friendly: keep everything in one column at small viewports.
        'refresh_secs':   30,
    }
    return render(request, 'watch/cup_round.html', context)
