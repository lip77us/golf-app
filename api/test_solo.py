"""The solo endpoints.

One golfer against par. The engine is covered in scoring/tests/test_solo.py;
these cover the wire: that the setup round-trips, that the board is readable,
and that nothing about money or a handicap mode can be posted — because a
solo game that grew a stake would be a different product.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from games.models import SoloGame
from tournament.models import Foursome, FoursomeMembership, Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('72.0'),
                                      par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, round_number=1,
            status='in_progress', active_games=['solo_stroke'])
        fs = Foursome.objects.create(round=self.round, group_number=1)
        p = Player.objects.create(account=self.acct, name='Paul',
                                  handicap_index=Decimal('12'))
        FoursomeMembership.objects.create(foursome=fs, player=p, tee=self.tee,
                                          course_handicap=12,
                                          playing_handicap=12)

    def _setup_url(self):
        return reverse('api-solo-setup', args=[self.round.id])

    def _result_url(self):
        return reverse('api-solo-result', args=[self.round.id])


class SetupTests(_Base):
    def test_defaults_before_anything_is_configured(self):
        d = self.client.get(self._setup_url()).data
        self.assertFalse(d['configured'])
        self.assertEqual(d['variant'], 'stroke')
        self.assertEqual(d['net_percent'], 100)

    def test_it_names_the_FOURSOME_so_start_round_can_open_it(self):
        """Score entry is addressed by foursome. Without this the screen
        reached for the round id, which is a different number — and on a
        server with more rounds than this one it points at somebody else's
        group."""
        d = self.client.get(self._setup_url()).data
        self.assertEqual(d['foursome_id'],
                         self.round.foursomes.first().id)

    def test_it_names_the_golfer_for_the_setup_screen(self):
        """So the screen can write "12 strokes" without a second request."""
        d = self.client.get(self._setup_url()).data
        self.assertEqual(d['player_name'], 'Paul')
        self.assertEqual(d['course_handicap'], 12)
        self.assertEqual(d['tee_name'], 'White')

    def test_configure_round_trips(self):
        r = self.client.post(self._setup_url(),
                             {'variant': 'nassau', 'net_percent': 90},
                             format='json')
        self.assertEqual(r.status_code, 201, r.content)
        d = self.client.get(self._setup_url()).data
        self.assertTrue(d['configured'])
        self.assertEqual(d['variant'], 'nassau')
        self.assertEqual(d['net_percent'], 90)

    def test_an_allowance_above_100_is_accepted(self):
        """Deliberate, and unique in the app. Nobody is paying."""
        r = self.client.post(self._setup_url(),
                             {'variant': 'stroke', 'net_percent': 130},
                             format='json')
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(SoloGame.objects.get().net_percent, 130)

    def test_an_absurd_allowance_is_refused(self):
        for pct in (0, 10, 40, 140, 200):
            r = self.client.post(self._setup_url(),
                                 {'variant': 'stroke', 'net_percent': pct},
                                 format='json')
            self.assertEqual(r.status_code, 400, f'{pct} should be refused')

    def test_there_is_no_handicap_mode_to_set(self):
        """Always net. Posting one is ignored rather than honoured — a gross
        solo game against par is stroke play with extra words."""
        self.client.post(self._setup_url(),
                         {'variant': 'stroke', 'net_percent': 100,
                          'handicap_mode': 'gross'}, format='json')
        cfg = SoloGame.objects.get()
        self.assertFalse(hasattr(cfg, 'handicap_mode'))

    def test_there_is_nothing_to_stake(self):
        self.client.post(self._setup_url(),
                         {'variant': 'stroke', 'net_percent': 100,
                          'entry_fee': 20}, format='json')
        cfg = SoloGame.objects.get()
        for field in ('entry_fee', 'payouts', 'bet_unit'):
            self.assertFalse(hasattr(cfg, field),
                             msg=f'a solo game has no {field}')


class OneGolferIsARoundTests(_Base):
    """The draw a solo round needs: one golfer, one group, no phantom.

    `RoundSetupSerializer.players` had `min_length=2`, so creating a solo
    round died on the Tees step with `non_field_errors: Ensure this field has
    at least 2 elements` — a message naming neither the field nor the rule,
    on a screen about tee boxes. Reported from the picker the day solo
    shipped.
    """

    def test_a_round_can_be_set_up_for_one(self):
        rnd = Round.objects.create(
            account=self.acct, course=self.round.course, round_number=2,
            status='pending', active_games=['solo_stroke'])
        p = Player.objects.get(name='Paul')
        r = self.client.post(
            reverse('api-round-setup', args=[rnd.id]),
            {'players': [{'player_id': p.id, 'tee_id': self.tee.id}]},
            format='json')
        self.assertEqual(r.status_code, 201, r.content)
        fs = rnd.foursomes.get()
        self.assertEqual(fs.memberships.count(), 1)

    def test_nobody_is_invented_to_fill_the_group(self):
        """A casual round never pads, and par is not a player — a phantom
        here would be a second card for a number the scorecard prints."""
        rnd = Round.objects.create(
            account=self.acct, course=self.round.course, round_number=3,
            status='pending', active_games=['solo_nassau'])
        p = Player.objects.get(name='Paul')
        self.client.post(
            reverse('api-round-setup', args=[rnd.id]),
            {'players': [{'player_id': p.id, 'tee_id': self.tee.id}]},
            format='json')
        fs = rnd.foursomes.get()
        self.assertFalse(fs.has_phantom)
        self.assertFalse(
            fs.memberships.filter(player__is_phantom=True).exists())

    def test_an_empty_draw_is_still_refused(self):
        rnd = Round.objects.create(
            account=self.acct, course=self.round.course, round_number=4,
            status='pending', active_games=['solo_stroke'])
        r = self.client.post(reverse('api-round-setup', args=[rnd.id]),
                             {'players': []}, format='json')
        self.assertEqual(r.status_code, 400)


class AutoPressTests(_Base):
    """Nassau only, and off unless asked for."""

    def test_it_defaults_off_and_round_trips_on(self):
        self.assertFalse(self.client.get(self._setup_url()).data['auto_press'])
        self.client.post(self._setup_url(),
                         {'variant': 'nassau', 'net_percent': 100,
                          'auto_press': True}, format='json')
        self.assertTrue(self.client.get(self._setup_url()).data['auto_press'])
        self.assertTrue(SoloGame.objects.get().auto_press)

    def test_the_board_reports_it(self):
        r = self.client.post(self._setup_url(),
                             {'variant': 'nassau', 'net_percent': 100,
                              'auto_press': True}, format='json')
        self.assertTrue(r.data['nassau']['auto_press'])
        self.assertEqual(r.data['nassau']['front']['presses'], [])

    def test_a_press_is_still_not_money(self):
        """It opens another match against par, not another bet."""
        r = self.client.post(self._setup_url(),
                             {'variant': 'nassau', 'net_percent': 100,
                              'auto_press': True}, format='json')
        self.assertTrue(r.data['for_fun'])
        for key in ('press_unit', 'bet_unit', 'money'):
            self.assertNotIn(key, r.data)

    def test_a_second_setup_answers_with_the_NEW_settings(self):
        """`update_or_create` leaves the Round holding the config it cached
        the first time, so without clearing it this POST would echo back the
        settings the golfer just replaced."""
        self.client.post(self._setup_url(),
                         {'variant': 'nassau', 'net_percent': 100},
                         format='json')
        r = self.client.post(self._setup_url(),
                             {'variant': 'nassau', 'net_percent': 80,
                              'auto_press': True}, format='json')
        self.assertEqual(r.data['net_percent'], 80)
        self.assertTrue(r.data['nassau']['auto_press'])


class LeaderboardTests(_Base):
    """One tab, with the card in it.

    The slug and the block are different names — `solo_nassau` in
    `active_games`, `solo` in the games dict — and `_leaderboard_active_games`
    appends every games key to the round's own list, so leaving the slug in
    gave a solo round TWO tabs: one with the board and one with nothing to
    draw, which the client renders as raw JSON.
    """

    def _lb(self):
        return self.client.get(
            reverse('api-leaderboard', args=[self.round.id])).data

    def test_the_block_is_there_and_the_slug_is_not_a_tab(self):
        self.round.active_games = ['solo_nassau']
        self.round.save()
        self.client.post(self._setup_url(),
                         {'variant': 'nassau', 'net_percent': 100},
                         format='json')
        d = self._lb()
        self.assertIn('solo', d['games'])
        self.assertEqual(d['games']['solo']['label'], 'Nassau')
        self.assertIn('solo', d['active_games'])
        self.assertNotIn('solo_nassau', d['active_games'])

    def test_a_solo_round_gets_no_one_row_stroke_play_table(self):
        """The generic "scores" tab ranks the field by net to par and pays
        it. A field of one is a single row with a $0 payout, which reads as a
        fault — and the solo board already carries the card."""
        self.round.active_games = ['solo_match']
        self.round.save()
        self.client.post(self._setup_url(),
                         {'variant': 'match', 'net_percent': 100},
                         format='json')
        self.assertNotIn('low_net_round', self._lb()['games'])

    def test_an_unconfigured_solo_round_has_no_block_at_all(self):
        self.round.active_games = ['solo_stroke']
        self.round.save()
        self.assertNotIn('solo', self._lb()['games'])


class ResultTests(_Base):
    def test_unconfigured_says_so(self):
        d = self.client.get(self._result_url()).data
        self.assertFalse(d['configured'])

    def test_the_board_carries_the_holes_and_the_reading(self):
        self.client.post(self._setup_url(),
                         {'variant': 'match', 'net_percent': 100},
                         format='json')
        d = self.client.get(self._result_url()).data
        self.assertTrue(d['configured'])
        self.assertEqual(len(d['holes']), 18)
        self.assertIn('match', d)
        self.assertNotIn('nassau', d)

    def test_a_stranger_cannot_read_it(self):
        self.client.post(self._setup_url(),
                         {'variant': 'stroke', 'net_percent': 100},
                         format='json')
        other = Account.objects.create(name='Someone Else')
        nosy = User.objects.create_user(username='nosy', account=other)
        c = APIClient()
        c.force_authenticate(nosy)
        self.assertEqual(c.get(self._result_url()).status_code, 404)
