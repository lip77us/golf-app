"""
api/invite_views.py
-------------------
Public, unauthenticated landing page for a personal invite link.

A user shares https://<host>/i/<code>/ (from the in-app share sheet); the
recipient lands here and is pitched the app with a download button.  Mirrors the
plain-HTML, no-JS, AllowAny style of api/watch_views.py.  The only personal
detail shown is the inviter's own display name — the same one the link-preview
card carries, resolved by the same `inviter_name` so the preview and the page
behind it cannot introduce him two different ways.
"""
from __future__ import annotations

import hashlib
import html

from django.conf import settings
from django.contrib.auth import get_user_model
from django.http import Http404, HttpResponse
from django.urls import reverse


def _inviter_display_name(user) -> str:
    """The inviter's full name, or a neutral stand-in when we have none."""
    from services.share_card import inviter_name
    return inviter_name(user) or 'A friend'


def invite_card_png(request, code: str):
    """
    GET /i/<code>/card.png

    The og:image for a personal invite link — the same 1200x630 template the
    watch card uses, with the INVITE pill and no round behind it.

    Unauthenticated on purpose: the crawler that fetches this carries no
    credential, and the code is already the credential for the page itself.

    Cached on the inviter's name, which is the only thing that varies. A long
    TTL is right here — unlike the watch card there is nothing live to go
    stale, and a rename is not worth a render per crawl.
    """
    from django.core.cache import cache
    from services.share_card import build_invite_context, render_card

    User = get_user_model()
    try:
        user = User.objects.select_related('account').get(invite_code=code)
    except User.DoesNotExist:
        raise Http404('Unknown invite link.')

    ctx = build_invite_context(user)
    # Keyed on a HASH of the title, not the title: it carries the inviter's
    # name, and a cache key with spaces in it is invalid under memcached.
    stamp = hashlib.sha1(ctx['title'].encode()).hexdigest()[:12]
    key = f'invitecard:{code}:{stamp}'
    png = cache.get(key)
    if png is None:
        png = render_card(ctx)
        cache.set(key, png, 60 * 60)

    resp = HttpResponse(png, content_type='image/png')
    resp['Cache-Control'] = 'public, max-age=3600'
    return resp


def invite_landing(request, code: str):
    """GET /i/<code>/ — public invite landing page."""
    User = get_user_model()
    try:
        user = User.objects.select_related('account').get(invite_code=code)
    except User.DoesNotExist:
        raise Http404('Unknown invite link.')

    who = html.escape(_inviter_display_name(user))
    download_url = html.escape(getattr(settings, 'APP_DOWNLOAD_URL', '') or '#')
    # The rendered card, not the one static image INVITE_OG_IMAGE_URL used to
    # serve: the invite is an acquisition surface and a card that names the
    # person inviting you is the whole difference. The setting stays as an
    # override for anyone who wants a fixed image back.
    og_image = html.escape(
        getattr(settings, 'INVITE_OG_IMAGE_URL', '')
        or request.build_absolute_uri(
            reverse('invite-card', args=[code]))
    )
    page_url = html.escape(request.build_absolute_uri())
    og_title = f"{who} invited you to Halved"
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
    <h1>{who} invited you to Halved</h1>
    <p>Halved is the easiest way to track golf bets — skins, nassau, points and
       more — with your group, right from your phone.</p>
    <a class="btn" href="{download_url}">Get the app</a>
  </div>
</body>
</html>"""
    return HttpResponse(page)
