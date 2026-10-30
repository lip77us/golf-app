"""Taking a round off your own lists.

Reported 30 Oct 2026: *"I have a round I was invited to and it never happened
and it is stuck on my open rounds list."* Neither cross-account list ages a
live follow off — `SharedRoundsView` drops a COMPLETED watch after
`SHARED_WATCH_RETENTION_DAYS` and nothing else, and `PlayingRoundsView` drops
nothing at any status — so an abandoned round sits on the Active tab for good.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from tournament.models import (Foursome, FoursomeMembership, HiddenRound,
                               Round, Watcher)

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        # THEIR account owns the round; MINE is the one being tidied.
        self.theirs = Account.objects.create(name='Saturday Crew')
        self.mine   = Account.objects.create(name="Paul's Golf")
        self.me = User.objects.create_user(
            username='paul', account=self.mine, phone='+13105550101')
        self.client = APIClient()
        self.client.force_authenticate(self.me)

        course = Course.objects.create(account=self.theirs, name='Tilden')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('72.0'),
                                      par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.theirs, course=course, round_number=1,
            status='in_progress', active_games=['skins'])

    def _as_player(self):
        """They added me to their round as a golfer, matched on my phone."""
        fs = Foursome.objects.create(round=self.round, group_number=1)
        p = Player.objects.create(account=self.theirs, name='Paul',
                                  handicap_index=Decimal('6'),
                                  phone='(310) 555-0101')
        FoursomeMembership.objects.create(
            foursome=fs, player=p, tee=self.tee,
            course_handicap=6, playing_handicap=6)

    def _as_watcher(self):
        Watcher.objects.create(round=self.round, phone='+13105550101',
                               name='Paul')

    def _playing(self):
        return self.client.get(reverse('api-playing-for-me')).data

    def _watching(self):
        return self.client.get(reverse('api-shared-rounds')).data

    def _hide(self):
        return self.client.post(reverse('api-round-hide', args=[self.round.id]))

    def _unhide(self):
        return self.client.delete(
            reverse('api-round-hide', args=[self.round.id]))


class HideARoundTests(_Base):
    def test_a_round_i_play_in_can_be_taken_off_my_list(self):
        self._as_player()
        self.assertEqual(len(self._playing()), 1)
        self.assertEqual(self._hide().status_code, 200)
        self.assertEqual(self._playing(), [])

    def test_a_round_i_watch_can_be_taken_off_my_list(self):
        self._as_watcher()
        self.assertEqual(len(self._watching()), 1)
        self._hide()
        self.assertEqual(self._watching(), [])

    def test_it_is_reversible(self):
        self._as_player()
        self._hide()
        self.assertEqual(self._playing(), [])
        self.assertEqual(self._unhide().status_code, 200)
        self.assertEqual(len(self._playing()), 1)

    def test_hiding_twice_is_not_an_error(self):
        self._as_player()
        self._hide()
        self.assertEqual(self._hide().status_code, 200)
        self.assertEqual(
            HiddenRound.objects.filter(user=self.me, round=self.round).count(),
            1)

    def test_it_does_not_touch_THEIR_round(self):
        # The whole point: this removes the round from my list, not me from
        # their game. Their draw and their invitation survive.
        self._as_player()
        self._as_watcher()
        self._hide()
        self.assertEqual(
            FoursomeMembership.objects.filter(
                foursome__round=self.round).count(), 1)
        self.assertTrue(Watcher.objects.filter(round=self.round).exists())
        self.assertEqual(Round.objects.filter(pk=self.round.id).count(), 1)

    def test_it_is_per_USER_not_per_account(self):
        # Two members of one account invited to the same round, each matched
        # on their OWN phone (`User.phone` is globally unique, which is the
        # cross-account identity key). One tidying his list must not tidy the
        # other's.
        self._as_player()
        mate = User.objects.create_user(
            username='mate', account=self.mine, phone='+13105550102')
        fs = Foursome.objects.get(round=self.round)
        p2 = Player.objects.create(account=self.theirs, name='Mate',
                                   handicap_index=Decimal('9'),
                                   phone='(310) 555-0102')
        FoursomeMembership.objects.create(
            foursome=fs, player=p2, tee=self.tee,
            course_handicap=9, playing_handicap=9)

        self._hide()
        self.assertEqual(self._playing(), [])

        other = APIClient()
        other.force_authenticate(mate)
        self.assertEqual(
            len(other.get(reverse('api-playing-for-me')).data), 1)

    def test_my_own_round_is_refused(self):
        # Hiding it would make it unreachable rather than tidy.
        mine = Round.objects.create(
            account=self.mine,
            course=Course.objects.create(account=self.mine, name='Home'),
            round_number=1, status='in_progress', active_games=['skins'])
        r = self.client.post(reverse('api-round-hide', args=[mine.id]))
        self.assertEqual(r.status_code, 400)
        self.assertIn('your own round', r.data['detail'])

    def test_a_stranger_cannot_hide_a_round_he_cannot_read(self):
        stranger = User.objects.create_user(
            username='nobody',
            account=Account.objects.create(name='Elsewhere'),
            phone='+15105550199')
        c = APIClient()
        c.force_authenticate(stranger)
        self.assertEqual(
            c.post(reverse('api-round-hide', args=[self.round.id])).status_code,
            404)
