"""
api/test_setup_edit.py
----------------------
Correcting a tee or a forced handicap after the round has started.

The refusal this replaces existed for a real reason: `HoleScore
.handicap_strokes` and `net_score` are STORED, so accepting a tee change is a
rewrite of already-scored rows, not a recompute. These tests are written around
the two ways that goes wrong — a rewrite that is incomplete, and a rewrite with
nothing kept to reverse it.

The fixture makes both visible. Paul is off 12 and hole 1 is stroke index 7, so
he strokes on it; forced to 5 he does not. Every assertion about the rescore
hangs off that one hole changing.
"""
from decimal import Decimal

from django.urls import reverse
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import Account, User
from scoring.models import HoleScore
from scoring.tests._helpers import (make_foursome, make_round, make_tee,
                                    submit_hole)
from tournament.models import FoursomeSetupUndo


class _Base(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['low_net_round'])
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(self.round, [('Paul', 12), ('Sam', 20)],
                                tee=self.tee)
        self.m = {m.player.name: m
                  for m in self.fs.memberships.select_related('player')}
        self.pid = {n: m.player_id for n, m in self.m.items()}
        self.user = User.objects.create_user(
            username='td', account=self.round.account, is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    # -- helpers ------------------------------------------------------------

    def _url(self):
        return reverse('api-foursome-tees', args=[self.fs.id])

    def _undo_url(self):
        return reverse('api-foursome-tees-undo', args=[self.fs.id])

    def _force(self, name, value):
        return self.client.patch(
            self._url(),
            {'handicaps': [{'player_id': self.pid[name],
                            'playing_handicap_override': value}]},
            format='json')

    def _play(self, n):
        for h in range(1, n + 1):
            submit_hole(self.fs, h, [(self.pid['Paul'], 4),
                                     (self.pid['Sam'], 5)])

    def _strokes(self, name, hole):
        return HoleScore.objects.get(foursome=self.fs,
                                     player_id=self.pid[name],
                                     hole_number=hole).handicap_strokes

    def _net(self, name, hole):
        return HoleScore.objects.get(foursome=self.fs,
                                     player_id=self.pid[name],
                                     hole_number=hole).net_score


class TheWindowTests(_Base):

    def test_before_a_hole_is_scored_nothing_is_rescored_and_no_undo_is_kept(self):
        """There is nothing to rescore and nothing to reverse — this is still
        plain setup, and it must not start collecting undo state."""
        resp = self._force('Paul', 5)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['holes_rescored'], 0)
        self.assertFalse(resp.data['undo_available'])
        self.assertFalse(FoursomeSetupUndo.objects.filter(
            foursome=self.fs).exists())

    def test_inside_the_window_it_is_accepted(self):
        self._play(3)
        self.assertEqual(self._force('Paul', 5).status_code, 200)

    def test_the_fourth_scored_hole_closes_it(self):
        self._play(4)
        resp = self._force('Paul', 5)
        self.assertEqual(resp.status_code, 400, resp.data)
        self.assertIn('after the first 3 holes', resp.data['detail'])

    def test_a_refused_edit_changes_nothing(self):
        self._play(4)
        self._force('Paul', 5)
        self.m['Paul'].refresh_from_db()
        self.assertIsNone(self.m['Paul'].playing_handicap_override)
        self.assertEqual(self._strokes('Paul', 1), 1)

    def test_a_banker_round_has_no_window_at_all(self):
        """The stricter game rule reaches this endpoint too — it is the shared
        ceiling that is consulted, not a second copy of the threshold."""
        from services.banker import setup_banker
        fs = make_foursome(
            make_round(self.tee.course, active_games=['banker']),
            [('A', 10), ('B', 4), ('C', 18), ('D', 0)], tee=self.tee)
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_banker(fs, first_banker_id=pid['A'])
        submit_hole(fs, 1, [(pid['A'], 4), (pid['B'], 4),
                            (pid['C'], 5), (pid['D'], 4)])
        resp = self.client.patch(
            reverse('api-foursome-tees', args=[fs.id]),
            {'handicaps': [{'player_id': pid['A'],
                            'playing_handicap_override': 6}]}, format='json')
        self.assertEqual(resp.status_code, 400, resp.data)
        self.assertIn('every Banker hole is its own bet', resp.data['detail'])


