"""
api/test_partial_rounds.py
--------------------------
End-to-end backend behavior for partial rounds (Phase 2 of
docs/hole-flexibility.md): a 9-hole round completes on its 9 holes, not 18.
Grows as later sub-slices (per-hole scoring, handicap, segment games) land.
"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from decimal import Decimal

from accounts.models import Account
from api.views import RoundCompleteView
from core.models import Course, Player, Tee
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)

User = get_user_model()


class PartialRoundCompletionTests(TestCase):
    def _nine_hole_round(self):
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES[:9])
        r = make_round(course=course)
        r.num_holes = 9
        r.starting_hole = 1
        r.save()
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        return r, fs

    def test_nine_hole_round_completes_on_nine(self):
        r, fs = self._nine_hole_round()
        # 8 of 9 holes scored -> not done.
        for h in range(1, 9):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertFalse(RoundCompleteView._all_foursomes_done(r))
        # Score the 9th -> done (never needs holes 10-18).
        submit_hole(fs, 9, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertTrue(RoundCompleteView._all_foursomes_done(r))

    def test_expected_holes_is_the_nine_played(self):
        r, fs = self._nine_hole_round()
        self.assertEqual(RoundCompleteView._expected_holes(fs), set(range(1, 10)))


class RoundCreateHolesTests(TestCase):
    """The create endpoint persists num_holes/starting_hole and clamps them to
    the course size."""

    def setUp(self):
        self.account = Account.objects.create(name='Create Holes')
        self.user = User.objects.create_user(username='td', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _course(self, holes):
        """A course + tee owned by the test user's account (so create passes
        the account scope check)."""
        course = Course.objects.create(name='Create GC', account=self.account)
        Tee.objects.create(course=course, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=holes)
        return course

    def _create(self, course, **extra):
        body = {'course_id': course.id, 'date': '2026-07-07',
                'active_games': ['low_net_round'], **extra}
        return self.client.post(reverse('api-round-create'), body, format='json')

    def test_defaults_are_full_18(self):
        resp = self._create(self._course(DEFAULT_HOLES))
        self.assertEqual(resp.status_code, 201)
        self.assertEqual((resp.data['num_holes'], resp.data['starting_hole']), (18, 1))

    def test_back_nine_persists(self):
        resp = self._create(self._course(DEFAULT_HOLES), num_holes=9, starting_hole=10)
        self.assertEqual((resp.data['num_holes'], resp.data['starting_hole']), (9, 10))

    def test_num_holes_clamped_to_short_course(self):
        resp = self._create(self._course(DEFAULT_HOLES[:9]), num_holes=18, starting_hole=1)
        self.assertEqual(resp.data['num_holes'], 9)   # clamped to the 9-hole course


class ClearScoreTests(TestCase):
    """gross_score=null clears (deletes) a HoleScore — the trailing-only Clear."""

    def setUp(self):
        from core.models import Tee
        from tournament.models import Round, Foursome, FoursomeMembership
        from scoring.models import HoleScore
        self.HoleScore = HoleScore
        self.account = Account.objects.create(name='Clear Test')
        self.user = User.objects.create_user(username='cs', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.course = Course.objects.create(name='CS GC', account=self.account)
        tee = Tee.objects.create(course=self.course, tee_name='White', slope=113,
                                 course_rating=Decimal('72.0'), par=72,
                                 holes=DEFAULT_HOLES)
        self.round = Round.objects.create(
            account=self.account, course=self.course, status='in_progress',
            active_games=['low_net_round'])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.amy = Player.objects.create(account=self.account, name='Amy',
                                         handicap_index=Decimal('10.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=self.amy, tee=tee,
            course_handicap=10, playing_handicap=10)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-score-submit', args=[self.fs.id])

    def _submit(self, gross):
        return self.client.post(self.url, {
            'hole_number': 1,
            'scores': [{'player_id': self.amy.id, 'gross_score': gross}],
        }, format='json')

    def test_null_gross_clears_the_score(self):
        self.assertEqual(self._submit(5).status_code, 200)
        self.assertTrue(self.HoleScore.objects.filter(
            foursome=self.fs, player=self.amy, hole_number=1,
            gross_score__isnull=False).exists())
        # Clear it.
        self.assertEqual(self._submit(None).status_code, 200)
        self.assertFalse(self.HoleScore.objects.filter(
            foursome=self.fs, player=self.amy, hole_number=1).exists())


class LowNetHolesInPlayTests(TestCase):
    """The low-net block declares every hole the round plays (with pars) so the
    leaderboard strip can render not-yet-played holes as blanks — matching the
    score-entry card."""

    def test_summary_lists_all_holes_with_pars(self):
        from services.low_net_round import low_net_round_summary
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES)
        r = make_round(course=course, active_games=['low_net_round'])
        fs = make_foursome(r, [('Amy', 0), ('Bob', 0)])
        # Full 18-hole round with holes 10 & 11 left unplayed.
        for h in list(range(1, 10)) + list(range(12, 19)):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])

        summ = low_net_round_summary(r)
        self.assertEqual(summ['holes_in_play'], list(range(1, 19)))
        # Par is available for the unplayed holes too (so they render, not vanish).
        self.assertIn(10, summ['hole_pars'])
        self.assertIn(11, summ['hole_pars'])


class BackNineCompletionTests(TestCase):
    def test_back_nine_completes_on_10_to_18(self):
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES)   # full 18-hole course
        r = make_round(course=course)
        r.num_holes = 9
        r.starting_hole = 10
        r.save()
        fs = make_foursome(r, [('Amy', 10), ('Bob', 12)])
        self.assertEqual(RoundCompleteView._expected_holes(fs), set(range(10, 19)))
        for h in range(10, 19):
            submit_hole(fs, h, [(m.player_id, 4) for m in fs.memberships.all()])
        self.assertTrue(RoundCompleteView._all_foursomes_done(r))


class ShotgunAssignmentTests(TestCase):
    """The TD sets a group's per-group starting hole + tee-slot label via
    PATCH /api/foursomes/{id}/ (shotgun start)."""

    def setUp(self):
        from tournament.models import Round, Foursome
        self.account = Account.objects.create(name='Shotgun GC')
        self.user = User.objects.create_user(username='sgtd', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.course = Course.objects.create(name='SG', account=self.account)
        Tee.objects.create(course=self.course, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=DEFAULT_HOLES)
        self.round = Round.objects.create(
            account=self.account, course=self.course, status='in_progress',
            active_games=['sixes'])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        self.url = reverse('api-foursome-detail', args=[self.fs.id])

    def test_set_starting_hole_and_slot(self):
        resp = self.client.patch(
            self.url, {'starting_hole': 8, 'shotgun_slot': 'a'}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(resp.data['starting_hole'], 8)
        self.assertEqual(resp.data['shotgun_slot'], 'A')   # upper-cased
        self.fs.refresh_from_db()
        self.assertEqual(self.fs.starting_hole, 8)

    def test_out_of_range_starting_hole_is_400(self):
        resp = self.client.patch(self.url, {'starting_hole': 19}, format='json')
        self.assertEqual(resp.status_code, 400)

    def test_null_starting_hole_clears_to_inherit(self):
        self.fs.starting_hole = 8
        self.fs.save(update_fields=['starting_hole'])
        resp = self.client.patch(self.url, {'starting_hole': None}, format='json')
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertIsNone(resp.data['starting_hole'])

    def test_non_admin_forbidden(self):
        other = User.objects.create_user(username='plain', account=self.account)
        c = APIClient(); c.force_authenticate(other)
        resp = c.patch(self.url, {'starting_hole': 8}, format='json')
        self.assertEqual(resp.status_code, 403)


class LowNetProspectiveStrokePlanTests(TestCase):
    """The Stroke Play summary carries a prospective full-round stroke plan for
    EVERY real player — including before any score is entered — so the scorecard
    can show where each player's handicap strokes fall up front."""

    def test_stroke_plan_present_before_any_scores(self):
        from services.low_net_round import low_net_round_summary
        course = make_course()
        make_tee(course=course, holes=DEFAULT_HOLES)
        r = make_round(course=course, active_games=['low_net_round'])
        # Amy scratch, Bob playing handicap 9 (net 100% default).
        make_foursome(r, [('Amy', 0), ('Bob', 9)])

        summ = low_net_round_summary(r)          # no holes submitted yet
        rows = {x['name']: x for x in summ['results']}
        # Both players appear before the round starts.
        self.assertIn('Amy', rows)
        self.assertIn('Bob', rows)

        # Bob (hcp 9) gets 9 strokes — on every hole with SI ≤ 9. In DEFAULT_HOLES
        # hole 5 is SI 1 (stroke) and hole 3 is SI 15 (no stroke).
        self.assertEqual(rows['Bob']['total_strokes'], 9)
        self.assertEqual(rows['Bob']['stroke_plan'].get(5), 1)
        self.assertIsNone(rows['Bob']['stroke_plan'].get(3))
        self.assertEqual(rows['Bob']['holes_played'], 0)   # nothing scored

        # Scratch Amy gets no strokes anywhere, and (unscored) wins no money.
        self.assertEqual(rows['Amy']['total_strokes'], 0)
        self.assertEqual(rows['Amy']['stroke_plan'], {})


