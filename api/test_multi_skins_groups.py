"""A Multi-Group Skins draw with MIXED group sizes.

Paul's round of 12 Oct 2026: a 15-foursome shotgun whose skins pool was one
full foursome playing together, two individuals and a twosome — 4, 1, 1, 2.
The picker had been seating everybody solo since July, so this is the shape
the client could not express; these pin that the server takes it and that the
pool scores across the groups whatever their sizes.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from tournament.models import Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class MixedGroupSizesTests(TestCase):
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
            status='pending', active_games=['multi_skins'],
            bet_unit=Decimal('5.00'))
        self.pids = []
        for i in range(8):
            p = Player.objects.create(account=self.acct, name=f'G{i+1}',
                                      handicap_index=Decimal('10'))
            self.pids.append(p.id)

    def _setup(self, groups):
        return self.client.post(
            reverse('api-round-setup', args=[self.round.id]),
            {'players': [
                {'player_id': pid, 'tee_id': self.tee.id, 'group_number': g}
                for pid, g in zip(self.pids, groups)
            ]},
            format='json')

    def test_four_one_one_two(self):
        r = self._setup([1, 1, 1, 1, 2, 3, 4, 4])
        self.assertEqual(r.status_code, 201, r.content)
        sizes = [fs.memberships.count()
                 for fs in self.round.foursomes.order_by('group_number')]
        self.assertEqual(sizes, [4, 1, 1, 2])

    def test_nobody_is_padded_into_the_short_groups(self):
        """A casual round never pads, so the single golfers really do play
        their own card rather than acquiring a phantom partner."""
        self._setup([1, 1, 1, 1, 2, 3, 4, 4])
        for fs in self.round.foursomes.all():
            self.assertFalse(fs.has_phantom)
            self.assertFalse(
                fs.memberships.filter(player__is_phantom=True).exists())

    def test_the_pool_scores_across_the_groups(self):
        """Which is the whole game: one skins competition over golfers who are
        on four different scorecards."""
        from services.multi_skins import setup_multi_skins, multi_skins_summary
        self._setup([1, 1, 1, 1, 2, 3, 4, 4])
        setup_multi_skins(self.round, participant_ids=self.pids,
                          handicap_mode='gross')
        from scoring.models import HoleScore
        for fs in self.round.foursomes.all():
            for m in fs.memberships.all():
                HoleScore.objects.create(
                    foursome=fs, player_id=m.player_id, hole_number=1,
                    gross_score=5 if m.player_id != self.pids[5] else 3,
                    handicap_strokes=0)
        from services.multi_skins import calculate_multi_skins
        calculate_multi_skins(self.round)
        d = multi_skins_summary(self.round)
        hole1 = next(h for h in d['holes'] if h['hole'] == 1)
        # The lone golfer in group 3 took it, against seven golfers on three
        # other cards.
        self.assertEqual(hole1['winner_id'], self.pids[5])