class RescoreTests(_Base):

    def test_every_played_hole_is_rewritten_not_just_the_next_one(self):
        """A round where hole 1 used one handicap and hole 3 used another is
        not a real result, so the edit is retroactive to the first hole."""
        self._play(3)
        # Stroke indexes 7, 3, 15. Off 12 he strokes on the first two.
        self.assertEqual([self._strokes('Paul', h) for h in (1, 2, 3)],
                         [1, 1, 0])
        resp = self._force('Paul', 5)
        # Off 5 only SI 3 still pops, so hole 1 is the single row to rewrite —
        # and hole 3 must be LEFT, not blanket-zeroed along with it.
        self.assertEqual(resp.data['holes_rescored'], 1)
        self.assertEqual([self._strokes('Paul', h) for h in (1, 2, 3)],
                         [0, 1, 0])

    def test_net_and_stableford_follow_rather_than_being_written(self):
        """`HoleScore.save()` already derives both from the strokes. Writing
        them here as well is how the two come to disagree."""
        self._play(1)
        self.assertEqual(self._net('Paul', 1), 3)
        self._force('Paul', 5)
        self.assertEqual(self._net('Paul', 1), 4)
        hs = HoleScore.objects.get(foursome=self.fs,
                                   player_id=self.pid['Paul'], hole_number=1)
        self.assertEqual(hs.stableford_points, 2)          # net 4 on a par 4

    def test_a_golfer_nobody_edited_is_left_alone(self):
        self._play(3)
        before = [self._strokes('Sam', h) for h in (1, 2, 3)]
        self._force('Paul', 5)
        self.assertEqual([self._strokes('Sam', h) for h in (1, 2, 3)], before)

    def test_an_edit_that_moves_no_stroke_reports_none(self):
        """Off 12 and off 17 both stroke on SI 7. The count is holes actually
        rewritten, so it can honestly be zero — and the confirmation sheet
        would then have nothing to warn about."""
        self._play(1)
        resp = self._force('Paul', 17)
        self.assertEqual(resp.data['holes_rescored'], 0)
        self.assertEqual(self._strokes('Paul', 1), 1)

    def test_the_games_are_recalculated_on_top(self):
        """Rewriting the rows is half of it — every game's summary is computed
        from them and has to be rebuilt, or the board keeps the old answer."""
        from services.low_net_round import low_net_round_summary

        def paul_net():
            rows = low_net_round_summary(self.round)['results']
            row = next(r for r in rows if r['player_id'] == self.pid['Paul'])
            return row['total_net']

        self._play(3)
        self.assertEqual(paul_net(), 12 - 2)    # three 4s, two strokes
        self._force('Paul', 5)
        self.assertEqual(paul_net(), 12 - 1)    # one stroke survives the cut


