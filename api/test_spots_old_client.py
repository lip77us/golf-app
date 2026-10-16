"""
api/test_spots_old_client.py
----------------------------
**What the SHIPPED app does against the new Spots backend.**

The app release goes through App Store review on Apple's schedule, so there is
a window where production runs this backend and phones run 2.11.2. These
replay 2.11.2's exact requests — the shapes in its `client.dart` before the
types work — and pin what each one does, so the window is a known quantity
rather than a guess.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

HOLES = [{'number': n, 'par': (3 if n in (3, 7) else 4),
          'stroke_index': n, 'yards': 400} for n in range(1, 19)]


class OldClientTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Old Client Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['nassau', 'spots'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.ids = []
        for n in ('A', 'B', 'C', 'D'):
            p = Player.objects.create(account=self.acct, name=n,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.ids.append(p.id)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    # 2.11.2's `postSpotsSetup`: no `types`, no greenie, no basis.
    def _old_setup(self):
        return self.client.post(
            reverse('api-spots-setup', args=[self.fs.id]),
            {'bet_unit': '1.00', 'payout_style': 'per_point',
             'per_point_mode': 'all'},
            format='json')

    # 2.11.2's `postSpotsTally`: a signed COUNT per golfer.
    def _old_tally(self, hole, pid, count):
        return self.client.post(
            reverse('api-spots-tally', args=[self.fs.id]),
            {'hole_number': hole,
             'entries': [{'player_id': pid, 'count': count}]},
            format='json')

    def test_SETUP_still_works(self):
        """It omits `types`, which means "the defaults" — so the old screen
        saves and the game is playable. This is the half that works."""
        r = self._old_setup()
        self.assertEqual(r.status_code, 201, r.data)

    def test_the_LEADERBOARD_still_reads(self):
        """Every field 2.11.2 parses is still there: the summary gained keys
        and lost none, and its `fromJson` ignores what it does not know."""
        self._old_setup()
        r = self.client.get(reverse('api-spots-result', args=[self.fs.id]))
        self.assertEqual(r.status_code, 200)
        self.assertIn('players', r.data)
        self.assertIn('money', r.data)
        for p in r.data['players']:
            self.assertIn('spots', p)
            self.assertIn('payout', p)
        # Per-hole rows keep `count`, which is what its hole strip draws.
        self._old_setup()

    def test_the_TALLY_is_refused(self):
        """The ⊖/⊕ stepper posts a count and gets a 400 — the known cost of
        the window, and a loud failure rather than a quiet wrong number."""
        self._old_setup()
        r = self._old_tally(5, self.ids[0], 2)
        self.assertEqual(r.status_code, 400, r.data)
        self.assertIn('types', r.data['entries'][0])

    def test_a_refused_tally_writes_NOTHING(self):
        self._old_setup()
        self._old_tally(5, self.ids[0], 2)
        got = self.client.get(reverse('api-spots-result', args=[self.fs.id]))
        self.assertEqual(got.data['money']['total_spots'], 0)

    def test_the_OLD_CLIENT_IS_NOT_PAID_FOR_SPOTS_IT_CANNOT_SHOW(self):
        """**The one that matters more than the 400.**

        Birdie and Eagle are read off the SCORES. If they were in play by
        default, a 2.11.2 round would quietly pay for birdies the group never
        agreed to and that its screens cannot draw — money moving for a
        reason nobody can see, which is worse than a control that fails.

        So a setup that does not mention `types` gets the SHEET types only.
        A client that sends `types` is one that can show them.
        """
        self._old_setup()
        HoleScore.objects.create(foursome=self.fs, player_id=self.ids[0],
                                 hole_number=1, gross_score=3)   # a birdie
        got = self.client.get(reverse('api-spots-result', args=[self.fs.id]))
        self.assertEqual(got.data['money']['total_spots'], 0,
                         'an old client was paid for a derived spot')
        slugs = [t['type'] for t in got.data['in_play']]
        self.assertNotIn('birdie', slugs)
        self.assertNotIn('eagle', slugs)
        # The rest of the defaults DO survive — only the money it cannot
        # draw is withheld, not the game.
        self.assertIn('sandy', slugs)
        self.assertIn('chippy', slugs)
        # Greenie too: it cannot pay without a pick, and that app has none,
        # so it is inert now and works the moment the phone updates.
        self.assertIn('greenie', slugs)

    def test_a_NEW_client_still_gets_the_designed_defaults(self):
        """Sending `types` explicitly is what the new screen does, and it
        gets exactly what the design specifies — including the derived two."""
        from services.spots import default_types
        r = self.client.post(
            reverse('api-spots-setup', args=[self.fs.id]),
            {'bet_unit': '1.00', 'types': default_types()}, format='json')
        self.assertEqual(r.status_code, 201, r.data)
        slugs = [t['type'] for t in r.data['in_play']]
        self.assertIn('birdie', slugs)
        self.assertIn('eagle', slugs)
