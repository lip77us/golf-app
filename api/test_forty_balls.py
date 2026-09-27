"""
api/test_forty_balls.py
-----------------------
40 Balls at the edges: the setup endpoint, the group's pick, the board and the
settlement pot.

The engine is tested in `scoring/tests/test_forty_balls.py`. What is here is
what the wiring decides on its own — above all the **three-way exclusion**,
which is a rule about the ROUND and therefore has to hold wherever a round is
edited from, not only in the wizard.
"""
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import Account, User
from games.models import FortyBallsConfig, FortyBallsHoleCount
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
    make_tournament, submit_hole,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}


class _Base(TestCase):
    def setUp(self):
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tourn = make_tournament(name='Autumn Cup')
        self.round = make_round(course=self.course, tournament=self.tourn,
                                active_games=[])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Bea', 0), ('Cal', 0), ('Dee', 0)],
            tee=self.tee)
        self.fs2 = make_foursome(
            self.round, [('Eve', 0), ('Fay', 0), ('Gus', 0), ('Hal', 0)],
            tee=self.tee, group_number=2)
        self.pids = [m.player_id for m in self.fs.memberships.order_by('id')]

        self.account = self.course.account
        self.user = User.objects.create_user(
            username='td', password='x', account=self.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def setup_url(self):
        return f'/api/rounds/{self.round.id}/forty-balls/setup/'

    def count_url(self, fs=None):
        return f'/api/foursomes/{(fs or self.fs).id}/forty-balls/count/'

    def configure(self, **kw):
        body = {'handicap_mode': 'net', 'net_percent': 100,
                'net_max_double_bogey': True, 'entry_fee': '10.00',
                'payouts': [{'place': 1, 'amount': '150.00'}]}
        body.update(kw)
        return self.client.post(self.setup_url(), body, format='json')

    def par_hole(self, hole, *deltas, fs=None):
        target = fs or self.fs
        pids = [m.player_id for m in target.memberships.order_by('id')]
        submit_hole(target, hole, [(p, PAR[hole] + d)
                                   for p, d in zip(pids, deltas)])


class SetupTests(_Base):
    def test_the_card_states_each_group_s_budget_and_the_TD_sets_none(self):
        r = self.client.get(self.setup_url())
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data['configured'])
        self.assertEqual([g['budget'] for g in r.data['groups']], [40, 40])
        self.assertEqual([g['size'] for g in r.data['groups']], [4, 4])
        # Nothing in the payload is a ball plan.
        self.assertNotIn('segments', r.data)

    def test_a_threesome_s_budget_is_thirty(self):
        self.fs2.memberships.order_by('id').last().delete()
        r = self.client.get(self.setup_url())
        self.assertEqual([g['budget'] for g in r.data['groups']], [40, 30])

    def test_post_saves_and_turns_the_game_on(self):
        self.assertEqual(self.configure().status_code, 201)
        self.round.refresh_from_db()
        self.assertIn('forty_balls', self.round.active_games)
        self.assertTrue(FortyBallsConfig.objects.filter(
            round=self.round).exists())

    def test_turning_it_on_turns_the_OTHER_TWO_off(self):
        # **The rule is about the round**, so it holds here and not only in the
        # wizard: two of these collect two entries for one set of group nets.
        self.round.active_games = ['irish_rumble', 'better_ball', 'skins']
        self.round.save(update_fields=['active_games'])
        self.configure()
        self.round.refresh_from_db()
        self.assertNotIn('irish_rumble', self.round.active_games)
        self.assertNotIn('better_ball', self.round.active_games)
        self.assertIn('forty_balls', self.round.active_games)
        # Anything else the round was playing is untouched.
        self.assertIn('skins', self.round.active_games)

    def test_the_allowance_moves_in_fives(self):
        self.assertEqual(self.configure(net_percent=87).status_code, 400)
        self.assertEqual(self.configure(net_percent=85).status_code, 201)

    def test_the_allowance_spans_what_the_SHARED_control_offers(self):
        # The screen uses `HandicapModeSelector`, the same control Irish Rumble
        # and nineteen others use, and its slider runs 50–130 — some formats
        # give more than full allowance. A 50–100 validator would reject what
        # the control can produce.
        self.assertEqual(self.configure(net_percent=130).status_code, 201)
        self.assertEqual(self.configure(net_percent=50).status_code, 201)
        self.assertEqual(self.configure(net_percent=135).status_code, 400)
        self.assertEqual(self.configure(net_percent=45).status_code, 400)

    def test_another_account_cannot_configure_it(self):
        other = Account.objects.create(name='Someone Else')
        user = User.objects.create_user(username='x', password='x',
                                        account=other, is_account_admin=True)
        c = APIClient()
        c.force_authenticate(user)
        self.assertEqual(c.post(self.setup_url(), {}, format='json').status_code,
                         404)


