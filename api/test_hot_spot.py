"""
api/test_hot_spot.py
--------------------
Hot Spot setup / anchor-order / result endpoints round-trip through the
serializer, view and urls. (The scoring itself is covered by
scoring/tests/test_hot_spot.py.)
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

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Hot Spot Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['hot_spot'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.players = [
            Player.objects.create(account=self.acct, name=n,
                                  handicap_index=Decimal('0'))
            for n in ('A', 'B', 'C', 'D')]
        for p in self.players:
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
        self.ids = [p.id for p in self.players]
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _setup(self, **over):
        body = {'scoring': 'to_par', 'handicap_mode': 'gross',
                'net_percent': 85, 'finish_rule': 'keep_rotating',
                'entry_fee': '20.00', 'payouts': [{'place': 1, 'amount': 40}]}
        body.update(over)
        return self.client.post(
            reverse('api-hot-spot-setup', args=[self.round.id]),
            body, format='json')

    def _order(self, ids=None):
        return self.client.post(
            reverse('api-hot-spot-order', args=[self.fs.id]),
            {'player_ids': ids or self.ids}, format='json')

    def _result(self):
        return self.client.get(reverse('api-hot-spot-result',
                                       args=[self.round.id]))


class SetupTests(_Base):

    def test_defaults_before_setup(self):
        resp = self.client.get(
            reverse('api-hot-spot-setup', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(resp.data['configured'])
        self.assertEqual(resp.data['net_percent'], 85,
                         '85% is the handoff default')
        self.assertEqual(resp.data['finish_rule'], 'keep_rotating')
        self.assertEqual(resp.data['group_sizes'], [4])

    def test_setup_round_trips(self):
        resp = self._setup(finish_rule='best_2', net_percent=100)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertTrue(resp.data['configured'])
        self.assertEqual(resp.data['finish_rule'], 'best_2')
        self.assertEqual(resp.data['net_percent'], 100)
        self.assertEqual(
            self.client.get(reverse('api-hot-spot-setup',
                                    args=[self.round.id])).data['net_percent'],
            100)

    def test_strokes_off_is_rejected_by_the_serializer(self):
        """There is no single low golfer in a field of groups."""
        self.assertEqual(self._setup(handicap_mode='strokes_off').status_code,
                         400)

    def test_the_allowance_slider_bounds_are_enforced(self):
        self.assertEqual(self._setup(net_percent=40).status_code, 400)
        self.assertEqual(self._setup(net_percent=140).status_code, 400)


class OrderTests(_Base):

    def test_the_group_sets_its_own_order(self):
        self._setup()
        resp = self._order(list(reversed(self.ids)))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['player_ids'], list(reversed(self.ids)))

    def test_a_partial_order_is_refused(self):
        self._setup()
        self.assertEqual(self._order(self.ids[:3]).status_code, 400)

    def test_moving_a_spent_position_is_refused_and_names_it(self):
        """The copy changed with the rule, and says which row it means.

        It used to say "the anchor order is set on the first tee" — true of
        the old all-or-nothing lock and misleading now, because the rest of
        the order is still the group's to arrange.
        """
        self._setup()
        self._order()
        HoleScore.objects.create(foursome=self.fs, player=self.players[0],
                                 hole_number=1, gross_score=4)
        resp = self._order(list(reversed(self.ids)))
        self.assertEqual(resp.status_code, 400)
        self.assertIn('Position 1', resp.data['detail'])

    def test_the_unspent_positions_are_still_the_groups_to_arrange(self):
        """Red Ball's rule, over the wire. Hole 1 is played; 2, 3 and 4 aren't.

        The old lock refused this with a 400 — not wrong about hole 1, wrong
        about the three holes that had decided nothing.
        """
        self._setup()
        self._order()
        HoleScore.objects.create(foursome=self.fs, player=self.players[0],
                                 hole_number=1, gross_score=4)
        wanted = [self.ids[0], self.ids[3], self.ids[2], self.ids[1]]
        resp = self._order(wanted)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['player_ids'], wanted)

    def test_the_result_reports_which_positions_are_locked(self):
        self._setup()
        self._order()
        HoleScore.objects.create(foursome=self.fs, player=self.players[0],
                                 hole_number=1, gross_score=4)
        g = next(x for x in self._result().data['groups']
                 if x['foursome_id'] == self.fs.pk)
        self.assertEqual(g['order_positions_locked'], [0])
        self.assertFalse(g['order_fully_locked'])


class ResultTests(_Base):

    def test_result_is_empty_before_setup(self):
        resp = self._result()
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertFalse(resp.data['configured'])

    def test_result_carries_the_board_and_the_card(self):
        self._setup()
        self._order()
        for p, score in zip(self.players, (9, 4, 4, 4)):
            HoleScore.objects.create(foursome=self.fs, player=p,
                                     hole_number=1, gross_score=score)
        resp = self._result()
        self.assertTrue(resp.data['configured'])
        row = resp.data['overall'][0]
        # anchor 9 capped to 6, plus the best of the others.
        self.assertEqual(row['total_score'], 10)
        hole = resp.data['groups'][0]['holes'][0]
        self.assertEqual(hole['anchor_id'], self.ids[0])
        self.assertEqual(len(hole['counted_ids']), 2)
        self.assertTrue(resp.data['groups'][0]['order_is_set'])
        self.assertTrue(resp.data['groups'][0]['order_locked'])

    def test_the_leaderboard_carries_a_hot_spot_block(self):
        self._setup()
        self._order()
        resp = self.client.get(reverse('api-leaderboard', args=[self.round.id]))
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertIn('hot_spot', resp.data['games'])
        self.assertEqual(resp.data['games']['hot_spot']['label'], 'Hot Seat')

    def test_the_key_is_the_old_slug_and_the_label_is_the_new_name(self):
        """The 15 Oct 2026 rename moved the NAME and not the id.

        Both halves matter and they pull opposite ways.  Renaming the value to
        match the label would orphan every round that already holds
        ``hot_spot`` -- in ``Round.active_games``, in a cup config's
        ``game_type``, in the leaderboard key the client tabs off.  Leaving the
        label would leave the app calling it by a name the website, the guide
        and the organiser no longer use.  So this pins the split rather than
        either name on its own.
        """
        from core.models import GameType
        self.assertEqual(GameType.HOT_SPOT.value, 'hot_spot')
        self.assertEqual(GameType.HOT_SPOT.label, 'Hot Seat')

        self._setup()
        self._order()
        resp = self.client.get(reverse('api-leaderboard', args=[self.round.id]))
        self.assertIn('hot_spot', resp.data['games'])
        self.assertNotIn('hot_seat', resp.data['games'])
        self.assertEqual(self.round.active_games, ['hot_spot'])

    def test_configured_games_reports_it_from_the_config(self):
        """It is the FOURSOME serializer that carries this, which is what the
        round hub reads to decide the Enter Scores route."""
        self._setup()
        from api.serializers import FoursomeSerializer
        self.assertIn('hot_spot',
                      FoursomeSerializer(self.fs).data['configured_games'])
