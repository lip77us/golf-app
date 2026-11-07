"""The public receipt — settle-up handoff §1, the "web" and "image" surfaces.

The payload here is the handoff's own worked casual example (the Round over
mock), so these pin the SPEC rather than the implementation.
"""
import io

from django.test import SimpleTestCase, TestCase
from django.urls import reverse
from PIL import Image

from scoring.tests._helpers import make_round
from services.receipt_ticket import receipt_page_html, stamp, ticket_html
from tournament.models import Receipt

CASUAL = {
    'title': 'Nassau + Skins',
    'sub': 'Tilden Park GC · Nov 4 · $10 a match · $2 a skin',
    'nets': [
        {'name': 'Paul', 'net': 2600, 'caption': '88 · net 76'},
        {'name': 'Dave', 'net': 1000, 'caption': '84 · net 76'},
        {'name': 'Sam',  'net': -1800, 'caption': '90 · net 75'},
        {'name': 'Mike', 'net': -1800, 'caption': '86 · net 76'},
    ],
    'pays': [
        {'from': 'Sam',  'to': 'Paul', 'amount': 1800},
        {'from': 'Mike', 'to': 'Dave', 'amount': 1000},
        {'from': 'Mike', 'to': 'Paul', 'amount': 800},
    ],
    'games': [{'label': 'The games',
               'rows': [['Nassau', 'Lipkin/Kim 1 UP'],
                        ['Skins', 'Lipkin 4 · Kim 2']]}],
    'scorer': {'name': 'Paul Kelly', 'initials': 'PK'},
    'settledAt': '2026-11-04T14:58:00+00:00',
    'url': 'halved.golf/r/7KQ2',
}


class TicketTests(SimpleTestCase):

    def test_nets_are_signed_and_transfers_are_not(self):
        """The mock is explicit: chips read +$26 / −$18, transfer lines read
        $18.  A transfer has a direction already — the two names and the arrow
        — so a sign on it would state it twice."""
        html = ticket_html(CASUAL)
        self.assertIn('+$26', html)
        self.assertIn('−$18', html)
        self.assertIn('>$18<', html)
        self.assertNotIn('+$18', html)

    def test_a_down_chip_is_marked_for_coral(self):
        html = ticket_html(CASUAL)
        self.assertIn('class="dn"', html)

    def test_the_web_surface_prefers_webGames(self):
        """§1: the web receipt uses webGames WHEN PRESENT."""
        payload = dict(CASUAL, webGames=[
            {'label': 'Skins by hole', 'rows': [['Hole 7', 'Kim x3']]}])
        self.assertIn('Skins by hole', ticket_html(payload, 'web'))

    def test_it_falls_back_to_games_when_there_is_no_long_form(self):
        """A game that never wrote a long form still renders, rather than the
        web receipt losing its games section entirely."""
        self.assertIn('The games', ticket_html(CASUAL, 'web'))

    def test_the_image_collapses_and_the_web_does_not(self):
        """§1 caps the preview at four chips, three transfer lines and the
        first section's first two rows.  The web receipt showing everything is
        the reason the link exists."""
        big = dict(CASUAL,
                   nets=[{'name': f'G{i}', 'net': 0} for i in range(9)],
                   pays=[{'from': 'a', 'to': f'b{i}', 'amount': 100}
                         for i in range(7)],
                   games=[{'label': 'The games',
                           'rows': [[f'r{i}', 'v'] for i in range(6)]},
                          {'label': 'Second', 'rows': [['x', 'y']]}])
        image = ticket_html(big, 'image')
        self.assertEqual(image.count('class="hr-nc"'), 1)
        self.assertEqual(image.count('<div><span><i>'), 3)
        self.assertNotIn('Second', image)
        self.assertEqual(image.count('<span>r'), 2)
        web = ticket_html(big, 'web')
        self.assertEqual(web.count('<div><span><i>'), 7)
        self.assertIn('Second', web)

    def test_a_string_amount_passes_through(self):
        """§3 types amount as Cents | string for rows like "4 x $71.87" and
        the preview's collapsed "14 more", which carry their own formatting."""
        payload = dict(CASUAL, pays=[{'from': 'TD', 'to': '14 more',
                                      'amount': '$1,114'}])
        self.assertIn('$1,114', ticket_html(payload))

    def test_a_golfers_name_cannot_inject_markup(self):
        """Names are free text typed by a user and this is a public page."""
        payload = dict(CASUAL, title='<script>x</script>',
                       nets=[{'name': '<b>Sam</b>', 'net': 0, 'caption': ''}])
        html = ticket_html(payload)
        self.assertNotIn('<script>', html)
        self.assertNotIn('<b>Sam</b>', html)
        self.assertIn('&lt;script&gt;', html)


class StampTests(SimpleTestCase):

    def test_the_handoffs_own_stamp(self):
        self.assertEqual(stamp(CASUAL), 'Final · settled 2:58 PM by Paul Kelly')

    def test_final_is_not_claimed_without_a_settled_time(self):
        """"Final" is a claim.  A receipt with no settledAt has not been
        settled, and stamping it anyway tells a golfer the money is done on
        the strength of a missing field."""
        self.assertEqual(stamp({'scorer': {'name': 'Paul Kelly'}}), '')


