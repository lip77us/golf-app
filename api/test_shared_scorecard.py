"""
api/test_shared_scorecard.py
----------------------------
The shared scorecard page (handoff-shared-scorecard) — what a link.halved.golf
tap opens, replacing the PNG the app used to text.

Pins the five things that were wrong with the PNG, so they cannot come back:
one name per golfer, the match titled rather than the venue, no duplicate net
table, a back nine that does not show fifteen empty columns, and Halved
actually present.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Round, Foursome, FoursomeMembership

from scoring.tests._helpers import DEFAULT_HOLES

User = get_user_model()


class SharedScorecardTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.host = Player.objects.create(
            account=self.acct, name='Paul Lipkin', handicap_index=4)
        self.course = Course.objects.create(account=self.acct, name='Tilden Park GC')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=DEFAULT_HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
            created_by=self.host, primary_game='nassau')
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = []

    def _add(self, name, hcp=10):
        p = Player.objects.create(account=self.acct, name=name, handicap_index=hcp)
        FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=hcp, playing_handicap=hcp)
        self.players.append(p)
        return p

    def _score(self, player, hole, gross):
        HoleScore.objects.create(foursome=self.fs, player=player,
                                 hole_number=hole, gross_score=gross)

    @property
    def _url(self):
        return f'/watch/{self.round.watch_token}/scorecard/'

    # ── access ──────────────────────────────────────────────────────────────

    def test_no_auth_required(self):
        """The share id is the credential."""
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        self.assertEqual(self.client.get(self._url).status_code, 200)

    def test_unknown_token_404s(self):
        self.assertEqual(
            self.client.get('/watch/nope/scorecard/').status_code, 404)

    # ── the five complaints ─────────────────────────────────────────────────

    def test_singles_titles_the_match_not_the_venue(self):
        from services.shared_scorecard import build_page
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        self.assertEqual(build_page(self.fs)['title'], 'Wendel vs Paul')

    def test_larger_group_titles_the_host(self):
        from services.shared_scorecard import build_page
        for n in ('Wendel Doman', 'Paul Lipkin', 'Ed Seputis'):
            self._add(n)
        self.assertEqual(build_page(self.fs)['title'],
                         'Paul’s round at Tilden Park GC')

    def test_one_name_per_golfer_title_and_grid_agree(self):
        """The PNG said 'Paul L.' in the grid and 'Paul Lipkin' in the table."""
        from services.shared_scorecard import build_page
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        page = build_page(self.fs)
        grid_names = {r['name'] for r in page['rows']}
        for n in grid_names:
            self.assertIn(n, page['title'])

    def test_last_initial_only_when_first_names_collide(self):
        from services.shared_scorecard import familiar_names
        self.assertEqual(familiar_names(['Paul Lipkin', 'Ed Seputis']),
                         {'Paul Lipkin': 'Paul', 'Ed Seputis': 'Ed'})
        self.assertEqual(familiar_names(['Paul Lipkin', 'Paul Sanders']),
                         {'Paul Lipkin': 'Paul L.', 'Paul Sanders': 'Paul S.'})

    def test_back_nine_collapsed_until_a_score_lands_on_ten(self):
        """Fifteen dash columns made a live match look abandoned."""
        from services.shared_scorecard import build_page
        a = self._add('Wendel Doman'); self._add('Paul Lipkin')
        for h in (1, 2, 3):
            self._score(a, h, 5)
        self.assertFalse(build_page(self.fs)['back_started'])
        self._score(a, 10, 4)
        self.assertTrue(build_page(self.fs)['back_started'])

    def test_halved_is_on_the_page(self):
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        html = self.client.get(self._url).content.decode()
        self.assertIn('HALVED', html)
        self.assertIn('Get Halved free', html)
        self.assertIn('Keep following live', html)

    def test_no_separate_net_table_just_a_mode(self):
        """Gross and Net are one grid behind a selector, not two tables."""
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        html = self.client.get(self._url).content.decode()
        self.assertIn('mode=net', html)
        self.assertEqual(html.count('class="grid'), html.count('gridscroll'))

    # ── the grid ────────────────────────────────────────────────────────────

    def test_unplayed_hole_is_blank_not_a_dash(self):
        from services.shared_scorecard import build_page
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        page = build_page(self.fs)
        self.assertTrue(all(c['value'] is None for c in page['rows'][0]['cells']))
        html = self.client.get(self._url).content.decode()
        i = html.find('FRONT')
        self.assertNotIn('–', html[i:i + 2000])

    def test_net_mode_reads_stored_net_not_a_recomputation(self):
        from services.shared_scorecard import build_page
        a = self._add('Wendel Doman'); self._add('Paul Lipkin')
        self._score(a, 1, 6)
        hs = HoleScore.objects.get(foursome=self.fs, player=a, hole_number=1)
        gross = build_page(self.fs, mode='gross')['rows'][0]['cells'][0]['value']
        net   = build_page(self.fs, mode='net')['rows'][0]['cells'][0]['value']
        self.assertEqual(gross, hs.gross_score)
        self.assertEqual(net,   hs.net_score)

    def test_score_notation(self):
        from services.shared_scorecard import score_class
        self.assertEqual(score_class(3, 4), 'birdie')
        self.assertEqual(score_class(2, 4), 'eagle')
        self.assertEqual(score_class(4, 4), '')
        self.assertEqual(score_class(5, 4), 'bogey')
        self.assertEqual(score_class(6, 4), 'double')
        self.assertEqual(score_class(None, 4), '')

    # ── the app shares this link ────────────────────────────────────────────

    def test_scorecard_payload_carries_the_share_url(self):
        from api.views import _build_scorecard
        self._add('Wendel Doman'); self._add('Paul Lipkin')
        url = _build_scorecard(self.fs)['share_url']
        self.assertIn(f'/watch/{self.round.watch_token}/scorecard/', url)
        self.assertIn('g=1', url)
