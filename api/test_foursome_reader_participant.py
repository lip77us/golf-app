"""
api/test_foursome_reader_participant.py
---------------------------------------
A golfer playing anywhere in a round can read every group's card in it.

From the Heart Health Scramble: once Jim was linked to his roster entry, opening
another team's scorecard returned "No such foursome". foursome_for_reader let a
watcher read every group but let a player read only his own.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.http import Http404
from django.test import TestCase

from accounts.models import Account
from accounts.scoring_access import foursome_for_reader, foursome_for_scorer
from core.models import Course, Player, Tee
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class ParticipantReadsOtherGroupsTests(TestCase):

    def setUp(self):
        self.club = Account.objects.create(name='TD club')
        course = Course.objects.create(account=self.club, name='Tilden')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('70'),
                                      par=70, holes=HOLES)
        self.round = Round.objects.create(account=self.club, course=course)
        self.mine   = Foursome.objects.create(round=self.round, group_number=1)
        self.theirs = Foursome.objects.create(round=self.round, group_number=2)

        jim = Player.objects.create(account=self.club, name='Jim',
                                    phone='5107344842',
                                    handicap_index=Decimal('16'))
        other = Player.objects.create(account=self.club, name='Other',
                                      phone='+14155550000',
                                      handicap_index=Decimal('10'))
        self._seat(self.mine, jim)
        self._seat(self.theirs, other)

        self.jim = User.objects.create_user(
            username='jim', account=Account.objects.create(name='Jim golf'),
            phone='+15107344842')

    def _seat(self, fs, player):
        FoursomeMembership.objects.create(foursome=fs, player=player,
                                          tee=self.tee, course_handicap=10,
                                          playing_handicap=10)

    def test_he_can_read_his_own_group(self):
        self.assertEqual(foursome_for_reader(self.jim, self.mine.pk), self.mine)

    def test_and_now_the_other_teams_card(self):
        self.assertEqual(foursome_for_reader(self.jim, self.theirs.pk),
                         self.theirs)

    def test_but_he_still_cannot_score_it(self):
        """Read only. Entering scores stays limited to his own group."""
        with self.assertRaises(Http404):
            foursome_for_scorer(self.jim, self.theirs.pk)

    def test_a_stranger_still_cannot_read_it(self):
        stranger = User.objects.create_user(
            username='x', account=Account.objects.create(name='Elsewhere'),
            phone='+19995550000')
        with self.assertRaises(Http404):
            foursome_for_reader(stranger, self.theirs.pk)

    def test_playing_a_different_round_does_not_open_this_one(self):
        other_round = Round.objects.create(account=self.club,
                                           course=self.round.course)
        elsewhere = Foursome.objects.create(round=other_round, group_number=1)
        with self.assertRaises(Http404):
            foursome_for_reader(self.jim, elsewhere.pk)
