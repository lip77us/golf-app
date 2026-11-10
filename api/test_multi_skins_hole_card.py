"""The skins POOL's score-entry card — on the wire.

The engine is covered in `scoring/tests/test_multi_skins_hole_card.py`; these
cover the two ways the screen gets it — WITH the save, and by a GET — and the
gate on the first: the pool rides as a side game on a sixty-player
tournament, where computing its card on every posted score would be for a
tray nobody draws.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from tournament.models import Foursome, FoursomeMembership, Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    ACTIVE  = ['multi_skins']
    PRIMARY = 'multi_skins'

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
            status='in_progress', active_games=list(self.ACTIVE),
            primary_game=self.PRIMARY, bet_unit=Decimal('10.00'))
        self.pid, self.fs = {}, {}
        for group, names in ((1, ('Ann Archer', 'Ben Bell')),
                             (2, ('Cal Croft', 'Dee Dunn'))):
            fs = Foursome.objects.create(round=self.round, group_number=group)
            self.fs[group] = fs
            for name in names:
                p = Player.objects.create(account=self.acct, name=name,
                                          handicap_index=Decimal('0'))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=0, playing_handicap=0)
                self.pid[name.split()[0]] = p.id

        from services.multi_skins import setup_multi_skins
        setup_multi_skins(self.round, list(self.pid.values()),
                          handicap_mode='gross', bet_unit=10)

    def _post_hole(self, group, hole, gross):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs[group].id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.pid[n], 'gross_score': g}
                        for n, g in gross.items()]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r

    def _card(self, group, hole):
        return self.client.get(reverse(
            'api-multi-skins-hole', args=[self.fs[group].id, hole]))


class PoolHoleCardEndpointTests(_Base):

    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, 1, {'Ann': 3, 'Ben': 4})
        card = r.data.get('multi_skins_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        # This group is in; the field is not.
        self.assertEqual(card['outcome'], 'waiting')
        self.assertEqual(card['rides_to'], '2 of 4 in')

    def test_the_group_that_completes_the_field_gets_the_result(self):
        self._post_hole(1, 1, {'Ann': 3, 'Ben': 4})
        r = self._post_hole(2, 1, {'Cal': 4, 'Dee': 4})
        card = r.data['multi_skins_hole']
        self.assertEqual(card['outcome'], 'outright')
        self.assertEqual(card['line'], 'Ann takes the skin with net 3')

    def test_a_GET_answers_for_a_hole_opened_without_posting(self):
        r = self._card(1, 3)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 3)
        self.assertEqual(r.data['outcome'], 'pending')
        self.assertEqual(len(r.data['players']), 2)

    def test_a_GET_sees_a_hole_the_other_group_has_since_settled(self):
        # The save's card said `waiting`; nothing pushes the result, so the
        # GET is how a card catches up.
        self._post_hole(1, 1, {'Ann': 3, 'Ben': 4})
        self._post_hole(2, 1, {'Cal': 4, 'Dee': 4})
        self.assertEqual(self._card(1, 1).data['outcome'], 'outright')

    def test_a_round_with_no_pool_gets_an_empty_card(self):
        self.round.multi_skins_game.delete()
        self.assertEqual(self._card(1, 1).data, {})

    def test_it_never_rides_under_the_skins_key(self):
        # Two cards, two keys: a round can carry round Skins as a side game
        # beside the pool, and one key could not say which it was sending.
        r = self._post_hole(1, 1, {'Ann': 3, 'Ben': 4})
        self.assertNotIn('skins_hole', r.data)

    def test_a_stranger_gets_a_404(self):
        other = Account.objects.create(name='Someone Else')
        user  = User.objects.create_user(username='nope', account=other)
        c = APIClient()
        c.force_authenticate(user)
        r = c.get(reverse('api-multi-skins-hole', args=[self.fs[1].id, 1]))
        self.assertEqual(r.status_code, 404)


class APoolThatIsASideGameSendsNoCardTests(_Base):
    """Stroke Play owns the entry; the pool is a leaderboard tab."""
    ACTIVE  = ['low_net_round', 'multi_skins']
    PRIMARY = 'low_net_round'

    def test_the_save_does_not_compute_it(self):
        r = self._post_hole(1, 1, {'Ann': 3, 'Ben': 4})
        self.assertNotIn('multi_skins_hole', r.data)

    def test_the_GET_still_answers(self):
        # The gate is on the save's cost, not on the card's existence.
        self.assertEqual(self._card(1, 1).data['hole'], 1)


class ALegacyPoolOnlyRoundStillGetsOneTests(_Base):
    """No stored primary, and the pool is all the round plays."""
    PRIMARY = None

    def test_the_save_returns_the_card(self):
        r = self._post_hole(1, 1, {'Ann': 3, 'Ben': 4})
        self.assertIn('multi_skins_hole', r.data)
