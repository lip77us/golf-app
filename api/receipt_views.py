"""The public receipt at ``halved.golf/r/<code>`` — settle-up handoff §1.

**Possession-gated, like the watch page and the invite landing.**  Anybody
holding the link sees it, because that is what the link is FOR: §1 texts it to
golfers who are not in the app and have no account to be authorised against.
The code is 8 base32-ish characters from a 32-character alphabet, so guessing
one is not a route in.

**It serves the frozen payload and computes nothing.**  Every other board in
this app is derived on read; a receipt is the opposite, and
:class:`tournament.models.Receipt` carries the reason.
"""
from django.conf import settings
from django.http import Http404, HttpResponse
from django.urls import reverse

from services.receipt_ticket import receipt_page_html
from tournament.models import Receipt


def _receipt(code: str) -> Receipt:
    try:
        return Receipt.objects.select_related('scorer').get(code=code)
    except Receipt.DoesNotExist:
        raise Http404('Unknown receipt link.')


def receipt_page(request, code: str):
    """GET /r/<code>/ — the web receipt."""
    receipt = _receipt(code)
    return HttpResponse(receipt_page_html(
        receipt.payload or {},
        page_url=request.build_absolute_uri(),
        card_url=request.build_absolute_uri(
            reverse('receipt-card', args=[code])),
        download_url=getattr(settings, 'APP_DOWNLOAD_URL', '') or '#',
        scorecard_url=(receipt.payload or {}).get('scorecardUrl', ''),
    ))


def receipt_card_png(request, code: str):
    """GET /r/<code>/card.png — the 1080x1350 link preview (§1).

    Cached rather than stored: the payload is frozen, so the card drawn from
    it is too, and a render is milliseconds.  The cache key carries the code
    alone for that reason — there is no version of a receipt to miss.
    """
    from django.core.cache import cache

    receipt = _receipt(code)
    key = f'receipt-card:{code}'
    png = cache.get(key)
    if png is None:
        from services.receipt_card import render_receipt_card
        png = render_receipt_card(receipt.payload or {})
        cache.set(key, png, 60 * 60 * 24)
    resp = HttpResponse(png, content_type='image/png')
    resp['Cache-Control'] = 'public, max-age=86400'
    return resp
