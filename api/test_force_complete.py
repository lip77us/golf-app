"""Closing a round the field has not finished.

The multi-foursome guard stops ONE GROUP's "Complete Round" locking its
siblings out of scoring. That is a hazard about a SCORER. The TD is a
different person — the cup branch already refuses a non-TD outright — and he
is the one who knows that two groups went home.

Before this he had no way to say so: the endpoint returned 200 with the round
unchanged, the tournament stayed in Active, and the only feedback was a
four-second snackbar. TPSGC 2026 Ryder Cup, 11 Oct 2026 — twelve groups, four
short — had to be closed by hand over SSH.
"""
from datetime import date
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import (Foursome, FoursomeMembership, Round,
                               Tournament)

HOLES = [{'number': n, 'par': 4, 'stroke_index': n} for n in range(1, 19)]


class ForceCompleteTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Duddy Club')
        self.td = User.objects.create_user(username='td', account=self.acct)
        self.td.is_account_admin = True
        self.td.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.td)

        course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('72.0'),
                                      par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Duddy Cup', start_date=date(2026, 6, 1),
            total_rounds=1)
        self.round = Round.objects.create(account=self.acct, course=course,
                                          tournament=self.tourn,
                                          round_number=1,
                                          status='in_progress')
        # Two groups: one finished, one that never teed off.
        self.done, self.short = [
            self._group(n) for n in (1, 2)
        ]
        for m in self.done.memberships.all():
            for h in range(1, 19):
                HoleScore.objects.create(foursome=self.done, player=m.player,
                                         hole_number=h, gross_score=4)

    def _group(self, n):
        fs = Foursome.objects.create(round=self.round, group_number=n)
        for i in range(4):
            p = Player.objects.create(account=self.acct, name=f'G{n}-{i}',
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(foursome=fs, player=p,
                                              tee=self.tee, course_handicap=0,
                                              playing_handicap=0)
        return fs

    def _url(self):
        return reverse('api-round-complete', args=[self.round.id])

    def _complete(self, **body):
        return self.client.post(self._url(), body, format='json')

    # -- the shipped behaviour, unchanged ---------------------------------

    def test_without_force_it_waits_for_the_field(self):
        """Still 200, still unchanged — the guard's whole point."""
        r = self._complete()
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data['status'], 'in_progress')
        self.assertFalse(r.data['all_foursomes_done'])

    # -- what was missing --------------------------------------------------

    def test_the_td_can_force_it(self):
        r = self._complete(force=True)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data['status'], 'complete')
        self.round.refresh_from_db()
        self.assertEqual(self.round.status, 'complete')

    def test_the_response_NAMES_the_groups_holding_it_open(self):
        """"Some groups have not finished" is not something a TD can act on.
        "Group 2, 0 of 18" is."""
        r = self._complete()
        out = r.data['groups_outstanding']
        self.assertEqual([g['group_number'] for g in out], [2])
        self.assertEqual(out[0]['holes_scored'], 0)
        self.assertEqual(out[0]['holes_expected'], 18)

    def test_a_finished_group_is_not_listed(self):
        self.assertNotIn(1, [g['group_number']
                             for g in self._complete().data['groups_outstanding']])

    def test_a_partly_played_group_reports_how_far_it_got(self):
        for m in self.short.memberships.all():
            for h in range(1, 13):
                HoleScore.objects.create(foursome=self.short, player=m.player,
                                         hole_number=h, gross_score=5)
        out = self._complete().data['groups_outstanding']
        self.assertEqual(out[0]['holes_scored'], 12)

    def test_the_client_is_told_whether_the_button_will_work(self):
        """It must not offer a force that would be ignored."""
        self.assertTrue(self._complete().data['can_force_complete'])

    def test_and_is_told_NOT_to_offer_it_once_the_field_is_in(self):
        for m in self.short.memberships.all():
            for h in range(1, 19):
                HoleScore.objects.create(foursome=self.short, player=m.player,
                                         hole_number=h, gross_score=5)
        r = self._complete()
        self.assertEqual(r.data['status'], 'complete')
        self.assertFalse(r.data['can_force_complete'])
        self.assertEqual(r.data['groups_outstanding'], [])

    # -- who may ------------------------------------------------------------

    def test_a_scorer_from_another_account_cannot_force_it(self):
        """The hazard the guard exists for: one group closing the round on
        the other eleven. A scorer passing `force` gets the ordinary wait.
        """
        from accounts.phone import normalize
        other = Account.objects.create(name='Visitor')
        scorer = User.objects.create_user(username='scorer', account=other)
        scorer.phone = normalize('+13105550199')
        scorer.save(update_fields=['phone'])
        m = self.done.memberships.first()
        m.player.phone = '+13105550199'
        m.player.save(update_fields=['phone'])
        m.is_scorer = True
        m.save(update_fields=['is_scorer'])

        c = APIClient()
        c.force_authenticate(scorer)
        r = c.post(self._url(), {'force': True}, format='json')
        # A cup round refuses a non-TD outright; a plain one accepts the call
        # and ignores the force. Either way the round does not close.
        self.round.refresh_from_db()
        self.assertEqual(self.round.status, 'in_progress',
                         msg=f'closed by a non-TD ({r.status_code})')
