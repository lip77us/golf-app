"""
api/invite_views.py
-------------------
Public, unauthenticated landing page for a personal invite link.

A user shares https://<host>/i/<code>/ (from the in-app share sheet); the
recipient lands here and is pitched the app with a download button.  Mirrors the
plain-HTML, no-JS, AllowAny style of api/watch_views.py.  No PII beyond the
inviter's first name is shown.
"""
from __future__ import annotations

import html

from django.conf import settings
from django.contrib.auth import get_user_model
from django.http import Http404, HttpResponse


def _inviter_first_name(user) -> str:
    try:
        full = user.player_profile.name
    except Exception:
        full = user.get_full_name() or ''
    full = (full or '').strip()
    return full.split()[0] if full else 'A friend'


def invite_landing(request, code: str):
    """GET /i/<code>/ — public invite landing page."""
    User = get_user_model()
    try:
        user = User.objects.select_related('account').get(invite_code=code)
    except User.DoesNotExist:
        raise Http404('Unknown invite link.')

    first = html.escape(_inviter_first_name(user))
    download_url = html.escape(getattr(settings, 'APP_DOWNLOAD_URL', '') or '#')
    og_image = html.escape(getattr(settings, 'INVITE_OG_IMAGE_URL', '') or '')
    page_url = html.escape(request.build_absolute_uri())
    og_title = f"{first} invited you to Halved"
    og_desc = ("Halved is the easiest way to track golf bets — skins, nassau, "
               "points and more — with your group.")

    # Open Graph / Twitter tags so the link shows a rich preview (logo + title)
    # when shared in Messages, social apps, etc. (the share-sheet thumbnail).
    og_image_tags = (
        f'<meta property="og:image" content="{og_image}">\n'
        f'  <meta name="twitter:card" content="summary_large_image">'
        if og_image else '<meta name="twitter:card" content="summary">'
    )

    page = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{og_title}</title>
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Halved">
  <meta property="og:title" content="{og_title}">
  <meta property="og:description" content="{og_desc}">
  <meta property="og:url" content="{page_url}">
  {og_image_tags}
  <style>
    body {{ font-family: -apple-system, system-ui, sans-serif; background:#0b5a2b;
            color:#fff; margin:0; min-height:100vh; display:flex;
            align-items:center; justify-content:center; text-align:center; }}
    .card {{ max-width:420px; padding:40px 28px; }}
    h1 {{ font-size:1.6rem; margin:0 0 8px; }}
    p {{ font-size:1.05rem; line-height:1.5; opacity:.92; }}
    .logo {{ font-size:2.4rem; font-weight:800; letter-spacing:.5px;
             margin-bottom:24px; }}
    a.btn {{ display:inline-block; margin-top:24px; padding:14px 28px;
             background:#fff; color:#0b5a2b; font-weight:700; border-radius:999px;
             text-decoration:none; }}
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">Halved</div>
    <h1>{first} invited you to play</h1>
    <p>Halved is the easiest way to track golf bets — skins, nassau, points and
       more — with your group, right from your phone.</p>
    <a class="btn" href="{download_url}">Get the app</a>
  </div>
</body>
</html>"""
    return HttpResponse(page)
