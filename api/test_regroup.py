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


class MovingOneGolferTests(_Base):
    """The golfer stuck in traffic: he takes a later tee time, the other
    three play on.

    `POST /rounds/{id}/move-player/` and its sheet were both fully written
    and the sheet had NO CALLER — a menu item was all that was missing, so
    the whole thing had never run. These cover the endpoint, including the
    account scoping it was missing.
    """

    def _move_url(self):
        return reverse('api-round-move-player', args=[self.round.id])

    def _body(self, idx, frm, to):
        return {'player_id': self.players[idx].id,
                'from_foursome_id': frm.id, 'to_foursome_id': to.id}

    def _fs(self, n):
        return Foursome.objects.get(round=self.round, group_number=n)

    def setUp(self):
        super().setUp()
        # A full group going off first and a later one with room — which is
        # the shape the move exists for. Two FULL groups cannot take anybody,
        # and a fixture that forgot that was my first version of these.
        self._draw([[0, 1, 2, 3], [4, 5, 6]])

    def test_moving_out_of_the_FIRST_group_is_refused(self):
        """And this is why a swap exists.

        A group playing short takes its phantom's scores from a full group
        teeing off AHEAD of it, so the first group cannot go short — and the
        first group is exactly where the golfer stuck in traffic is. The
        donor validator refuses it, correctly, and nothing about the move
        endpoint can help him.
        """
        r = self.client.post(self._move_url(),
                             self._body(0, self._fs(1), self._fs(2)),
                             format='json')
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn('donor', r.data['detail'])
        self.assertEqual(self._group_of(0), 1)

    def test_moving_out_of_a_LATER_group_is_fine(self):
        # Group 2 is the short one and group 1 tees off ahead of it, so the
        # donor pool holds.
        self._draw([[0, 1, 2, 3], [4, 5, 6], [7]])
        r = self.client.post(self._move_url(),
                             self._body(4, self._fs(2), self._fs(3)),
                             format='json')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self._group_of(4), 3)

    def test_it_is_refused_once_either_group_has_teed_off(self):
        """The line between this and a withdrawal, not a technicality: a
        group that has scored holes as four must not be rewritten as three."""
        HoleScore.objects.create(foursome=self._fs(1),
                                 player=self.players[1],
                                 hole_number=1, gross_score=4)
        r = self.client.post(self._move_url(),
                             self._body(0, self._fs(1), self._fs(2)),
                             format='json')
        self.assertEqual(r.status_code, 409, r.content)
        self.assertEqual(self._group_of(0), 1)

    def test_the_destination_group_having_started_also_refuses(self):
        HoleScore.objects.create(foursome=self._fs(2),
                                 player=self.players[4],
                                 hole_number=1, gross_score=4)
        r = self.client.post(self._move_url(),
                             self._body(0, self._fs(1), self._fs(2)),
                             format='json')
        self.assertEqual(r.status_code, 409, r.content)

    # ── Swap ────────────────────────────────────────────────────────────

    def _swap_body(self, idx, frm, to, other_idx):
        return {'player_id': self.players[idx].id,
                'from_foursome_id': frm.id, 'to_foursome_id': to.id,
                'swap_with_player_id': self.players[other_idx].id}

    def test_a_late_golfer_swaps_into_a_later_group(self):
        """The actual fix for the traffic case: he trades places with
        somebody in a later group, both groups keep their size, the first
        group tees off on time with four."""
        r = self.client.post(self._move_url(),
                             self._swap_body(0, self._fs(1), self._fs(2), 4),
                             format='json')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self._group_of(0), 2)
        self.assertEqual(self._group_of(4), 1)

    def test_a_swap_changes_nobody_size(self):
        before = [len([m for m in self._fs(n).memberships.all()
                       if not m.player.is_phantom]) for n in (1, 2)]
        self.client.post(self._move_url(),
                         self._swap_body(0, self._fs(1), self._fs(2), 4),
                         format='json')
        after = [len([m for m in self._fs(n).memberships.all()
                      if not m.player.is_phantom]) for n in (1, 2)]
        self.assertEqual(before, after)

    def test_a_swap_is_refused_once_either_group_has_teed_off(self):
        HoleScore.objects.create(foursome=self._fs(1),
                                 player=self.players[1],
                                 hole_number=1, gross_score=4)
        r = self.client.post(self._move_url(),
                             self._swap_body(0, self._fs(1), self._fs(2), 4),
                             format='json')
        self.assertEqual(r.status_code, 409, r.content)
        self.assertEqual(self._group_of(0), 1)

    def test_swapping_with_somebody_not_in_that_group_is_a_404(self):
        r = self.client.post(self._move_url(),
                             self._swap_body(0, self._fs(1), self._fs(2), 1),
                             format='json')
        self.assertEqual(r.status_code, 404, r.content)

    def test_a_swap_keeps_each_golfer_on_his_own_tee(self):
        """A swap moves the golfer, not the tee box — and his playing
        handicap is per-tee, so carrying the other man's would re-net every
        hole he plays."""
        m = self._fs(1).memberships.get(player=self.players[0])
        m.playing_handicap = 7
        m.save(update_fields=['playing_handicap'])
        self.client.post(self._move_url(),
                         self._swap_body(0, self._fs(1), self._fs(2), 4),
                         format='json')
        moved = self._fs(2).memberships.get(player=self.players[0])
        self.assertEqual(moved.playing_handicap, 7)
        self.assertEqual(moved.tee_id, self.tee.id)

    def test_a_full_group_cannot_take_a_fifth(self):
        """Moving INTO the full first group, so the donor rule is satisfied
        (group 2 going short has a full group ahead of it) and the only
        guard that can fire is the to-side one."""
        self._draw([[0, 1, 2, 3], [4, 5, 6, 7]])
        r = self.client.post(self._move_url(),
                             self._body(4, self._fs(2), self._fs(1)),
                             format='json')
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn('4 players', r.data['detail'])

    def test_a_group_cannot_be_cut_below_two(self):
        """Isolated on purpose: with two pairs the only guard that can fire
        is the from-side one, so the assertion cannot pass for the wrong
        reason."""
        self._draw([[0, 1], [2, 3]])
        r = self.client.post(self._move_url(),
                             self._body(0, self._fs(1), self._fs(2)),
                             format='json')
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(self._group_of(0), 1)

    def test_another_account_cannot_rearrange_this_round(self):
        """It used a bare `get_object_or_404(Round, pk=pk)` where every other
        round-level TD view is account-scoped. No caller is almost certainly
        why nobody noticed; wiring it up is what makes it matter.
        """
        other = Account.objects.create(name='Someone Else')
        intruder = User.objects.create_user(username='nosy', account=other)
        intruder.is_account_admin = True
        intruder.save(update_fields=['is_account_admin'])
        c = APIClient()
        c.force_authenticate(intruder)
        r = c.post(self._move_url(),
                   self._body(0, self._fs(1), self._fs(2)), format='json')
        self.assertEqual(r.status_code, 404, r.content)
        self.assertEqual(self._group_of(0), 1)
