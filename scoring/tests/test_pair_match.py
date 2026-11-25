"""
scoring/tests/test_pair_match.py
--------------------------------
Two-man Scramble and Alternate Shot as a 2v2 MATCH in one group. They ride
the Fourball tables (`ball_format`): ONE score a side a hole, the lower net
pair score wins the hole, strokes are the DIFFERENCE between the pairs'
allowances (the same table the Team Play pairs use).

Teams are Team 1 = (A, B), Team 2 = (C, D).
"""
from decimal import Decimal

from django.test import TestCase

from services.fourball import (
    setup_fourball, calculate_fourball, fourball_summary, fourball_hole_card,
    pair_allowances, scorer_on_hole,
)
from ._helpers import make_course, make_tee, make_round, make_foursome, \
    make_player, submit_hole


class PairBase(TestCase):
    fmt = 'scramble'
    hcps = (0, 10, 10, 20)

    def setUp(self):
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course,
                                active_games=['scramble_match'])
        self.p = [make_player(n, h, short_name=n)
                  for n, h in zip('ABCD', self.hcps)]
        self.fs = make_foursome(
            self.round, [(pl, h) for pl, h in zip(self.p, self.hcps)],
            tee=self.tee)

    def setup_game(self, **kw):
        return setup_fourball(
            self.fs, [self.p[0].id, self.p[1].id],
            [self.p[2].id, self.p[3].id], handicap_mode='net',
            ball_format=self.fmt, **kw)

    def score(self, hole, who_t1, g1, who_t2, g2):
        """Post ONE score a side (on whoever holds the number)."""
        submit_hole(self.fs, hole, [(self.p[who_t1], g1),
                                    (self.p[who_t2], g2)])
        calculate_fourball(self.fs)

    def hole(self, n):
        return next(h for h in fourball_summary(self.fs)['holes']
                    if h['hole'] == n)


class ScrambleMatchTests(PairBase):
    def test_allowance_is_the_pairs_table_and_the_higher_pair_gets_the_difference(self):
        game = self.setup_game()
        # 35% low + 15% high: A0,B10 -> 1.5 -> 2 ; C10,D20 -> 6.5 -> 7
        self.assertEqual(pair_allowances(self.fs, game), {1: 2, 2: 7})

    def test_a_stroke_hole_turns_a_tie_into_a_win(self):
        self.setup_game()
        # Difference is 5 — hole 2 is SI 3, so team 2's score nets one less.
        self.score(1, 0, 4, 2, 4)
        self.score(2, 0, 5, 2, 5)
        h = self.hole(2)
        self.assertEqual((h['t1_net'], h['t2_net'], h['winner']), (5, 4, 'T2'))

    def test_a_non_stroke_hole_stays_a_tie(self):
        self.setup_game()
        self.score(1, 0, 4, 2, 4)            # hole 1 is SI 7, past the 5
        self.assertEqual(self.hole(1)['winner'], 'Halved')

    def test_only_the_first_golfer_holds_the_score_and_the_hole_is_complete(self):
        self.setup_game()
        self.score(1, 0, 4, 2, 5)
        card = fourball_hole_card(self.fs, 1)
        self.assertEqual(card['ball_format'], 'scramble')
        self.assertTrue(card['hole_complete'])
        scorers = [r['player_id'] for r in card['players'] if r['scorer']]
        self.assertEqual(scorers, [self.p[0].id, self.p[2].id])

    def test_gross_mode_gives_no_strokes(self):
        setup_fourball(self.fs, [self.p[0].id, self.p[1].id],
                       [self.p[2].id, self.p[3].id], handicap_mode='gross',
                       ball_format='scramble')
        self.score(1, 0, 4, 2, 4)
        self.score(2, 0, 5, 2, 5)
        self.assertEqual(self.hole(2)['winner'], 'Halved')

    def test_a_flat_allowance_replaces_the_table(self):
        game = self.setup_game(allowance_pct=50)
        # 50% of each golfer: A0,B10 -> 5 ; C10,D20 -> 15
        self.assertEqual(pair_allowances(self.fs, game), {1: 5, 2: 15})

    def test_strokes_off_is_not_offered_and_becomes_net(self):
        game = setup_fourball(self.fs, [self.p[0].id, self.p[1].id],
                              [self.p[2].id, self.p[3].id],
                              handicap_mode='strokes_off',
                              ball_format='scramble')
        self.assertEqual(game.handicap_mode, 'net')

    def test_it_closes_out_like_any_match(self):
        self.setup_game(allowance_pct=1)
        for h in range(1, 12):
            self.score(h, 0, 3, 2, 5)        # team 1 wins every hole
        s = fourball_summary(self.fs)
        self.assertEqual(s['status'], 'complete')
        self.assertEqual(s['finished_on_hole'], 10)
        self.assertEqual(s['result_label'], 'Team 1 wins 10&8')

    def test_settlement_is_the_fourball_match_bet(self):
        self.setup_game(bet_amount=Decimal('5.00'), allowance_pct=1)
        for h in range(1, 12):
            self.score(h, 0, 3, 2, 5)
        money = {e['name']: e['amount']
                 for e in fourball_summary(self.fs)['money']['by_player']}
        self.assertEqual(money['A'], 5.0)
        self.assertEqual(money['C'], -5.0)

    def test_an_ordinary_fourball_is_unchanged(self):
        game = setup_fourball(self.fs, [self.p[0].id, self.p[1].id],
                              [self.p[2].id, self.p[3].id],
                              handicap_mode='gross')
        self.assertEqual(game.ball_format, 'best_ball')
        self.assertEqual(fourball_summary(self.fs)['game_slug'], 'fourball')


