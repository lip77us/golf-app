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


class AddPlayerTests(TestCase):
    """The latecomer. A casual round's field could only ever be set in the
    create flow, so a pool could not take somebody standing on the first tee.
    """

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
            status='in_progress', active_games=['multi_skins'],
            bet_unit=Decimal('5.00'))
        self.pids = []
        for i in range(4):
            p = Player.objects.create(account=self.acct, name=f'G{i+1}',
                                      handicap_index=Decimal('10'))
            self.pids.append(p.id)
        self.client.post(
            reverse('api-round-setup', args=[self.round.id]),
            {'players': [
                {'player_id': pid, 'tee_id': self.tee.id, 'group_number': g}
                for pid, g in zip(self.pids, [1, 1, 2, 3])
            ]}, format='json')
        self.late = Player.objects.create(account=self.acct, name='Late Len',
                                          handicap_index=Decimal('8'))

    def _url(self):
        return reverse('api-round-add-player', args=[self.round.id])

    def _score(self, group_number, hole=1):
        from scoring.models import HoleScore
        fs = self.round.foursomes.get(group_number=group_number)
        for m in fs.memberships.all():
            HoleScore.objects.create(foursome=fs, player_id=m.player_id,
                                     hole_number=hole, gross_score=4,
                                     handicap_strokes=0)

    def test_he_lands_on_a_card_of_his_own(self):
        r = self.client.post(self._url(),
                             {'player_id': self.late.id,
                              'tee_id': self.tee.id}, format='json')
        self.assertEqual(r.status_code, 201, r.content)
        fs = self.round.foursomes.order_by('-group_number').first()
        self.assertEqual(fs.group_number, 4)
        self.assertEqual([m.player_id for m in fs.memberships.all()],
                         [self.late.id])

    def test_a_new_card_works_even_mid_round(self):
        """Which is the point: his own group touches nothing that exists, so
        unlike a regroup it is safe once the round is under way."""
        self._score(1)
        r = self.client.post(self._url(),
                             {'player_id': self.late.id,
                              'tee_id': self.tee.id}, format='json')
        self.assertEqual(r.status_code, 201, r.content)

    def test_he_can_join_a_group_that_has_not_teed_off(self):
        r = self.client.post(self._url(),
                             {'player_id': self.late.id,
                              'tee_id': self.tee.id,
                              'group_number': 2}, format='json')
        self.assertEqual(r.status_code, 201, r.content)
        fs = self.round.foursomes.get(group_number=2)
        self.assertEqual(fs.memberships.count(), 2)

    def test_but_not_one_that_has(self):
        """His tee can lower the group's minimum par, which re-derives every
        other member's playing handicap — and those are the numbers their
        played holes were scored against."""
        self._score(1)
        r = self.client.post(self._url(),
                             {'player_id': self.late.id,
                              'tee_id': self.tee.id,
                              'group_number': 1}, format='json')
        self.assertEqual(r.status_code, 409, r.content)
        self.assertIn('his own', r.data['detail'])

    def test_a_full_group_is_a_foursome(self):
        # Group 2 starts with one; three more fill it.
        for i in range(3):
            p = Player.objects.create(account=self.acct, name=f'X{i}',
                                      handicap_index=Decimal('9'))
            self.client.post(self._url(), {'player_id': p.id,
                                           'tee_id': self.tee.id,
                                           'group_number': 2}, format='json')
        p = Player.objects.create(account=self.acct, name='Fifth',
                                  handicap_index=Decimal('9'))
        r = self.client.post(self._url(), {'player_id': p.id,
                                           'tee_id': self.tee.id,
                                           'group_number': 2}, format='json')
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn('full', r.data['detail'])

    def test_he_joins_the_pool_too(self):
        """A golfer seated in a skins round who is not in the pool would be
        scoring for nothing."""
        from services.multi_skins import setup_multi_skins
        setup_multi_skins(self.round, participant_ids=self.pids,
                          handicap_mode='gross')
        self.client.post(self._url(), {'player_id': self.late.id,
                                       'tee_id': self.tee.id}, format='json')
        game = self.round.multi_skins_game
        self.assertIn(self.late.id,
                      game.participants.values_list('id', flat=True))

    def test_he_gets_a_playing_handicap(self):
        self.client.post(self._url(), {'player_id': self.late.id,
                                       'tee_id': self.tee.id}, format='json')
        m = self.round.foursomes.get(group_number=4).memberships.get()
        self.assertGreater(m.playing_handicap, 0)
        self.assertEqual(m.tee_id, self.tee.id)

    def test_adding_him_twice_is_refused(self):
        self.client.post(self._url(), {'player_id': self.late.id,
                                       'tee_id': self.tee.id}, format='json')
        r = self.client.post(self._url(), {'player_id': self.late.id,
                                           'tee_id': self.tee.id},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('already in this round', r.data['detail'])

    def test_a_stranger_cannot_add_to_my_round(self):
        other = Account.objects.create(name='Someone Else')
        nosy = User.objects.create_user(username='nosy', account=other)
        c = APIClient()
        c.force_authenticate(nosy)
        r = c.post(self._url(), {'player_id': self.late.id,
                                 'tee_id': self.tee.id}, format='json')
        self.assertEqual(r.status_code, 404)

    def test_a_finished_round_takes_nobody(self):
        self.round.status = 'complete'
        self.round.save(update_fields=['status'])
        r = self.client.post(self._url(), {'player_id': self.late.id,
                                           'tee_id': self.tee.id},
                             format='json')
        self.assertEqual(r.status_code, 400)


class RoundPayloadKnowsWhoIsOnHalvedTests(TestCase):
    """`is_on_app` is a context-fed field, and only the roster endpoint was
    filling it — so a ROUND payload said nobody was on Halved.

    Reported from the hub's Groups screen, which told a TD that six golfers
    who are on Halved were not, and refused to save his draw over it.
    """

    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.user = User.objects.create_user(username='paul', account=self.acct,
                                             phone='+15105550001')
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
        # One golfer carries a phone a registered user has; one does not.
        self.member = Player.objects.create(
            account=self.acct, name='On Halved', handicap_index=Decimal('10'),
            phone='(510) 555-0001')
        self.guest = Player.objects.create(
            account=self.acct, name='Guest', handicap_index=Decimal('10'),
            phone='(510) 555-9999')
        self.client.post(
            reverse('api-round-setup', args=[self.round.id]),
            {'players': [
                {'player_id': self.member.id, 'tee_id': self.tee.id,
                 'group_number': 1},
                {'player_id': self.guest.id, 'tee_id': self.tee.id,
                 'group_number': 2},
            ]}, format='json')

    def _flags(self):
        d = self.client.get(reverse('api-round-detail',
                                    args=[self.round.id])).data
        out = {}
        for fs in d['foursomes']:
            for m in fs['memberships']:
                out[m['player']['name']] = m['player']['is_on_app']
        return out

    def test_the_round_payload_flags_the_member(self):
        self.assertTrue(self._flags()['On Halved'])

    def test_and_does_not_flag_the_guest(self):
        self.assertFalse(self._flags()['Guest'])

    def test_a_formatted_phone_still_matches(self):
        """The match is on the NORMALIZED number — the golfer's row carries
        whatever was typed."""
        self.member.phone = '510-555-0001'
        self.member.save(update_fields=['phone'])
        self.assertTrue(self._flags()['On Halved'])