class ShotgunProgressTests(TestCase):
    """**"Through N" is a COUNT of holes played, not the highest hole number.**

    The two are the same figure on a round that starts on the 1st, which is
    why this survived: on a shotgun from 13 a group that has played six holes
    has scored hole 18, and the rounds list said "Through 18" on a round with
    twelve holes still to go — a round that reads as finished.
    """

    def setUp(self):
        from scoring.tests._helpers import (make_tee, make_round,
                                            make_foursome, _test_account)
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        self.round.starting_hole = 13
        self.round.num_holes = 18
        self.round.save(update_fields=['starting_hole', 'num_holes'])
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 0), ('C', 0), ('D', 0)], tee=self.tee)
        self.fs.starting_hole = 13
        self.fs.save(update_fields=['starting_hole'])
        self.pids = [m.player_id for m in self.fs.memberships.all()]

    def _play(self, holes):
        from scoring.tests._helpers import submit_hole
        for h in holes:
            submit_hole(self.fs, h, [(p, 4) for p in self.pids])

    def test_six_holes_of_a_shotgun_is_through_six(self):
        from api.views import _round_current_hole
        from services.hole_plan import play_order
        order = play_order(self.round, self.fs)
        self.assertEqual(order[:6], [13, 14, 15, 16, 17, 18])
        self._play(order[:6])
        self.assertEqual(_round_current_hole(self.round), 6,
                         'the highest hole number scored is 18; the group has '
                         'played six')

    def test_fifteen_played_is_through_fifteen(self):
        from api.views import _round_current_hole
        from services.hole_plan import play_order
        self._play(play_order(self.round, self.fs)[:15])
        self.assertEqual(_round_current_hole(self.round), 15)

    def test_a_round_from_the_first_is_unchanged(self):
        """The shipped behaviour is the degenerate case and must not move."""
        from api.views import _round_current_hole
        self.round.starting_hole = 1
        self.round.save(update_fields=['starting_hole'])
        self.fs.starting_hole = 1
        self.fs.save(update_fields=['starting_hole'])
        self._play(range(1, 8))
        self.assertEqual(_round_current_hole(self.round), 7)

    def test_two_groups_are_not_added_together(self):
        """Counting distinct hole numbers across the round would report twelve
        for a round where every group has played six."""
        from api.views import _round_current_hole
        from scoring.tests._helpers import make_foursome
        from services.hole_plan import play_order
        other = make_foursome(
            self.round, [('E', 0), ('F', 0), ('G', 0), ('H', 0)],
            tee=self.tee, group_number=2)
        other.starting_hole = 1
        other.save(update_fields=['starting_hole'])
        self._play(play_order(self.round, self.fs)[:6])
        from scoring.tests._helpers import submit_hole
        opids = [m.player_id for m in other.memberships.all()]
        for h in play_order(self.round, other)[:6]:
            submit_hole(other, h, [(p, 4) for p in opids])
        self.assertEqual(_round_current_hole(self.round), 6)

    def test_nothing_scored_is_not_started(self):
        from api.views import _round_current_hole
        self.assertEqual(_round_current_hole(self.round), 0)
