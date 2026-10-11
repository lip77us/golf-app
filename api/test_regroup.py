"""Redrawing a round's groups between rounds.

A TD re-pairs for round 2 — leaders out last, or just mixing the groups up so
the same four men are not together all week. That was reachable exactly once:
the Set up button renders only for a `pending` round, and setting a round up
flips it to `in_progress`, so the door shut the instant the draw was saved,
hours before anybody teed off.

The real rule is whether anybody has played. It has to be enforced in the
service, because `HoleScore.foursome` is CASCADE — `setup_round` opens by
deleting every foursome in the round, which takes every score with it,
silently, in the same transaction.
"""
from datetime import date
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from services.round_setup import (RoundRegroupLocked, round_has_real_scores,
                                  setup_round)
from tournament.models import Foursome, Round, Tournament

HOLES = [{'number': n, 'par': 4, 'stroke_index': n} for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Duddy Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Duddy Cup', start_date=date(2026, 6, 1),
            total_rounds=2, active_games=['low_net'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=2, status='pending')
        self.players = [
            Player.objects.create(account=self.acct, name=f'G{i}',
                                  short_name=f'G{i}', handicap_index=10)
            for i in range(8)
        ]

    def _draw(self, groups):
        """groups: list of lists of player indexes."""
        return setup_round(self.round, players=[
            {'player_id': self.players[i].id, 'tee_id': self.tee.id,
             'group_number': n}
            for n, g in enumerate(groups, start=1) for i in g
        ], randomise=False)

    def _group_of(self, idx):
        m = Foursome.objects.filter(
            round=self.round, memberships__player=self.players[idx]).first()
        return m and m.group_number


class RedrawingAnUnplayedRoundTests(_Base):

    def test_the_groups_can_be_redrawn_before_anybody_tees_off(self):
        """The whole point. A round that is SET UP but unplayed is the normal
        state between rounds, and it was the state with no way back."""
        self._draw([[0, 1, 2, 3], [4, 5, 6, 7]])
        self.assertEqual(self._group_of(4), 2)

        # Leaders out last: move G4 up with the first group.
        self._draw([[0, 1, 2, 4], [3, 5, 6, 7]])
        self.assertEqual(self._group_of(4), 1)
        self.assertEqual(self._group_of(3), 2)

    def test_in_progress_with_no_scores_is_still_open(self):
        """`pending` was the old gate and it is the wrong question: setting a
        round up flips it to in_progress hours before anybody plays."""
        self._draw([[0, 1, 2, 3], [4, 5, 6, 7]])
        self.round.status = 'in_progress'
        self.round.save(update_fields=['status'])
        self.assertFalse(round_has_real_scores(self.round))
        self._draw([[0, 1, 4, 5], [2, 3, 6, 7]])
        self.assertEqual(self._group_of(4), 1)

    def test_a_posted_score_shuts_it(self):
        fs = self._draw([[0, 1, 2, 3], [4, 5, 6, 7]])[0]
        HoleScore.objects.create(foursome=fs, player=self.players[0],
                                 hole_number=1, gross_score=4)
        with self.assertRaises(RoundRegroupLocked):
            self._draw([[0, 1, 4, 5], [2, 3, 6, 7]])

    def test_the_refusal_is_what_saves_the_scores(self):
        """`HoleScore.foursome` is CASCADE, so without the guard the redraw
        deletes every score in the round — silently, in one transaction. This
        is the test that would fail loudly if the guard were removed."""
        fs = self._draw([[0, 1, 2, 3], [4, 5, 6, 7]])[0]
        for h in range(1, 19):
            HoleScore.objects.create(foursome=fs, player=self.players[0],
                                     hole_number=h, gross_score=4)
        before = HoleScore.objects.filter(
            foursome__round=self.round, player__is_phantom=False).count()
        self.assertEqual(before, 18)
        with self.assertRaises(RoundRegroupLocked):
            self._draw([[0, 1, 4, 5], [2, 3, 6, 7]])
        after = HoleScore.objects.filter(
            foursome__round=self.round, player__is_phantom=False).count()
        self.assertEqual(after, 18)

    def test_a_phantom_score_does_not_count_as_played(self):
        """`setup_round` writes the borrowed 4th's scores itself, so counting
        them would make a round refuse to redraw on its own output."""
        from services.round_setup import create_phantom_hole_scores
        fs = self._draw([[0, 1, 2], [3, 4, 5]])[0]
        if fs.has_phantom:
            create_phantom_hole_scores(fs)
            self.assertTrue(
                HoleScore.objects.filter(foursome=fs,
                                         player__is_phantom=True).exists())
        self.assertFalse(round_has_real_scores(self.round))
        self._draw([[0, 3, 4], [1, 2, 5]])
        self.assertEqual(self._group_of(3), 1)


class TheEndpointSaysSoTests(_Base):

    def _setup_url(self):
        return reverse('api-round-setup', args=[self.round.id])

    def _body(self, groups):
        return {'players': [
            {'player_id': self.players[i].id, 'tee_id': self.tee.id,
             'group_number': n}
            for n, g in enumerate(groups, start=1) for i in g
        ], 'handicap_allowance': 1.0, 'randomise': False}

    def test_a_redraw_of_an_unplayed_round_succeeds(self):
        self.client.post(self._setup_url(),
                         self._body([[0, 1, 2, 3], [4, 5, 6, 7]]),
                         format='json')
        r = self.client.post(self._setup_url(),
                             self._body([[0, 1, 4, 5], [2, 3, 6, 7]]),
                             format='json')
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(self._group_of(4), 1)

    def test_a_played_round_is_refused_with_400_not_500(self):
        """An ordinary TD mistake, not a bug — so it gets a sentence, not a
        stack trace."""
        self.client.post(self._setup_url(),
                         self._body([[0, 1, 2, 3], [4, 5, 6, 7]]),
                         format='json')
        fs = Foursome.objects.filter(round=self.round).first()
        HoleScore.objects.create(foursome=fs,
                                 player=fs.memberships.first().player,
                                 hole_number=1, gross_score=4)
        r = self.client.post(self._setup_url(),
                             self._body([[0, 1, 4, 5], [2, 3, 6, 7]]),
                             format='json')
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn('score', r.data['detail'])

    def test_the_round_reports_whether_a_redraw_is_open(self):
        """The client is TOLD. The rule is `HoleScore.foursome` being CASCADE,
        which is not a fact a phone can see — and the old client gated its one
        entry point on `pending`, which is a different and wrong question."""
        self.client.post(self._setup_url(),
                         self._body([[0, 1, 2, 3], [4, 5, 6, 7]]),
                         format='json')
        url = reverse('api-round-detail', args=[self.round.id])
        d = self.client.get(url).json()
        self.assertEqual(d['status'], 'in_progress')
        self.assertTrue(d['can_regroup'])

        fs = Foursome.objects.filter(round=self.round).first()
        HoleScore.objects.create(foursome=fs,
                                 player=fs.memberships.first().player,
                                 hole_number=1, gross_score=4)
        self.assertFalse(self.client.get(url).json()['can_regroup'])
