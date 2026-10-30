"""
scoring/tests/test_annandale_friday.py
--------------------------------------
Engine tests for services/annandale_friday.py — one group of 5 or 6, teams
that make three better-ball Nassaus.

What is this game's own and gets pinned here:

* the SHAPE — three pairs, or a pair and a three — and the three matches
  each shape makes;
* the FIELD-WIDE handicap: one golfer, the same strokes in every match
  (where Triple Nassau, the nearest neighbour, gives different strokes per
  opponent);
* per-golfer settlement across two or three matches, zero-sum;
* the edit window on teams, and a settings save that keeps the presses;
* the manual press rule — 1 down or level — and that a press lands on the
  match it was called in.

The Nassau engine itself (holes up, close-out, presses at 2/4/6/8) is
test_nassau.py's; this file trusts it and checks the wiring.
"""
from django.test import TestCase

from games.models import NassauGame, NassauPress
from services.annandale_friday import (
    AF_CHILD_SLUGS, AnnandaleLocked, AnnandalePressRefused,
    AnnandaleShapeError, annandale_friday_summary, calculate_annandale_friday,
    matches_for, press_annandale, setup_annandale_friday, shape_problem,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


# ── The shape, as pure units ────────────────────────────────────────────────

class ShapeTests(TestCase):
    def test_six_plays_as_three_pairs(self):
        assert shape_problem([[1, 2], [3, 4], [5, 6]]) is None

    def test_six_in_any_other_split_says_so(self):
        assert shape_problem([[1, 2], [3, 4, 5, 6]]) == \
            'Six golfers play as three pairs.'
        assert shape_problem([[1, 2, 3], [4, 5, 6]]) == \
            'Six golfers play as three pairs.'

    def test_five_plays_as_a_pair_and_a_three(self):
        assert shape_problem([[1, 2], [3, 4, 5]]) is None
        assert shape_problem([[3, 4, 5], [1, 2]]) is None

    def test_five_in_any_other_split_says_so(self):
        assert shape_problem([[1, 2], [3, 4], [5]]) == \
            'Five golfers play as a pair and a three.'

    def test_a_golfer_on_two_teams(self):
        assert shape_problem([[1, 2], [2, 3], [4, 5]]) == 'A golfer is on two teams.'

    def test_a_golfer_left_off_every_team(self):
        assert shape_problem([[1, 2], [3, 4, 5]], roster_ids=[1, 2, 3, 4, 5, 6]) \
            == '1 golfer is not on a team.'

    def test_four_is_not_offered(self):
        msg = shape_problem([[1, 2], [3, 4]], roster_ids=[1, 2, 3, 4])
        assert msg.startswith('Annandale Friday is for a group of 5 or 6'), msg

    def test_six_makes_every_pair_against_the_other_two(self):
        a, b, c = [1, 2], [3, 4], [5, 6]
        assert matches_for([a, b, c]) == [(a, b), (a, c), (b, c)]

    def test_five_puts_the_pair_against_each_pair_of_the_three(self):
        assert matches_for([[1, 2], [3, 4, 5]]) == [
            ([1, 2], [3, 4]), ([1, 2], [3, 5]), ([1, 2], [4, 5])]

    def test_five_finds_the_pair_whichever_order_the_teams_are_in(self):
        assert matches_for([[3, 4, 5], [1, 2]]) == matches_for([[1, 2], [3, 4, 5]])


# ── The engine ───────────────────────────────────────────────────────────────

class _Base(TestCase):
    ROSTER = [('Bill', 8), ('Tom', 14), ('Dave', 4),
              ('Ray', 18), ('Jim', 11), ('Sam', 22)]

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 10
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(self.round, self.ROSTER, tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def ids(self, *names):
        return [self.pid[n] for n in names]

    def gets(self, s, match, who):
        for t in ('team1', 'team2'):
            for pl in s['matches'][match - 1]['summary']['teams'][t]:
                if pl['player_id'] == who:
                    return pl['phcp_in_play']
        return None

    def score_all(self, hole, gross):
        submit_hole(self.fs, hole, [(self.pid[n], g) for n, g in gross.items()])


class SixTests(_Base):
    def teams(self):
        return [self.ids('Bill', 'Tom'), self.ids('Dave', 'Ray'),
                self.ids('Jim', 'Sam')]

    def test_setup_creates_three_2v2_matches(self):
        setup_annandale_friday(self.fs, self.teams())
        s = annandale_friday_summary(self.fs)
        AB, CD, EF = self.teams()
        assert [(m['side1_ids'], m['side2_ids']) for m in s['matches']] == [
            (AB, CD), (AB, EF), (CD, EF)]
        assert [(m['side1_team'], m['side2_team']) for m in s['matches']] == [
            (0, 1), (0, 2), (1, 2)]
        assert all(p['matches'] == 2 for p in s['players'])
        assert s['group_size'] == 6

    def test_each_match_lists_a_side_in_card_order(self):
        # Card order is the order the teams were given in, Tom before Bill
        # here, whatever order the database returns them in.
        teams = [self.ids('Tom', 'Bill'), self.ids('Ray', 'Dave'),
                 self.ids('Sam', 'Jim')]
        setup_annandale_friday(self.fs, teams)
        for m in annandale_friday_summary(self.fs)['matches']:
            got1 = [p['player_id'] for p in m['summary']['teams']['team1']]
            got2 = [p['player_id'] for p in m['summary']['teams']['team2']]
            assert (got1, got2) == (m['side1_ids'], m['side2_ids'])

    def test_the_defaults_are_the_packets(self):
        setup_annandale_friday(self.fs, self.teams())
        s = annandale_friday_summary(self.fs)
        assert s['handicap_mode'] == 'strokes_off'
        assert s['second_ball_tiebreak'] is False
        assert s['claremont'] is False
        assert s['auto_press'] is True
        assert s['manual_press'] is False
        assert s['loss_cap'] is None

    def test_saving_settings_clears_a_cap_from_before_it_was_removed(self):
        setup_annandale_friday(self.fs, self.teams())
        NassauGame.objects.filter(game_type__in=AF_CHILD_SLUGS).update(loss_cap=20)
        setup_annandale_friday(self.fs, self.teams())
        assert annandale_friday_summary(self.fs)['loss_cap'] is None

    def test_a_golfer_takes_the_same_strokes_into_every_match(self):
        # Off the low man of the WHOLE group: Dave is 4, so Sam (22) gets 18
        # in both his matches — not 22−8 against Bill & Tom's low and 22−4
        # against Dave & Ray's, which is what a pairwise allocation would do.
        setup_annandale_friday(self.fs, self.teams())
        s = annandale_friday_summary(self.fs)
        sam, dave = self.pid['Sam'], self.pid['Dave']
        assert self.gets(s, 2, sam) == 18
        assert self.gets(s, 3, sam) == 18
        assert self.gets(s, 1, dave) == 0
        assert self.gets(s, 3, dave) == 0
        # And the summary states it once per golfer, for score entry's keypad.
        by_pid = {p['player_id']: p['strokes_in_play'] for p in s['players']}
        assert by_pid[sam] == 18 and by_pid[dave] == 0

    def test_the_second_ball_breaks_a_tied_best_ball(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               second_ball_tiebreak=True)
        # AB v CD on hole 1: best balls 4 v 4, second balls 5 v 6 → AB wins.
        self.score_all(1, {'Bill': 4, 'Tom': 5, 'Dave': 4, 'Ray': 6,
                           'Jim': 7, 'Sam': 7})
        calculate_annandale_friday(self.fs)
        s = annandale_friday_summary(self.fs)
        h1 = s['matches'][0]['summary']['holes'][0]
        assert h1['winner'] == 'team1', h1

    def test_with_the_tiebreak_off_the_hole_is_halved(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               second_ball_tiebreak=False)
        self.score_all(1, {'Bill': 4, 'Tom': 5, 'Dave': 4, 'Ray': 6,
                           'Jim': 7, 'Sam': 7})
        calculate_annandale_friday(self.fs)
        h1 = annandale_friday_summary(self.fs)['matches'][0]['summary']['holes'][0]
        assert h1['winner'] == 'halved', h1

    def test_claremont_wins_when_both_are_asked_for(self):
        setup_annandale_friday(self.fs, self.teams(), claremont=True,
                               second_ball_tiebreak=True)
        s = annandale_friday_summary(self.fs)
        assert s['claremont'] is True
        assert s['second_ball_tiebreak'] is False
        assert all(m.variant == 'claremont'
                   for m in NassauGame.objects.filter(foursome=self.fs))

    def test_settlement_nets_each_golfers_two_matches_and_sums_to_zero(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False)
        # Bill & Tom win every hole; Dave & Ray beat Jim & Sam every hole.
        for h in range(1, 19):
            self.score_all(h, {'Bill': 3, 'Tom': 5, 'Dave': 4, 'Ray': 6,
                               'Jim': 5, 'Sam': 7})
        calculate_annandale_friday(self.fs)
        s = annandale_friday_summary(self.fs)
        net = {p['player_id']: p['net'] for p in s['players']}
        # Three bets of $10 per match per golfer.
        assert net[self.pid['Bill']] == 60
        assert net[self.pid['Dave']] == 0       # lost one, won one
        assert net[self.pid['Jim']] == -60
        assert abs(sum(net.values())) < 0.005
        assert s['status'] == 'complete'


class MoneyTests(_Base):
    def teams(self):
        return [self.ids('Bill', 'Tom'), self.ids('Dave', 'Ray'),
                self.ids('Jim', 'Sam')]

    def _sweep(self, holes):
        for h in range(1, holes + 1):
            self.score_all(h, {'Bill': 3, 'Tom': 5, 'Dave': 4, 'Ray': 6,
                               'Jim': 5, 'Sam': 7})
        calculate_annandale_friday(self.fs)

    def test_the_loss_cap_holds_in_settlement(self):
        # Uncapped, Jim loses $30 in each of his two matches. Capped at $20 a
        # side per Nassau, he loses $20 in each — settling off the uncapped
        # total would have charged him $60. Setup no longer offers a cap; a
        # round set up before that keeps its own, so the row is written here.
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False)
        NassauGame.objects.filter(game_type__in=AF_CHILD_SLUGS).update(loss_cap=20)
        self._sweep(18)
        net = {p['player_id']: p['net']
               for p in annandale_friday_summary(self.fs)['players']}
        assert net[self.pid['Jim']] == -40
        assert net[self.pid['Bill']] == 40
        assert abs(sum(net.values())) < 0.005

    def test_each_total_is_the_sum_of_its_matches(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross')
        self._sweep(8)
        for p in annandale_friday_summary(self.fs)['players']:
            assert len(p['by_match']) == 2
            assert abs(sum(m['live_net'] for m in p['by_match'])
                       - p['live_net']) < 0.005, p
            assert abs(sum(m['net'] for m in p['by_match']) - p['net']) < 0.005

    def test_mid_round_the_live_figure_moves_and_the_settled_one_waits(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False)
        self._sweep(1)
        p = {x['player_id']: x
             for x in annandale_friday_summary(self.fs)['players']}
        bill = p[self.pid['Bill']]
        assert bill['net'] == 0          # nothing has settled
        assert bill['live_net'] > 0      # but he is up in both matches
        assert abs(sum(x['live_net'] for x in p.values())) < 0.005


class FiveTests(_Base):
    ROSTER = _Base.ROSTER[:5]

    def teams(self):
        return [self.ids('Bill', 'Tom'), self.ids('Dave', 'Ray', 'Jim')]

    def test_the_pair_is_in_all_three_and_the_others_in_two(self):
        setup_annandale_friday(self.fs, self.teams())
        s = annandale_friday_summary(self.fs)
        count = {p['player_id']: p['matches'] for p in s['players']}
        assert count[self.pid['Bill']] == 3
        assert count[self.pid['Tom']] == 3
        assert {count[self.pid[n]] for n in ('Dave', 'Ray', 'Jim')} == {2}
        # Every opponent of the pair is the three — one team, one colour.
        assert {m['side2_team'] for m in s['matches']} == {1}

    def test_settlement_is_zero_sum_with_the_pair_in_three(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False)
        for h in range(1, 19):
            self.score_all(h, {'Bill': 3, 'Tom': 5, 'Dave': 4, 'Ray': 6,
                               'Jim': 5})
        calculate_annandale_friday(self.fs)
        net = {p['player_id']: p['net']
               for p in annandale_friday_summary(self.fs)['players']}
        assert net[self.pid['Bill']] == 90       # three matches, three bets
        assert net[self.pid['Dave']] == -60      # in two of them
        assert abs(sum(net.values())) < 0.005

    def test_a_split_that_is_not_the_shape_is_refused(self):
        with self.assertRaisesMessage(AnnandaleShapeError,
                                      'Five golfers play as a pair and a three.'):
            setup_annandale_friday(self.fs, [self.ids('Bill', 'Tom'),
                                             self.ids('Dave', 'Ray'),
                                             self.ids('Jim')])
        assert not NassauGame.objects.filter(foursome=self.fs).exists()


class EditWindowTests(_Base):
    def teams(self):
        return [self.ids('Bill', 'Tom'), self.ids('Dave', 'Ray'),
                self.ids('Jim', 'Sam')]

    def other_teams(self):
        return [self.ids('Bill', 'Dave'), self.ids('Tom', 'Ray'),
                self.ids('Jim', 'Sam')]

    def _play(self, holes):
        for h in range(1, holes + 1):
            self.score_all(h, {n: 4 for n, _ in self.ROSTER})

    def test_teams_can_be_redrawn_inside_the_window(self):
        setup_annandale_friday(self.fs, self.teams())
        self._play(3)
        setup_annandale_friday(self.fs, self.other_teams())
        s = annandale_friday_summary(self.fs)
        assert s['matches'][0]['side1_ids'] == self.ids('Bill', 'Dave')
        # And the played holes are rescored under the new teams.
        assert len(s['matches'][0]['summary']['holes']) == 3

    def test_teams_lock_on_the_fourth_hole(self):
        setup_annandale_friday(self.fs, self.teams())
        self._play(4)
        with self.assertRaises(AnnandaleLocked) as cm:
            setup_annandale_friday(self.fs, self.other_teams())
        assert 'locked after the first 3 holes' in str(cm.exception)

    def test_reordering_inside_a_team_is_not_a_redraw(self):
        setup_annandale_friday(self.fs, self.teams())
        self._play(6)
        AB, CD, EF = self.teams()
        setup_annandale_friday(self.fs, [AB[::-1], CD, EF])     # no raise

    def test_a_settings_save_keeps_the_manual_presses(self):
        setup_annandale_friday(self.fs, self.teams(), manual_press=True,
                               handicap_mode='gross')
        self.score_all(1, {'Bill': 5, 'Tom': 5, 'Dave': 4, 'Ray': 6,
                           'Jim': 5, 'Sam': 5})
        calculate_annandale_friday(self.fs)
        press_annandale(self.fs, 1, 2)
        self._play(6)
        setup_annandale_friday(self.fs, self.teams(), manual_press=True,
                               handicap_mode='gross', net_percent=90,
                               press_unit=5)
        child = NassauGame.objects.get(foursome=self.fs, game_type='af_1')
        assert child.net_percent == 90
        assert float(child.press_unit) == 5
        assert NassauPress.objects.filter(game=child, press_type='manual',
                                          start_hole=2).exists()


class ManualPressTests(_Base):
    def teams(self):
        return [self.ids('Bill', 'Tom'), self.ids('Dave', 'Ray'),
                self.ids('Jim', 'Sam')]

    def setUp(self):
        super().setUp()
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               manual_press=True, auto_press=False)

    def _hole(self, h, ab, cd):
        # Only match 1 (AB v CD) is shaped by these numbers; EF plays level.
        self.score_all(h, {'Bill': ab, 'Tom': ab + 1, 'Dave': cd, 'Ray': cd + 1,
                           'Jim': 5, 'Sam': 5})
        calculate_annandale_friday(self.fs)

    def test_a_press_when_level(self):
        self._hole(1, 4, 4)
        # Level is allowed here on purpose — a plain Nassau's can_press is not.
        assert annandale_friday_summary(self.fs)['matches'][0]['can_press']
        press_annandale(self.fs, 1, 2)
        assert NassauPress.objects.filter(
            game__game_type='af_1', press_type='manual', start_hole=2).exists()

    def test_a_press_when_one_down(self):
        self._hole(1, 5, 4)
        assert annandale_friday_summary(self.fs)['matches'][0]['can_press']
        press_annandale(self.fs, 1, 2)

    def test_no_press_at_two_down(self):
        self._hole(1, 5, 4)
        self._hole(2, 5, 4)
        assert not annandale_friday_summary(self.fs)['matches'][0]['can_press']
        with self.assertRaises(AnnandalePressRefused):
            press_annandale(self.fs, 1, 3)

    def test_the_loss_cap_is_checked_against_the_match_being_pressed(self):
        # The regression: add_manual_press read the cap off the foursome's
        # PRIMARY Nassau. A child match is never the primary, so the lookup
        # found nothing and the cap was silently skipped — a side that had
        # already lost its cap could press for free. Same bug in Triple Nassau.
        from services.nassau import add_manual_press
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               manual_press=True, auto_press=False)
        NassauGame.objects.filter(game_type__in=AF_CHILD_SLUGS).update(loss_cap=10)
        for h in range(1, 10):
            self._hole(h, 5, 4)          # CD take the front: AB lose $10
        self._hole(10, 5, 4)             # and go 1 down on the back
        with self.assertRaisesMessage(ValueError, 'loss cap'):
            add_manual_press(self.fs, 11, game_type='af_1')

    def test_a_press_lands_on_the_match_it_was_called_in(self):
        self._hole(1, 4, 4)
        press_annandale(self.fs, 2, 2)
        self._hole(2, 4, 4)
        s = annandale_friday_summary(self.fs)
        presses = s['matches'][1]['summary']['presses']
        assert any(p['start_hole'] == 2 for p in presses), presses
        assert not NassauPress.objects.filter(game__game_type='af_1').exists()

    def test_no_press_when_the_option_is_off(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               manual_press=False)
        self._hole(1, 4, 4)
        assert not annandale_friday_summary(self.fs)['matches'][0]['can_press']
        with self.assertRaisesMessage(AnnandalePressRefused, 'Manual presses are off'):
            press_annandale(self.fs, 1, 2)


class AutoPressTests(_Base):
    def test_a_side_two_down_on_the_nine_presses_from_the_next_hole(self):
        teams = [self.ids('Bill', 'Tom'), self.ids('Dave', 'Ray'),
                 self.ids('Jim', 'Sam')]
        setup_annandale_friday(self.fs, teams, handicap_mode='gross')
        for h in (1, 2):
            self.score_all(h, {'Bill': 5, 'Tom': 6, 'Dave': 4, 'Ray': 6,
                               'Jim': 5, 'Sam': 5})
        calculate_annandale_friday(self.fs)
        presses = annandale_friday_summary(self.fs)['matches'][0]['summary']['presses']
        assert [(p['press_type'], p['start_hole']) for p in presses] == [('auto', 3)], presses

    def test_child_slugs_are_three(self):
        assert AF_CHILD_SLUGS == ('af_1', 'af_2', 'af_3')