class AlternateShotMatchTests(PairBase):
    fmt = 'alternate_shot'

    def test_the_table_is_fifty_percent_of_combined(self):
        game = self.setup_game()
        self.assertEqual(pair_allowances(self.fs, game), {1: 5, 2: 15})

    def test_the_score_sits_on_whoever_tees_and_alternates(self):
        game = self.setup_game(team1_first_tee=self.p[1].id)
        self.assertEqual(scorer_on_hole(self.fs, game, 1, 1), self.p[1].id)
        self.assertEqual(scorer_on_hole(self.fs, game, 1, 2), self.p[0].id)
        self.assertEqual(scorer_on_hole(self.fs, game, 1, 3), self.p[1].id)
        # No first tee named: the first golfer on the card.
        self.assertEqual(scorer_on_hole(self.fs, game, 2, 1), self.p[2].id)

    def test_a_score_on_either_partner_counts_on_its_hole(self):
        self.setup_game(team1_first_tee=self.p[1].id)
        # Hole 1: B tees for team 1, C for team 2. Hole 2: A and D.
        self.score(1, 1, 4, 2, 4)
        self.score(2, 0, 4, 3, 4)
        self.assertEqual(len(fourball_summary(self.fs)['holes']), 2)

    def test_strokes_follow_the_teeing_golfer_and_the_difference(self):
        self.setup_game()
        # Difference is 10: SI <= 10 gets one — hole 1 (SI 7) does.
        self.score(1, 0, 5, 2, 5)
        h = self.hole(1)
        self.assertEqual((h['t1_net'], h['t2_net'], h['winner']), (5, 4, 'T2'))

    def test_the_first_tee_is_stored_and_reported(self):
        self.setup_game(team1_first_tee=self.p[1].id)
        s = fourball_summary(self.fs)
        self.assertEqual(s['first_tee']['1'], self.p[1].id)
        self.assertEqual(s['game_slug'], 'alternate_shot_match')
        self.assertEqual(s['scorers_by_hole']['1'][0], self.p[1].id)

    def test_a_first_tee_who_is_not_on_the_side_is_ignored(self):
        game = self.setup_game(team1_first_tee=self.p[3].id)
        self.assertIsNone(game.team1_first_tee_id)