class UndoTests(_Base):

    def test_it_puts_the_strokes_back(self):
        self._play(3)
        self._force('Paul', 5)
        self.assertEqual(self._strokes('Paul', 1), 0)

        resp = self.client.post(self._undo_url())
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(self._strokes('Paul', 1), 1)
        self.assertEqual(self._net('Paul', 1), 3)

    def test_it_puts_the_setting_back_too(self):
        self._play(3)
        self._force('Paul', 5)
        self.client.post(self._undo_url())
        self.m['Paul'].refresh_from_db()
        self.assertIsNone(self.m['Paul'].playing_handicap_override)
        self.assertEqual(self.m['Paul'].playing_handicap, 12)

    def test_restoring_writes_the_stored_numbers_rather_than_re_deriving(self):
        """The whole point. Once `handicap_strokes` is overwritten there is
        nothing left to derive the old value FROM — a restore that recomputed
        would compute it under settings that no longer exist anywhere."""
        self._play(1)
        self._force('Paul', 5)
        undo = FoursomeSetupUndo.objects.get(foursome=self.fs)
        rows = {(r['player_id'], r['hole_number']): r
                for r in undo.payload['hole_scores']}
        self.assertEqual(rows[(self.pid['Paul'], 1)]['handicap_strokes'], 1)
        self.assertEqual(rows[(self.pid['Paul'], 1)]['net_score'], 3)

    def test_the_step_is_spent_once_used(self):
        """An undo of an undo is a second step, which this deliberately is
        not — and a second press would re-apply values the round has moved
        past."""
        self._play(1)
        self._force('Paul', 5)
        self.assertEqual(self.client.post(self._undo_url()).status_code, 200)
        second = self.client.post(self._undo_url())
        self.assertEqual(second.status_code, 400, second.data)
        self.assertIn('nothing to undo', second.data['detail'])

    def test_a_second_edit_replaces_the_step_and_makes_the_first_permanent(self):
        """One step, not a growing stack. Undoing after two edits takes you
        back to the second, never the first."""
        self._play(1)
        self._force('Paul', 5)            # 12 -> 5, hole 1 loses its stroke
        self._force('Paul', 20)           # 5 -> 20, it gets one back
        self.assertEqual(self._strokes('Paul', 1), 1)

        self.client.post(self._undo_url())
        self.assertEqual(self._strokes('Paul', 1), 0)      # back to the 5
        self.m['Paul'].refresh_from_db()
        self.assertEqual(self.m['Paul'].playing_handicap_override, 5)

    def test_the_response_says_a_step_is_standing_before_the_next_edit(self):
        """The client has to be able to say "this replaces your last change"
        BEFORE the second edit. Discovering it afterwards is too late to be
        of any use."""
        self._play(1)
        first = self._force('Paul', 5)
        self.assertTrue(first.data['undo_available'])
        self.assertIn('hcp 12', first.data['undo_note'])

    def test_the_note_names_the_golfer_and_the_change(self):
        self._play(1)
        self._force('Paul', 5)
        undo = FoursomeSetupUndo.objects.get(foursome=self.fs)
        self.assertIn('hcp 12', undo.note)
        self.assertIn('5', undo.note)

    def test_get_reports_whether_there_is_one(self):
        self._play(1)
        self.assertFalse(self.client.get(self._undo_url()).data['available'])
        self._force('Paul', 5)
        resp = self.client.get(self._undo_url())
        self.assertTrue(resp.data['available'])
        self.assertTrue(resp.data['note'])

    def test_another_accounts_foursome_is_not_reachable(self):
        other = Account.objects.create(name='Somebody Else')
        intruder = User.objects.create_user(
            username='them', account=other, is_account_admin=True)
        self._play(1)
        self._force('Paul', 5)
        self.client.force_authenticate(intruder)
        self.assertEqual(self.client.post(self._undo_url()).status_code, 404)


class TeeChangeTests(_Base):
    """A tee change is the harder half: it moves the group's lowest par, so a
    golfer nobody named can come out on a different playing handicap."""

    def setUp(self):
        super().setUp()
        self.blue = make_tee(self.tee.course, tee_name='Blue', slope=125,
                             course_rating=73.5)

    def _move(self, name, tee):
        return self.client.patch(
            self._url(),
            {'tees': [{'player_id': self.pid[name], 'tee_id': tee.id}]},
            format='json')

    def test_a_tee_change_inside_the_window_rescores(self):
        self._play(3)
        resp = self._move('Paul', self.blue)
        self.assertEqual(resp.status_code, 200, resp.data)
        self.m['Paul'].refresh_from_db()
        self.assertEqual(self.m['Paul'].tee_id, self.blue.id)

    def test_the_undo_covers_golfers_the_request_never_named(self):
        """The snapshot is the whole foursome on purpose. Restoring only the
        named golfer would leave the others on par-adjusted numbers nobody
        chose — and nothing would look wrong."""
        self._play(1)
        self._move('Paul', self.blue)
        undo = FoursomeSetupUndo.objects.get(foursome=self.fs)
        captured = {r['player_id'] for r in undo.payload['memberships']}
        self.assertEqual(captured, set(self.pid.values()))

    def test_undoing_a_tee_change_puts_the_tee_back(self):
        self._play(2)
        self._move('Paul', self.blue)
        self.client.post(self._undo_url())
        self.m['Paul'].refresh_from_db()
        self.assertEqual(self.m['Paul'].tee_id, self.tee.id)

    def test_the_note_names_the_tees(self):
        self._play(1)
        self._move('Paul', self.blue)
        undo = FoursomeSetupUndo.objects.get(foursome=self.fs)
        self.assertIn('White', undo.note)
        self.assertIn('Blue', undo.note)