class PageTests(SimpleTestCase):

    def test_no_phone_frame_or_fake_browser_chrome(self):
        """patterns/receipt-ticket.js wraps every surface in a phone with a
        status bar and an address bar reading halved.golf, because it is a
        prototype showing a phone.  On the real page that would be a picture
        of a browser inside a browser."""
        html = receipt_page_html(CASUAL)
        # 'hr-st' is NOT checked: it is a prefix of hr-stamp, which the page
        # legitimately has.  A substring assertion that matches the thing it
        # is meant to allow is a test that fails for being right.
        for scaffolding in ('hr-ph', 'hr-sf', '●●●', 'halved.golf</div>'):
            self.assertNotIn(scaffolding, html)

    def test_no_venmo_or_cash_app(self):
        """§1 says so outright, and the handoff's own open note defers the
        payment handoff — payment is not tracked."""
        html = receipt_page_html(CASUAL).lower()
        self.assertNotIn('venmo', html)
        self.assertNotIn('cash app', html)

    def test_the_scorecard_link_is_drawn_only_when_there_is_one(self):
        """A link to nothing reads as broken rather than as not offered."""
        self.assertNotIn('Hole-by-hole', receipt_page_html(CASUAL))
        self.assertIn('Hole-by-hole', receipt_page_html(
            CASUAL, scorecard_url='https://halved.golf/x/'))

    def test_the_cta_and_stamp_are_there(self):
        html = receipt_page_html(CASUAL, download_url='https://apps.apple.com/x')
        self.assertIn('Run the next game yourself', html)
        self.assertIn('Get Halved', html)
        self.assertIn('https://apps.apple.com/x', html)
        self.assertIn('Final · settled 2:58 PM by Paul Kelly', html)


class CardTests(SimpleTestCase):

    def test_it_is_the_declared_og_image_size(self):
        """1080x1350, which the page declares in og:image:width/height — a
        client that is told one size and served another crops it."""
        from services.receipt_card import render_receipt_card
        im = Image.open(io.BytesIO(render_receipt_card(CASUAL)))
        self.assertEqual(im.size, (1080, 1350))

    def test_the_ticket_hugs_its_content(self):
        """Stretching it to the footer leaves a slab of dead ink under the
        last row.  The height is computed from named parts that the layout
        then spends; this is what catches the two drifting apart."""
        from services.receipt_card import render_receipt_card, INK, S
        for label, payload in (('casual', CASUAL),
                               ('one chip', {'title': 'Skins', 'sub': 'x',
                                             'nets': [{'name': 'A', 'net': 100}],
                                             'pays': [], 'games': []})):
            with self.subTest(label):
                im = Image.open(
                    io.BytesIO(render_receipt_card(payload))).convert('RGB')
                mid = im.width // 2
                rows = [y for y in range(im.height)
                        if im.getpixel((mid, y)) == INK]
                bottom = rows[-1]
                # TEXT, by luminance.  Two cheaper tests were wrong: sampling
                # the full width catches the ticket's own rounded corners
                # showing ground, and a narrow mid window misses a
                # right-aligned value.  A chip's mint border blends to ~78,
                # so 90 separates type from furniture.
                last = max(y for y in range(rows[0], bottom)
                           if any(sum(im.getpixel((px, y))) / 3 > 90
                                  for px in range(110, im.width - 110, 2)))
                self.assertLess(bottom - last, 25 * S,
                                f'{label}: dead ink under the last row')

    def test_a_shorter_receipt_still_renders(self):
        from services.receipt_card import render_receipt_card
        im = Image.open(io.BytesIO(render_receipt_card(
            {'title': 'Skins', 'sub': 'x', 'nets': [], 'pays': []})))
        self.assertEqual(im.size, (1080, 1350))


class RouteTests(TestCase):

    def setUp(self):
        self.round = make_round()
        self.receipt = Receipt.objects.create(
            payload=CASUAL, settled_at='2026-11-04T14:58:00+00:00',
            round=self.round)

    def test_exactly_one_parent_is_required(self):
        """A receipt belongs to a round OR a tournament, the same split
        SettlementSend carries.  Neither is not a receipt of anything."""
        from django.db import IntegrityError, transaction
        with self.assertRaises(IntegrityError), transaction.atomic():
            Receipt.objects.create(payload={},
                                   settled_at='2026-11-04T14:58:00+00:00')

    def test_the_code_is_minted_and_usable(self):
        self.assertEqual(len(self.receipt.code), 8)
        self.assertNotIn('0', self.receipt.code)
        self.assertNotIn('1', self.receipt.code)

    def test_the_page_serves_the_frozen_payload(self):
        resp = self.client.get(reverse('receipt-page', args=[self.receipt.code]))
        self.assertEqual(resp.status_code, 200)
        body = resp.content.decode()
        self.assertIn('Nassau + Skins', body)
        self.assertIn('+$26', body)
        self.assertIn('Final · settled', body)

    def test_it_declares_the_card_as_its_og_image(self):
        resp = self.client.get(reverse('receipt-page', args=[self.receipt.code]))
        body = resp.content.decode()
        self.assertIn('og:image', body)
        self.assertIn(f'/r/{self.receipt.code}/card.png', body)
        self.assertIn('content="1080"', body)
        self.assertIn('content="1350"', body)

    def test_an_unknown_code_is_a_404_and_not_a_blank_receipt(self):
        self.assertEqual(self.client.get('/r/ZZZZZZZZ/').status_code, 404)

    def test_the_card_route_serves_a_png(self):
        resp = self.client.get(reverse('receipt-card', args=[self.receipt.code]))
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp['Content-Type'], 'image/png')
        self.assertEqual(Image.open(io.BytesIO(resp.content)).size, (1080, 1350))

    def test_it_needs_no_sign_in(self):
        """Possession-gated, like the watch page: §1 texts this link to
        golfers who are not in the app and have no account to authorise."""
        self.assertEqual(
            self.client.get(reverse('receipt-page',
                                    args=[self.receipt.code])).status_code, 200)
