"""How many golfers one group may hold — four, or six playing Annandale Friday.

`services.round_setup.max_group_size` is the one place that answers it, and
three paths refuse a golfer over it: round setup (explicit and automatic
grouping), add-player and move-player. Left to the old foursome split, six
golfers picked for Annandale Friday came back as two threes — a different
round, with no error to say so.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from services.round_setup import max_group_size
from tournament.models import Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    GAMES = ['annandale_friday']

    def setUp(self):
        self.acct = Account.objects.create(name='Annandale')
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        course = Course.objects.create(account=self.acct, name='Annandale GC')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('72.0'),
                                      par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, round_number=1, status='pending',
            active_games=list(self.GAMES),
            primary_game=self.GAMES[0] if self.GAMES else None,
            bet_unit=Decimal('10.00'))
        self.pids = [Player.objects.create(account=self.acct, name=f'G{i+1}',
                                           handicap_index=Decimal('10')).id
                     for i in range(8)]

    def _setup(self, n, groups=None):
        players = [{'player_id': pid, 'tee_id': self.tee.id}
                   for pid in self.pids[:n]]
        if groups:
            for p, g in zip(players, groups):
                p['group_number'] = g
        return self.client.post(reverse('api-round-setup', args=[self.round.id]),
                                {'players': players, 'randomise': False},
                                format='json')

    def sizes(self):
        return [fs.memberships.count()
                for fs in self.round.foursomes.order_by('group_number')]


class AnnandaleFridayTests(_Base):
    def test_the_rule(self):
        assert max_group_size(self.round) == 6

    def test_six_is_one_card(self):
        r = self._setup(6)
        assert r.status_code == 201, r.content
        assert self.sizes() == [6]

    def test_five_is_one_card(self):
        assert self._setup(5).status_code == 201
        assert self.sizes() == [5]

    def test_six_with_explicit_groups_is_one_card(self):
        assert self._setup(6, groups=[1] * 6).status_code == 201
        assert self.sizes() == [6]

    def test_seven_on_one_card_is_a_400_not_a_500(self):
        r = self._setup(7, groups=[1] * 7)
        assert r.status_code == 400, r.content
        assert 'Each group must have 1–6 players' in r.json()['detail']

    def test_the_primary_alone_is_enough(self):
        # A round whose active list was trimmed still knows its game.
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        assert max_group_size(self.round) == 6

    def test_add_player_takes_a_fifth_and_a_sixth_and_refuses_a_seventh(self):
        assert self._setup(4, groups=[1] * 4).status_code == 201
        url = reverse('api-round-add-player', args=[self.round.id])
        for pid in self.pids[4:6]:
            r = self.client.post(url, {'player_id': pid, 'tee_id': self.tee.id,
                                       'group_number': 1}, format='json')
            assert r.status_code == 201, r.content
        r = self.client.post(url, {'player_id': self.pids[6],
                                   'tee_id': self.tee.id, 'group_number': 1},
                             format='json')
        assert r.status_code == 400
        assert r.json()['detail'] == ('Group 1 is full — this game is at '
                                      'most 6 on a card.')

    def test_move_player_takes_a_fifth(self):
        assert self._setup(7, groups=[1, 1, 1, 1, 2, 2, 2]).status_code == 201
        g1, g2 = self.round.foursomes.order_by('group_number')
        r = self.client.post(
            reverse('api-round-move-player', args=[self.round.id]),
            {'player_id': self.pids[4], 'from_foursome_id': g2.id,
             'to_foursome_id': g1.id}, format='json')
        assert r.status_code == 200, r.content
        assert self.sizes() == [5, 2]


class EveryOtherGameTests(_Base):
    """Nothing changes for a round that is not playing it."""
    GAMES = ['skins']

    def test_the_rule(self):
        assert max_group_size(self.round) == 4

    def test_six_still_splits_into_two_threes(self):
        assert self._setup(6).status_code == 201
        assert self.sizes() == [3, 3]

    def test_five_on_one_card_is_refused(self):
        r = self._setup(5, groups=[1] * 5)
        assert r.status_code == 400
        assert 'Each group must have 1–4 players' in r.json()['detail']

    def test_add_player_still_says_foursome(self):
        assert self._setup(4, groups=[1] * 4).status_code == 201
        r = self.client.post(
            reverse('api-round-add-player', args=[self.round.id]),
            {'player_id': self.pids[4], 'tee_id': self.tee.id,
             'group_number': 1}, format='json')
        assert r.status_code == 400
        assert r.json()['detail'] == 'Group 1 is full — a group is a foursome.'
