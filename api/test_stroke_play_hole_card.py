"""The Stroke Play score-entry card — on the wire.

The engine is covered in `scoring/tests/test_stroke_play_hole_card.py`; these
cover the two ways the screen gets it: WITH the save, so the tray does not
cost a second request (the lesson Annandale Friday's tray learned), and by a
GET for a hole the screen opens without posting.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from games.models import LowNetRoundConfig
from tournament.models import Foursome, FoursomeMembership, Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    games = ['low_net_round']

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
            status='in_progress', active_games=self.games,
            handicap_mode='net', net_percent=100,
            net_max_double_bogey=True)
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name, hcp in (('Ann', 0), ('Ben', 9), ('Cal', 18), ('Dee', 27)):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal(hcp))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=hcp, playing_handicap=hcp)
            self.pid[name] = p.id
        LowNetRoundConfig.objects.create(
            round=self.round, handicap_mode='net', net_percent=100)

    def _post_hole(self, hole, gross):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.pid[n], 'gross_score': g}
                        for n, g in gross.items()]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r

    def _card(self, hole):
        return self.client.get(
            reverse('api-stroke-play-hole', args=[self.fs.id, hole]))


class StrokePlayHoleCardEndpointTests(_Base):
    def test_the_save_returns_the_card_for_the_hole_just_posted(self):
        r = self._post_hole(1, {'Ann': 4, 'Ben': 5, 'Cal': 5, 'Dee': 6})
        card = r.data.get('stroke_play_hole')
        self.assertIsNotNone(card, 'the tray must not cost a second request')
        self.assertEqual(card['hole'], 1)
        self.assertEqual(len(card['standing']), 4)
        # Hole 1 is stroke index 1, so everyone but Ann gets a shot — Dee
        # gets two off 27.
        strokes = {p['name']: p['strokes'] for p in card['players']}
        self.assertEqual(strokes, {'Ann': 0, 'Ben': 1, 'Cal': 1, 'Dee': 2})

    def test_the_card_follows_the_hole_being_posted(self):
        self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4, 'Dee': 4})
        r = self._post_hole(2, {'Ann': 4, 'Ben': 4, 'Cal': 4, 'Dee': 4})
        self.assertEqual(r.data['stroke_play_hole']['hole'], 2)

    def test_the_get_serves_a_hole_nobody_has_posted(self):
        r = self._card(10)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['hole'], 10)
        self.assertEqual(len(r.data['players']), 4)
        self.assertTrue(all(p['gross'] is None for p in r.data['players']))
        # The strokes are there anyway: the keypad is coded against them.
        # Hole 10 is stroke index 10, so Ben (9) gets nothing and Dee (27)
        # gets one rather than the two she gets on the first nine's holes.
        self.assertEqual(
            {p['name']: p['strokes'] for p in r.data['players']},
            {'Ann': 0, 'Ben': 0, 'Cal': 1, 'Dee': 1})

    def test_a_round_without_stroke_play_gets_no_card_on_the_save(self):
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        r = self._post_hole(1, {'Ann': 4, 'Ben': 4, 'Cal': 4, 'Dee': 4})
        self.assertNotIn('stroke_play_hole', r.data)

    def test_another_account_cannot_read_the_card(self):
        other = Account.objects.create(name='Someone else')
        user  = User.objects.create_user(username='nobody', account=other)
        c = APIClient()
        c.force_authenticate(user)
        r = c.get(reverse('api-stroke-play-hole', args=[self.fs.id, 1]))
        self.assertEqual(r.status_code, 404)