class CountTests(_Base):
    def setUp(self):
        super().setUp()
        self.configure()

    def test_the_state_reports_the_bounds_before_a_pick(self):
        self.par_hole(1, 0, 0, 0, 0)
        r = self.client.get(self.count_url() + '?hole=1')
        self.assertEqual(r.status_code, 200)
        st = r.data['state']
        self.assertEqual((st['lo'], st['hi']), (0, 4))
        self.assertIsNone(st['count'])
        self.assertTrue(st['can_pick'])
        self.assertEqual(st['slack'], 18 * 4 - 40)     # 32, and only falls

    def test_a_pick_is_recorded_and_the_card_comes_back(self):
        self.par_hole(1, -1, 0, 0, 0)
        r = self.client.post(self.count_url(),
                             {'hole_number': 1, 'count': 1}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['state']['count'], 1)
        self.assertEqual(r.data['card']['holes'][0]['result'], -1)
        self.assertEqual(r.data['card']['spent'], 1)

    def test_a_refusal_is_409_and_says_what_is_wrong(self):
        # The body was well formed; the refusal is about the round's state,
        # which a client handles by re-reading rather than re-prompting.
        #
        # **The client sends the hole's scores FIRST and the count with them**,
        # so reaching this means the scores did not land — not that the group
        # picked too early. The message says so.
        r = self.client.post(self.count_url(),
                             {'hole_number': 1, 'count': 2}, format='json')
        self.assertEqual(r.status_code, 409)
        self.assertIn('no scores on the server', r.data['detail'])

    def test_the_bounds_come_back_before_the_hole_is_posted(self):
        # So the picker can draw while the group is still entering.
        r = self.client.get(self.count_url() + '?hole=1')
        st = r.data['state']
        self.assertTrue(st['can_pick'])
        self.assertFalse(st['scores_in'])
        self.assertEqual((st['lo'], st['hi']), (0, 4))
        # And what the client needs to work the nets out locally.
        self.assertEqual(st['handicap_mode'], 'net')
        self.assertTrue(st['cap'])

    def test_a_count_above_the_group_size_is_a_400(self):
        # That one IS a malformed body — there is no fifth golfer.
        self.par_hole(1, 0, 0, 0, 0)
        r = self.client.post(self.count_url(),
                             {'hole_number': 1, 'count': 5}, format='json')
        self.assertEqual(r.status_code, 400)

    def test_a_settled_hole_is_refused(self):
        self.par_hole(1, 0, 0, 0, 0)
        self.client.post(self.count_url(),
                         {'hole_number': 1, 'count': 2}, format='json')
        self.par_hole(2, 0, 0, 0, 0)
        r = self.client.post(self.count_url(),
                             {'hole_number': 1, 'count': 3}, format='json')
        self.assertEqual(r.status_code, 409)
        self.assertIn('settled', r.data['detail'])


class BoardTests(_Base):
    def setUp(self):
        super().setUp()
        self.configure()

    def test_the_leaderboard_gains_a_forty_balls_block(self):
        self.par_hole(1, 0, 0, 0, 0)
        r = self.client.get(f'/api/rounds/{self.round.id}/leaderboard/')
        self.assertEqual(r.status_code, 200)
        self.assertIn('forty_balls', r.data['games'])
        self.assertEqual(r.data['games']['forty_balls']['label'], '40 Balls')

    def test_groups_rank_on_the_total_and_the_pool_is_the_field(self):
        self.par_hole(1, -1, -1, 0, 0)
        self.client.post(self.count_url(),
                         {'hole_number': 1, 'count': 2}, format='json')
        self.par_hole(1, 0, 0, 0, 0, fs=self.fs2)
        self.client.post(self.count_url(self.fs2),
                         {'hole_number': 1, 'count': 2}, format='json')

        r = self.client.get(f'/api/rounds/{self.round.id}/forty-balls/')
        rows = r.data['results']
        self.assertEqual(rows[0]['group_number'], 1)
        self.assertEqual(rows[0]['total'], -2)
        self.assertEqual(rows[0]['rank'], 1)
        self.assertEqual(r.data['pool'], 80.0)      # $10 × 8 golfers

    def test_a_DQd_group_is_listed_last_with_no_rank(self):
        # Its scores are real and stay visible; what it has no claim to is a
        # place, because its total came from a budget that cannot come out.
        for h in range(1, 11):
            self.par_hole(h, 0, 0, 0, 0)
            self.client.post(self.count_url(),
                             {'hole_number': h, 'count': 2}, format='json')
        for m in list(self.fs.memberships.order_by('id'))[2:]:
            m.withdrew_after_hole = 10
            m.save(update_fields=['withdrew_after_hole'])

        rows = self.client.get(
            f'/api/rounds/{self.round.id}/forty-balls/').data['results']
        mine = next(r for r in rows if r['group_number'] == 1)
        self.assertTrue(mine['dq'])
        self.assertIsNone(mine['rank'])
        self.assertEqual(mine['payout'], 0.0)
        self.assertIs(rows[-1]['group_number'], 1)   # sorted to the bottom


class SettlementTests(_Base):
    def setUp(self):
        super().setUp()
        self.configure()

    def test_it_settles_as_a_group_prize_like_irish_rumble(self):
        self.par_hole(1, -1, -1, 0, 0)
        self.client.post(self.count_url(),
                         {'hole_number': 1, 'count': 2}, format='json')
        self.par_hole(1, 0, 0, 0, 0, fs=self.fs2)
        self.client.post(self.count_url(self.fs2),
                         {'hole_number': 1, 'count': 2}, format='json')

        from services.tournament_settlement import tournament_settlement
        s = tournament_settlement(self.tourn)
        pot = next(g for g in s['games'] if g['key'] == 'forty_balls')
        self.assertEqual(pot['label'], '40 Balls · R1')
        self.assertEqual(pot['entries_in'], 80.0)    # $10 × 8
        self.assertEqual(pot['prizes_out'], 150.0)

        # The winning group's four golfers split it, and the line names the ways.
        winner = next(g for g in s['golfers']
                      if g['player_id'] == self.pids[0])
        prize = next(p for p in winner['prizes'] if p['game'] == '40 Balls · R1')
        self.assertEqual(prize['amount'], 37.5)      # 150 / 4
        self.assertIn('4 ways', prize['detail'])
