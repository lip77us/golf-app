"""
api/test_stableford.py
----------------------
Casual Stableford: editable 6-bucket points table (Net%/Gross, no Strokes-Off),
ranked standings, and Low-Net-style prize payouts. Gross mode is used here so
the table + ranking + money are exercised without handicap allocation.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Round, Foursome, FoursomeMembership
from scoring.models import HoleScore


User = get_user_model()

# 18 par-4 holes, stroke index 1..18.
HOLES = [{'number': i, 'par': 4, 'stroke_index': i} for i in range(1, 19)]


class StablefordTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.client = APIClient(); self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.acct, name='Pines')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, sex='M',
            sort_priority=0, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=self.course, status='in_progress',
            active_games=[])
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        # Three players: A all birdies, B all pars, C all bogeys.
        self.pa = self._player('A', gross=3)
        self.pb = self._player('B', gross=4)
        self.pc = self._player('C', gross=5)

    def _player(self, name, *, gross):
        p = Player.objects.create(
            account=self.acct, name=name, handicap_index=Decimal('0.0'))
        FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        for h in range(1, 19):
            HoleScore.objects.create(
                foursome=self.fs, player=p, hole_number=h,
                gross_score=gross, handicap_strokes=0)
        return p

    def _setup(self, **body):
        body.setdefault('handicap_mode', 'gross')
        return self.client.post(
            reverse('api-stableford-setup', args=[self.round.id]),
            body, format='json')

    def _result(self):
        return self.client.get(
            reverse('api-stableford-result', args=[self.round.id])).data

    # ---- setup ----
    def test_setup_activates_game_and_defaults(self):
        r = self._setup()
        self.assertEqual(r.status_code, 201, r.data)
        self.round.refresh_from_db()
        self.assertIn('stableford', self.round.active_games)
        self.assertEqual(r.data['pts_birdie'], 3)   # standard default

    # ---- standard table: birdie 3 / par 2 / bogey 1 ----
    def test_standard_table_ranking(self):
        self._setup()
        res = self._result()
        rows = {row['player_name']: row for row in res['results']}
        self.assertEqual(rows['A']['total_points'], 18 * 3)  # birdies
        self.assertEqual(rows['B']['total_points'], 18 * 2)  # pars
        self.assertEqual(rows['C']['total_points'], 18 * 1)  # bogeys
        self.assertEqual(rows['A']['rank'], 1)
        self.assertEqual(rows['C']['rank'], 3)

    # ---- modified table (8/5/2/0/-1/-3) changes the spread ----
    def test_modified_table(self):
        self._setup(pts_eagle=5, pts_birdie=2, pts_par=0,
                    pts_bogey=-1, pts_double=-3, pts_albatross=8)
        rows = {r['player_name']: r for r in self._result()['results']}
        self.assertEqual(rows['A']['total_points'], 18 * 2)    # birdies → 2
        self.assertEqual(rows['B']['total_points'], 0)          # pars → 0
        self.assertEqual(rows['C']['total_points'], 18 * -1)    # bogeys → -1
        self.assertEqual(rows['A']['rank'], 1)

    # ---- money: pool + payout to the winner ----
    def test_payouts(self):
        self._setup(entry_fee='10.00',
                    payouts=[{'place': 1, 'amount': '30.00'}])
        res = self._result()
        self.assertEqual(res['pool'], 30.0)        # 10 × 3 players
        rows = {r['player_name']: r for r in res['results']}
        self.assertEqual(rows['A']['payout'], 30.0)
        self.assertIsNone(rows['B']['payout'])

    def test_per_point_vs_average_is_the_default(self):
        # 3 players, points 54 / 36 / 18 (birdies/pars/bogeys), $1 a point.
        # No per_point_mode → the new standard: settle vs the field average
        # (mean 36). net = (pts − mean) × rate.
        self._setup(payout_style='per_point', per_point_rate='1.00')
        rows = {r['player_name']: r for r in self._result()['results']}
        self.assertEqual(rows['A']['payout'], 54 - 36)   # +18
        self.assertEqual(rows['B']['payout'], 36 - 36)   #   0
        self.assertEqual(rows['C']['payout'], 18 - 36)   # -18
        self.assertEqual(sum(r['payout'] for r in rows.values()), 0)

    def test_per_point_pay_everyone_above_you(self):
        # 3 players, points 54 / 36 / 18 (birdies/pars/bogeys), $1 a point.
        self._setup(payout_style='per_point', per_point_rate='1.00',
                    per_point_mode='all')
        rows = {r['player_name']: r for r in self._result()['results']}
        # net = rate × (n·pts − total); total = 108, n = 3.
        self.assertEqual(rows['A']['payout'], 3 * 54 - 108)   # +54
        self.assertEqual(rows['B']['payout'], 3 * 36 - 108)   #   0
        self.assertEqual(rows['C']['payout'], 3 * 18 - 108)   # -54
        # Zero-sum.
        self.assertEqual(sum(r['payout'] for r in rows.values()), 0)

    def test_per_point_loss_cap_clips_and_rescales(self):
        # vs-average raw is A +18 / B 0 / C −18. Cap C at $10 → C pays 10,
        # winner A (owed 18) rescales to 10, still zero-sum.
        self._setup(payout_style='per_point', per_point_rate='1.00',
                    loss_cap='10.00')
        rows = {r['player_name']: r for r in self._result()['results']}
        self.assertEqual(rows['C']['payout'], -10.0)
        self.assertEqual(rows['A']['payout'], 10.0)
        self.assertEqual(rows['B']['payout'], 0.0)
        self.assertEqual(sum(r['payout'] for r in rows.values()), 0)
        self.assertEqual(self._result()['loss_cap'], 10.0)

    def test_leaderboard_has_low_net_scores_tab(self):
        # A casual Stableford round still exposes a Low Net (scores) block so
        # players can see gross/net totals, not just points.
        self._setup()
        data = self.client.get(
            reverse('api-leaderboard', args=[self.round.id])).data
        self.assertIn('stableford', data['games'])
        self.assertIn('low_net_round', data['games'])  # scores fallback

    def test_watch_page_renders(self):
        self._setup(payout_style='per_point', per_point_rate='1.00')
        from django.test import Client
        resp = Client().get(
            f'/watch/{self.round.watch_token}/?view=stableford')
        self.assertEqual(resp.status_code, 200)
        self.assertContains(resp, 'Stableford')
        self.assertContains(resp, 'A')  # player names render

    def test_per_point_first_only(self):
        # Only the leader (A) collects; B and C pay their deficit × $1.
        self._setup(payout_style='per_point', per_point_rate='1.00',
                    per_point_mode='first')
        rows = {r['player_name']: r for r in self._result()['results']}
        self.assertEqual(rows['A']['payout'], (54 - 36) + (54 - 18))  # +54
        self.assertEqual(rows['B']['payout'], -(54 - 36))              # -18
        self.assertEqual(rows['C']['payout'], -(54 - 18))              # -36
        self.assertEqual(sum(r['payout'] for r in rows.values()), 0)

    def test_excluded_player_gets_no_money(self):
        self._setup(entry_fee='10.00',
                    payouts=[{'place': 1, 'amount': '30.00'}],
                    excluded_player_ids=[self.pa.id])
        rows = {r['player_name']: r for r in self._result()['results']}
        # A excluded → no payout; the prize falls to the next eligible (B).
        self.assertIsNone(rows['A']['payout'])
        self.assertTrue(rows['A']['excluded'])
        self.assertEqual(rows['B']['payout'], 30.0)

    # ---- stroke visibility on the points grid (Index row + per-cell dots) ----
    # ---- the scorecard block ----
    def test_scorecard_strokes_are_prospective_across_the_whole_round(self):
        """**Every hole, with its strokes, before any of them is played.**

        The block used to derive its holes from what had a GROSS on it and its
        strokes from gross minus net — both of which exist only once a hole is
        scored. So the card grew a column at a time and a golfer could not see
        where his shots fell until he had taken them, on the one game where
        knowing which holes give a stroke is how you decide whether to go for a
        green.
        """
        m = FoursomeMembership.objects.get(foursome=self.fs, player=self.pa)
        m.playing_handicap = 10
        m.save(update_fields=['playing_handicap'])
        HoleScore.objects.filter(foursome=self.fs).delete()
        self._setup(handicap_mode='net', net_percent=50)

        card = self._result()['scorecard']
        self.assertEqual([h['hole'] for h in card['holes']], list(range(1, 19)))
        self.assertEqual(card['holes_in_play'], list(range(1, 19)))

        def strokes_on(hole):
            row = next(h for h in card['holes'] if h['hole'] == hole)
            cell = next(c for c in row['scores']
                        if c['player_id'] == self.pa.id)
            return cell['strokes']

        # 10 off at 50% is 5 strokes — SI 1..5, and the SI is the hole number.
        self.assertEqual(strokes_on(1), 1)
        self.assertEqual(strokes_on(5), 1)
        self.assertEqual(strokes_on(6), 0)
        # ...with no gross anywhere, because nothing has been played.
        self.assertTrue(all(c['gross'] is None
                            for h in card['holes'] for c in h['scores']))

    def test_scorecard_shows_a_double_stroke_as_two(self):
        """**Two strokes on a hole is a 2, and it is there before the round.**

        A golfer off more than the course's eighteen strokes on every hole and
        twice on the hardest, and that second stroke is the thing a playing
        partner most wants to know in advance. The count is not capped on the
        way out; the shared card draws a dot per stroke.
        """
        m = FoursomeMembership.objects.get(foursome=self.fs, player=self.pa)
        m.playing_handicap = 22
        m.save(update_fields=['playing_handicap'])
        HoleScore.objects.filter(foursome=self.fs).delete()
        self._setup(handicap_mode='net', net_percent=100)

        card = self._result()['scorecard']

        def strokes_on(hole):
            row = next(h for h in card['holes'] if h['hole'] == hole)
            return next(c for c in row['scores']
                        if c['player_id'] == self.pa.id)['strokes']

        # 22 = one stroke everywhere, plus a second on SI 1..4.
        self.assertEqual(strokes_on(1), 2)
        self.assertEqual(strokes_on(4), 2)
        self.assertEqual(strokes_on(5), 1)
        self.assertEqual(strokes_on(18), 1)

    def test_scorecard_carries_each_hole_s_points(self):
        # One card draws the gross block and the points block over the same
        # hole columns, which is what makes a MODIFIED table readable: a bare
        # `3` could be a net birdie or a gross par.
        self._setup(handicap_mode='gross')
        card = self._result()['scorecard']
        row = next(h for h in card['holes'] if h['hole'] == 1)
        pts = {c['player_id']: c['points'] for c in row['scores']}
        # A birdies every hole (3 on a par 4) → 3 on the standard table;
        # B pars → 2, C bogeys → 1.
        self.assertEqual(pts[self.pa.id], 3)
        self.assertEqual(pts[self.pb.id], 2)
        self.assertEqual(pts[self.pc.id], 1)

    def test_scorecard_greens_nobody(self):
        # Stableford has no hole WINNER — every golfer scores his own points
        # against par, so there is nobody for the shared card to tint.
        self._setup(handicap_mode='gross')
        card = self._result()['scorecard']
        self.assertTrue(all(h['winner_id'] is None for h in card['holes']))

    def test_summary_exposes_stroke_index_and_net_strokes(self):
        # Give A a handicap; net at 50% → effective 5 → strokes on SI 1..5
        # (HOLES stroke_index == hole number).
        m = FoursomeMembership.objects.get(foursome=self.fs, player=self.pa)
        m.playing_handicap = 10
        m.save(update_fields=['playing_handicap'])
        self._setup(handicap_mode='net', net_percent=50)
        res = self._result()

        # Stroke-index map is always present (drives the "Index" row). Keys are
        # ints in the DRF response data (JSON-stringified only over the wire).
        self.assertEqual(res['stroke_index'][1], 1)
        self.assertEqual(res['stroke_index'][18], 18)

        rows = {r['player_name']: r for r in res['results']}
        # A (hcp 10 @ 50% = 5) gets a stroke on holes 1-5, none on 6+.
        a_strokes = rows['A']['strokes']
        self.assertEqual(a_strokes.get(1), 1)
        self.assertEqual(a_strokes.get(5), 1)
        self.assertIsNone(a_strokes.get(6))
        # Scratch B gets no strokes at all.
        self.assertEqual(rows['B']['strokes'], {})
