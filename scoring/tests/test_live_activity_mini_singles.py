"""
The Mini Singles lock screen
(`handoff-lock-screens-mgskins-minisingles-nassaunine-solo`, section 2),
played through the same script the score-entry tray's tests use.
"""
from services.live_activity_mini_singles import (mini_singles_activity_state,
                                                 mini_singles_final_state)
from services.live_activity_registry import (BUILDERS, UNSHIPPED_KINDS,
                                             card_kind)
from services.three_person_match import (calculate_three_person_match,
                                         setup_three_person_match)
from services.tournament_match_play import calculate_tournament_match_play

from ._helpers import make_foursome, make_round, make_tee, submit_hole
from .test_mini_singles_hole_card import SCRIPT, ORDER, _Base


class _Lock(_Base):
    def state(self, played, who='Paul', script=None):
        self._play(played, script)
        return mini_singles_activity_state(
            self.fs, player_id=self.pid[who], thru=played)


class RegistrationTests(_Lock):
    def test_it_draws_the_match_card(self):
        self.assertIn('match_play', BUILDERS)
        self.assertEqual(card_kind('match_play'), 'match')
        self.assertNotIn('match', UNSHIPPED_KINDS)


class TheSemisTests(_Lock):
    def test_your_match_and_one_line_for_the_other(self):
        c = self.state(4)
        self.assertEqual(c['kind'], 'match')
        self.assertEqual(c['header']['game'], 'MINI SINGLES · SEMI 1')
        # No yardage, on purpose.
        self.assertEqual(c['header']['segment'], 'HOLE 5 · PAR 4')
        self.assertEqual(c['number'], {'text': '2 UP', 'colour': 'blue'})
        self.assertEqual(c['state'], {'word': '5 TO PLAY', 'to_play': 'OF 9'})
        self.assertEqual([s['names'] for s in c['sides']],
                         ['Paul Lipkin', 'Lee Naylor'])
        self.assertEqual([s['colour'] for s in c['sides']],
                         ['blue', 'orange'])
        self.assertTrue(c['footer']['context'].startswith('Semi 2 · '))
        self.assertEqual(c['footer']['money'], '')
        self.assertTrue(c['thru'].startswith('THRU 4'))

    def test_the_other_semi_is_the_readers_other_line(self):
        c = self.state(4, who='Dave')
        self.assertEqual(c['header']['game'], 'MINI SINGLES · SEMI 2')
        self.assertTrue(c['footer']['context'].startswith('Semi 1 · '))

    def test_no_stake_while_running(self):
        c = self.state(4)
        self.assertNotIn('$', repr(c))

    def test_a_watcher_gets_the_first_match(self):
        self._play(4)
        c = mini_singles_activity_state(self.fs, player_id=None, thru=4)
        self.assertEqual(c['header']['game'], 'MINI SINGLES · SEMI 1')

    def test_a_semi_that_closes_holds_its_result(self):
        c = self.state(8)
        self.assertEqual(c['number'], {'text': '2 & 1', 'colour': 'blue'})
        self.assertEqual(c['state'], {'word': 'THROUGH',
                                      'to_play': 'TO THE FINALS'})
        self.assertEqual(c['sides'][0]['names'],
                         'Paul Lipkin beat Lee Naylor')

    def test_the_semi_loser_goes_to_third(self):
        c = self.state(8, who='Lee')
        self.assertEqual(c['state'], {'word': '3RD PLACE',
                                      'to_play': 'FROM THE 10TH'})


class LevelAfterNineTests(_Lock):
    def test_the_semi_that_plays_on(self):
        c = self.state(9, who='Dave')
        self.assertEqual(c['number'], {'text': 'ALL SQ',
                                       'colour': 'neutral'})
        self.assertEqual(c['state'], {'word': 'PLAYING ON',
                                      'to_play': 'NEXT HOLE WON'})
        self.assertEqual(c['footer']['context'], 'Winner plays Lipkin')

    def test_the_waiting_finalist_is_scored_against_both(self):
        c = self.state(10, who='Paul')
        self.assertEqual(c['header']['game'], 'MINI SINGLES · FINALS')
        self.assertEqual(c['number']['text'], '1 UP')
        self.assertEqual(c['state']['word'], 'v TBD')
        self.assertEqual(c['state']['to_play'], 'SEMI 2 PLAYING ON')
        self.assertEqual(c['sides'][1]['names'], 'v Moran or Reid')
        self.assertEqual(c['footer']['context'],
                         'Scored from the 10th against both')


class TheBackNineTests(_Lock):
    def test_the_finals_with_third_in_the_footer(self):
        c = self.state(12)
        self.assertEqual(c['header']['game'], 'MINI SINGLES · FINALS')
        self.assertEqual(c['number'], {'text': '2 UP', 'colour': 'blue'})
        self.assertEqual(c['state'], {'word': '6 TO PLAY', 'to_play': 'OF 9'})
        self.assertTrue(c['footer']['context'].startswith('3rd · '))

    def test_the_third_place_match_has_the_finals_in_its_footer(self):
        c = self.state(12, who='Lee')
        self.assertEqual(c['header']['game'], 'MINI SINGLES · 3RD PLACE')
        self.assertTrue(c['footer']['context'].startswith('Finals · '))

    def test_a_finals_that_closes_holds(self):
        c = self.state(16)
        self.assertEqual(c['number']['text'], '3 & 2')
        self.assertEqual(c['state'], {'word': 'CLOSED',
                                      'to_play': 'ON THE 16TH'})
        self.assertEqual(c['sides'][0]['names'], 'Paul Lipkin beat Sam Reid')

    def test_dormie(self):
        # Hole 9 of the nine: Lee leads 3rd place by one with one to play.
        c = self.state(17, who='Lee')
        self.assertIn(c['state']['word'], ('DORMIE', '1 TO PLAY'))


