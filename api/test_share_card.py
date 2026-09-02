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
        self.assertEqual(ctx['pill'], 'LIVE')
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
        self.assertEqual(ctx['pill'], 'FINAL')
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


# ---------------------------------------------------------------------------
# The invite card — same template, no round behind it
# (handoff-share-link-cards)
# ---------------------------------------------------------------------------

class InviteCardTests(TestCase):
    """The invite link is the other half of the acquisition surface.

    It used to serve one static square icon, which is the gray-row problem the
    watch card was built to solve, one link over.
    """

    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.player = Player.objects.create(
            account=self.acct, name='Paul Lipkin', handicap_index=4)
        self.user.player_profile = self.player
        self.user.save()
        self.code = self.user.ensure_invite_code()

    def test_the_card_is_a_1200x630_png_and_needs_no_auth(self):
        from PIL import Image
        resp = self.client.get(f'/i/{self.code}/card.png')
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp['Content-Type'], 'image/png')
        self.assertEqual(Image.open(io.BytesIO(resp.content)).size, (1200, 630))

    def test_an_unknown_code_is_404_not_a_card(self):
        self.assertEqual(self.client.get('/i/nope/card.png').status_code, 404)

    def test_it_names_the_person_inviting_you(self):
        from services.share_card import build_invite_context
        ctx = build_invite_context(self.user)
        self.assertEqual(ctx['title'], 'Paul Lipkin invited you to Halved')
        self.assertEqual(ctx['action'], 'Get the app')

    def test_the_pill_says_invite_and_takes_no_dot(self):
        """Nothing about an invite is live, and a mint dot would claim it is."""
        from services.share_card import build_invite_context
        ctx = build_invite_context(self.user)
        self.assertEqual(ctx['pill'], 'INVITE')
        self.assertFalse(ctx['is_live'])

    def test_a_nameless_inviter_still_gets_a_card(self):
        """The fallback is never 'no image'."""
        from services.share_card import build_invite_context, render_card
        bare = User.objects.create_user(username='ghost', account=self.acct)
        ctx = build_invite_context(bare)
        self.assertNotIn('None', ctx['title'])
        self.assertTrue(ctx['title'])
        self.assertTrue(render_card(ctx))

    def test_the_landing_page_points_og_image_at_the_rendered_card(self):
        """Not the static icon it used to serve."""
        with self.settings(INVITE_OG_IMAGE_URL=''):
            body = self.client.get(f'/i/{self.code}/').content.decode()
        self.assertIn(f'/i/{self.code}/card.png', body)

    def test_the_setting_still_overrides(self):
        with self.settings(INVITE_OG_IMAGE_URL='https://example.com/fixed.png'):
            body = self.client.get(f'/i/{self.code}/').content.decode()
        self.assertIn('https://example.com/fixed.png', body)


class TitleWrapTests(TestCase):
    """The title wraps to two lines rather than shrinking to one.

    The handoff's answer to a long course name is to truncate it server-side.
    A card that breaks because someone typed a long name is still a broken
    card, so this degrades instead — and must never overflow the block.
    """

    def _lines(self, title, **kw):
        from PIL import Image, ImageDraw
        from services.share_card import _title_block
        d = ImageDraw.Draw(Image.new('RGB', (1200, 630)))
        return _title_block(d, title, **kw)

    def test_a_short_title_stays_at_full_size_on_one_line(self):
        font, lines = self._lines('Skins at Tilden')
        self.assertEqual(len(lines), 1)
        self.assertEqual(font.size, 60)

    def test_a_normal_title_wraps_to_two_lines_at_full_size(self):
        font, lines = self._lines('Paul’s Skins at Tilden Park GC')
        self.assertEqual(len(lines), 2)
        self.assertEqual(font.size, 60)

    def test_a_long_title_shrinks_to_fit_two_lines_rather_than_truncating(self):
        title = 'Alexander’s Triple Nassau at Corica Park — South Course'
        font, lines = self._lines(title)
        self.assertEqual(len(lines), 2)
        self.assertLess(font.size, 60)
        self.assertNotIn('…', ' '.join(lines))
        # Every word survived, in order.
        self.assertEqual(' '.join(lines).split(), title.split())

    def test_an_absurd_title_ellipsises_rather_than_overflowing(self):
        font, lines = self._lines('Wolf ' * 60)
        self.assertEqual(len(lines), 2)
        self.assertTrue(lines[-1].endswith('…'))

    def test_no_word_is_ever_broken_mid_way(self):
        """A mid-word break reads as corruption, not as a long name."""
        title = 'Bartholomew’s Stableford at Kingsbarns Championship Links'
        _, lines = self._lines(title)
        for word in ' '.join(lines).replace('…', '').split():
            self.assertTrue(
                any(word in original for original in title.split()),
                f'{word!r} is not a whole word from the title')


class FinishedRoundCopyTests(TestCase):
    """A finished round must not promise something live anywhere on the card.

    The pill was already guarded; the footer's call to action was not, and
    "Watch live" on a round from last Tuesday makes the same false promise —
    the tap behind it lands on a scorecard.
    """

    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.host = Player.objects.create(
            account=self.acct, name='Paul Lipkin', handicap_index=4)
        self.course = Course.objects.create(account=self.acct, name='Tilden Park GC')
        self.round = Round.objects.create(
            account=self.acct, course=self.course, created_by=self.host,
            active_games=['skins'], status='complete')

    def test_a_finished_round_offers_the_result_not_a_live_board(self):
        from services.share_card import build_context
        ctx = build_context(self.round)
        self.assertEqual(ctx['pill'], 'FINAL')
        self.assertFalse(ctx['is_live'])
        self.assertNotIn('live', ctx['action'].lower())

    def test_a_round_in_progress_still_says_watch_live(self):
        from services.share_card import build_context
        self.round.status = 'in_progress'
        self.round.save(update_fields=['status'])
        self.assertEqual(build_context(self.round)['action'], 'Watch live')
