"""
api/test_share_card.py
----------------------
The Open Graph share card (handoff-share-round, deliverable B).

The link is an acquisition surface: it routinely lands with someone who has
never heard of Halved. Before this it arrived as a gray row with the client's
own compass glyph, because the page emitted no og:image at all.

Pins the contract a link-preview crawler depends on: the tags exist, the
image is a real 1200x630 PNG served without a credential, a finished round
does not claim to be LIVE, and the title uses the game's public name.
"""
from decimal import Decimal
import io

from django.contrib.auth import get_user_model
from django.test import TestCase

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Round, Foursome, FoursomeMembership

from scoring.tests._helpers import DEFAULT_HOLES

User = get_user_model()


class ShareCardTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='paul', account=self.acct)
        # Round.created_by is a Player, not a User.
        self.host = Player.objects.create(
            account=self.acct, name='Paul Lipkin', handicap_index=4)
        self.course = Course.objects.create(account=self.acct, name='Tilden Park GC')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=DEFAULT_HOLES,
        )
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
            created_by=self.host, primary_game='nassau',
        )
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = []
        for i in range(4):
            p = Player.objects.create(
                account=self.acct, name=f'P{i}', handicap_index=10)
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=10, playing_handicap=10)
            self.players.append(p)

    def _score_through(self, hole: int):
        for h in range(1, hole + 1):
            for p in self.players:
                HoleScore.objects.create(
                    foursome=self.fs, player=p, hole_number=h, gross_score=4)

    @property
    def _url(self):
        return f'/watch/{self.round.watch_token}/card.png'

    # ── the image ───────────────────────────────────────────────────────────

    def test_card_is_a_1200x630_png_and_needs_no_auth(self):
        """The crawler that fetches this carries no credential."""
        r = self.client.get(self._url)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r['Content-Type'], 'image/png')
        from PIL import Image
        img = Image.open(io.BytesIO(r.content))
        self.assertEqual(img.size, (1200, 630))

    def test_unknown_token_is_404_not_a_card(self):
        self.assertEqual(self.client.get('/watch/nope/card.png').status_code, 404)

    def test_card_renders_before_any_score_exists(self):
        """Never fall back to no image -- that is the gray card again."""
        self.assertEqual(HoleScore.objects.count(), 0)
        self.assertEqual(self.client.get(self._url).status_code, 200)

    # ── what it says ────────────────────────────────────────────────────────

    def test_live_while_in_progress(self):
        from services.share_card import build_context
        self._score_through(7)
        ctx = build_context(self.round)
        self.assertEqual(ctx['state_label'], 'LIVE')
        self.assertTrue(ctx['is_live'])
        self.assertEqual(ctx['thru'], 7)
        self.assertIn('Thru 7', ctx['meta'])

    def test_completed_round_never_claims_to_be_live(self):
        """A card saying LIVE on a round from last Tuesday is worse than none."""
        from services.share_card import build_context
        self._score_through(18)
        self.round.status = 'complete'
        self.round.save(update_fields=['status'])
        ctx = build_context(self.round)
        self.assertEqual(ctx['state_label'], 'FINAL')
        self.assertFalse(ctx['is_live'])

    def test_title_names_host_game_and_course(self):
        from services.share_card import build_context
        self.assertEqual(build_context(self.round)['title'],
                         'Paul’s Nassau at Tilden Park GC')

    def test_title_uses_the_public_game_name(self):
        """Not GameType.label -- 'Low Net (Round)' must never reach a card."""
        from services.share_card import build_context
        self.round.primary_game = 'low_net_round'
        self.round.save(update_fields=['primary_game'])
        title = build_context(self.round)['title']
        self.assertIn('Stroke Play', title)
        self.assertNotIn('(', title)

    def test_title_degrades_rather_than_dangling(self):
        from services.share_card import build_context
        self.round.primary_game = ''
        self.round.active_games = []
        self.round.created_by = None
        self.round.save(update_fields=['primary_game', 'active_games', 'created_by'])
        self.assertEqual(build_context(self.round)['title'],
                         'A round at Tilden Park GC')

    # ── the tags ────────────────────────────────────────────────────────────

    def test_watch_page_emits_the_open_graph_block(self):
        html = self.client.get(f'/watch/{self.round.watch_token}/').content.decode()
        for needle in ('property="og:title"', 'property="og:image"',
                       'property="og:url"', 'name="twitter:card"',
                       'content="summary_large_image"',
                       'property="og:image:width"'):
            self.assertIn(needle, html, f'missing {needle}')

    def test_og_image_points_at_the_card(self):
        from api.watch_views import share_meta
        meta = share_meta(self.round)
        self.assertTrue(meta['og_image'].endswith(
            f'/watch/{self.round.watch_token}/card.png'))
        self.assertEqual(meta['og_title'], 'Paul’s Nassau at Tilden Park GC')