class ScrambleDriveQuotaTests(PairBase):
    """The two-man scramble's per-nine / per-eighteen drive quota — the same
    window arithmetic the Team Play pairs use."""

    def quota(self, rule='per_nine', each=1):
        return self.setup_game(drive_rule=rule, drives_required=each)

    def test_it_is_off_unless_asked_for(self):
        self.setup_game()
        self.assertEqual(fourball_summary(self.fs)['drives'], {})
        self.assertEqual(fourball_hole_card(self.fs, 1)['drive'], {})

    def test_only_a_scramble_takes_a_quota(self):
        from services.fourball import setup_fourball
        g = setup_fourball(self.fs, [self.p[0].id, self.p[1].id],
                           [self.p[2].id, self.p[3].id],
                           ball_format='alternate_shot', drive_rule='per_nine')
        self.assertEqual(g.drive_rule, 'none')

    def test_a_pick_is_recorded_and_the_tracker_counts_it(self):
        from services.fourball import set_drive, drive_state
        game = self.quota()
        set_drive(self.fs, 1, 1, self.p[0].id)
        st = drive_state(self.fs, game, thru=1)['teams']['1']
        front = st['windows'][0]
        self.assertEqual(front['required'], 2)           # 2 golfers x 1
        self.assertEqual(front['owed'], 1)
        self.assertEqual(st['picks'], {'1': self.p[0].id})

    def test_per_nine_is_two_windows_and_the_front_does_not_carry(self):
        from services.fourball import set_drive, drive_state
        game = self.quota()
        set_drive(self.fs, 1, 1, self.p[0].id)
        set_drive(self.fs, 1, 2, self.p[0].id)
        wins = drive_state(self.fs, game, thru=12)['teams']['1']['windows']
        self.assertEqual(len(wins), 2)
        self.assertEqual(wins[1]['owed'], 2)             # back nine untouched

    def test_the_card_names_the_pick_and_warns_when_every_hole_is_owed(self):
        from services.fourball import set_drive
        self.quota(rule='per_eighteen', each=9)          # 18 of 18: no slack
        card = fourball_hole_card(self.fs, 1)
        side = card['drive']['sides'][0]
        self.assertTrue(side['warn'])
        set_drive(self.fs, 1, 1, self.p[1].id)
        side = fourball_hole_card(self.fs, 1)['drive']['sides'][0]
        self.assertEqual(side['picked'], self.p[1].id)

    def test_a_golfer_from_the_other_side_is_refused(self):
        from services.fourball import set_drive, DriveRefused
        self.quota()
        with self.assertRaises(DriveRefused):
            set_drive(self.fs, 1, 1, self.p[2].id)

    def test_a_pick_can_be_cleared(self):
        from services.fourball import set_drive, drive_picks
        self.quota()
        set_drive(self.fs, 1, 3, self.p[0].id)
        set_drive(self.fs, 1, 3, None)
        self.assertEqual(drive_picks(self.fs, 1), {})

    def test_a_pick_never_blocks_the_hole(self):
        self.quota()
        self.score(1, 0, 4, 2, 4)
        self.assertTrue(fourball_hole_card(self.fs, 1)['hole_complete'])


class PairMatchLockScreenTests(PairBase):
    def _card(self, slug):
        from services.live_activity_match import match_activity_state
        return match_activity_state(self.fs, slug=slug,
                                    player_id=self.p[0].id, thru=1)

    def test_the_scramble_draws_the_match_card_under_its_own_name(self):
        self.setup_game()
        self.score(1, 0, 3, 2, 5)
        s = self._card('scramble_match')
        self.assertEqual(s['kind'], 'match')
        self.assertEqual(s['header']['game'], 'TWO-MAN SCRAMBLE')
        self.assertEqual(s['number']['text'], '1 UP')

    def test_alternate_shot_has_its_own_label(self):
        self.fmt = 'alternate_shot'
        self.setup_game()
        self.score(1, 0, 3, 2, 5)
        s = self._card('alternate_shot_match')
        self.assertEqual(s['header']['game'], 'ALTERNATE SHOT')

    def test_the_registry_knows_both_slugs(self):
        from services.live_activity_registry import BUILDERS, CARD_KIND
        for slug in ('scramble_match', 'alternate_shot_match'):
            self.assertIn(slug, BUILDERS)
            self.assertEqual(CARD_KIND[slug], 'match')


class ShortResultTests(TestCase):
    def test_the_margin_alone(self):
        from services.fourball import short_result
        self.assertEqual(short_result('Team 2 wins 5&4'), '5&4')
        self.assertEqual(short_result('Team 1 wins 1 up'), '1 up')
        self.assertEqual(short_result('All Square'), 'All Square')
        self.assertEqual(short_result(None), '')

    def test_the_watch_card_does_not_say_wins_twice(self):
        from api.watch_views import _fourball_watch_card
        card = _fourball_watch_card({
            'team1': {'players': ['A', 'B']}, 'team2': {'players': ['C', 'D']},
            'overall': {'holes_up': -5, 'leader': 'team2'},
            'status': 'complete', 'result': 'team2',
            'result_label': 'Team 2 wins 5&4', 'holes': [],
        })
        self.assertEqual(card['status'], 'C & D wins 5&4')