class FinalTests(_Lock):
    def test_the_collection_is_net_of_the_entry(self):
        self._play(18)
        c = mini_singles_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertEqual(c['header'], {'game': 'MINI SINGLES',
                                       'segment': 'GROUP COMPLETE'})
        self.assertEqual(c['state']['to_play'], 'GROSS, 18 HOLES')
        self.assertEqual(c['footer']['context'], 'Dismisses in 5 min')
        self.assertTrue(c['closed'])
        self.assertTrue(c['number']['text'].startswith(('+$', '−$')),
                        c['number'])
        self.assertIn('1st', c['sides'][0]['names'])


class ThreeGolfersTests(_Lock):
    """Points over the front, then a Finals."""

    def setUp(self):
        from django.test import TestCase  # noqa: F401
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross',
                                active_games=['match_play'])
        self.fs = make_foursome(
            self.round, [('Paul Lipkin', 0), ('Dave Moran', 0),
                         ('Sam Reid', 0)], tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_three_person_match(
            self.fs, handicap_mode='gross', entry_fee=10,
            payout_config={'1st': 20, '2nd': 10, '3rd': 0})

    def play(self, upto, scores):
        for h in range(1, upto + 1):
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [(self.pid[n], par + scores[n][h - 1])
                                     for n in ('Paul', 'Dave', 'Sam')])
        calculate_three_person_match(self.fs)

    def card(self, who, thru):
        return mini_singles_activity_state(
            self.fs, player_id=self.pid[who], thru=thru)

    def test_the_cut_is_the_number(self):
        # Dave wins every hole, Paul second, Sam last.
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 18, 'Sam': [1] * 18}
        self.play(5, sc)
        c = self.card('Paul', 5)
        self.assertEqual(c['header']['game'], 'MINI SINGLES · POINTS')
        self.assertEqual(c['number'], {'text': '2ND', 'colour': 'mint'})
        # 3 pts a hole over Sam's 1: +10 after five.
        self.assertEqual(c['state'], {'word': '+10',
                                      'to_play': 'OVER 3RD · 4 TO PLAY'})
        self.assertEqual(c['sides'][0]['names'],
                         'Moran 25 · Lipkin 15 · Reid 5')
        self.assertEqual(c['footer']['context'], '5-3-1 · top two to the Finals')

    def test_in_third_it_is_the_gap_to_second(self):
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 18, 'Sam': [1] * 18}
        self.play(5, sc)
        c = self.card('Sam', 5)
        self.assertEqual(c['number']['text'], '3RD')
        self.assertEqual(c['state'], {'word': '−10',
                                      'to_play': 'TO 2ND · 4 TO PLAY'})

    def test_no_stake_on_the_running_card(self):
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 18, 'Sam': [1] * 18}
        self.play(3, sc)
        self.assertNotIn('$', repr(self.card('Paul', 3)))

    def test_level_for_second_after_nine_plays_on(self):
        # Paul and Sam tie each hole; Dave wins every hole.
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 18, 'Sam': [0] * 18}
        self.play(9, sc)
        c = self.card('Paul', 9)
        self.assertEqual(c['number']['text'], 'T2')
        self.assertEqual(c['state'], {'word': 'PLAYING ON',
                                      'to_play': 'LEVEL WITH REID'})
        self.assertEqual(c['footer']['context'], 'Next hole won decides 2nd')

    def test_the_finals_for_a_finalist(self):
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 9 + [0, 0, 0, 0, 0, 0, 0, 0, 0],
              'Sam': [1] * 18}
        self.play(12, sc)
        c = self.card('Paul', 12)
        self.assertEqual(c['header']['game'], 'MINI SINGLES · FINALS')
        self.assertEqual(c['state']['to_play'], 'OF 9')

    def test_the_golfer_who_missed_the_cut(self):
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 18, 'Sam': [1] * 18}
        self.play(12, sc)
        c = self.card('Sam', 12)
        self.assertEqual(c['number']['text'], '3RD')
        self.assertEqual(c['state'], {'word': 'OUT',
                                      'to_play': 'AFTER THE 10TH'})
        self.assertTrue(c['sides'][0]['names'].startswith('Finals · '))

    def test_the_final_is_net_of_the_entry(self):
        sc = {'Dave': [-1] * 18, 'Paul': [0] * 18, 'Sam': [1] * 18}
        self.play(18, sc)
        c = mini_singles_final_state(self.fs, player_id=self.pid['Dave'])
        self.assertEqual(c['header']['segment'], 'GROUP COMPLETE')
        self.assertEqual(c['number']['text'], '+$10')
        self.assertIn('1st · won the Finals', c['sides'][0]['names'])
        self.assertIn('$30 pot', c['sides'][0]['names'])
