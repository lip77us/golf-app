"""
scoring/tests/test_three_person_hole_card.py
--------------------------------------------
The three-man Mini Singles score-entry card
(`handoff-mini-singles-three-score-entry`), played through the engine on the
handoff's course and scores: Paul (8), Dave (11), Sam (14).

Also pins the engine rule the packet changed — **points play on while 2nd is
level**, where it used to be a sudden-death card-off.

`REGEN_M3_FIXTURES=1` rewrites the JSON the Dart tests draw.
"""
import json
import os
from decimal import Decimal
from pathlib import Path

from django.test import TestCase

from services.three_person_match import (
    setup_three_person_match, calculate_three_person_match,
    three_person_hole_card, three_person_match_summary,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

PAR = [4, 5, 3, 4, 4, 3, 4, 4, 5, 4, 3, 4, 4, 5, 4, 3, 4, 4]
SI = [7, 11, 13, 1, 5, 17, 9, 3, 15, 12, 18, 2, 8, 4, 10, 16, 6, 14]
G0 = [[4, 6, 3, 3, 5, 3, 4, 3, 6, 4, 3, 5, 5, 5, 4, 3, 5, 4],
      [5, 5, 5, 4, 4, 4, 5, 5, 6, 5, 4, 4, 5, 6, 4, 3, 5, 5],
      [6, 7, 4, 5, 4, 4, 3, 6, 5, 5, 3, 5, 4, 6, 5, 3, 5, 4]]
FIX = Path(__file__).resolve().parents[2] / 'mobile' / 'test' / 'fixtures'


class _Base(TestCase):
    gross = G0

    def setUp(self):
        self.tee = make_tee(holes=[
            {'number': i + 1, 'par': PAR[i], 'stroke_index': SI[i],
             'yards': 400} for i in range(18)])
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 8), ('Dave Moran', 11), ('Sam Reid', 14)],
            tee=self.tee)
        self.ids = [m.player_id for m in self.fs.memberships.all()]
        self.P, self.D, self.S = self.ids
        setup_three_person_match(
            self.fs, handicap_mode='strokes_off', net_percent=100,
            entry_fee=10, payout_config={'1st': 20, '2nd': 10, '3rd': 0})

    def play(self, upto, skip=()):
        for h in range(1, upto + 1):
            submit_hole(self.fs, h, [(pid, self.gross[i][h - 1])
                                     for i, pid in enumerate(self.ids)
                                     if (h, i) not in skip])
        calculate_three_person_match(self.fs)

    def card(self, h):
        return three_person_hole_card(self.fs, h)

    def totals(self, c):
        return {t['first']: t['total'] for t in c['totals']}


class TheWorkedExampleTests(_Base):
    def test_thru_9_is_level_for_second(self):
        self.play(9)
        c = self.card(9)
        self.assertEqual(self.totals(c), {'Paul': '33', 'Dave': '24',
                                          'Sam': '24'})
        self.assertEqual(c['phase'], 'points')
        self.assertFalse(c['play_on'])
        self.assertIn('Dave and Sam are level for 2nd', c['line'])
        self.assertEqual(c['next']['title'], 'Points play on from 10')
        self.assertEqual(c['pill']['text'], 'Points · Paul 33')
        self.assertEqual([r['place'] for r in c['table']], ['1', 'T2', 'T2'])
        self.assertEqual(c['finals_cards'], [])

    def test_hole_10_points_play_on_with_the_finals_beside_it(self):
        self.play(10)
        c = self.card(10)
        self.assertEqual(c['phase'], 'points')
        self.assertTrue(c['play_on'])
        self.assertEqual(self.totals(c), {'Paul': '38', 'Dave': '26',
                                          'Sam': '26'})
        self.assertEqual(c['pill']['text'], 'Points play on')
        self.assertEqual(c['pill']['sub'], 'Dave, Sam level for 2nd')
        self.assertEqual([(f['names'], f['text']) for f in c['finals_cards']],
                         [('Paul v Dave', 'Paul 1 UP'),
                          ('Paul v Sam', 'Paul 1 UP')])
        self.assertEqual([p['pts'] for p in c['players']], ['5', '2', '2'])
        self.assertEqual(three_person_match_summary(self.fs)['status'],
                         'tiebreak')

    def test_hole_11_clears_second_and_reads_the_finals_back(self):
        self.play(11)
        c = self.card(11)
        self.assertEqual(c['phase'], 'points')
        self.assertEqual(self.totals(c), {'Paul': '42', 'Dave': '27',
                                          'Sam': '30'})
        self.assertIn('Paul and Sam play the finals, scored from the 10th. '
                      'Dave takes 3rd on points.', c['line'])
        self.assertEqual(c['finals_cards'], [])
        s = three_person_match_summary(self.fs)
        self.assertEqual(s['status'], 'phase2')
        self.assertEqual(s['phase2']['leader_id'], self.P)
        self.assertEqual(s['phase2']['runner_up_id'], self.S)
        # Read back from the 10th, over the two holes already played.
        self.assertEqual([h['hole'] for h in s['phase2']['holes']], [10, 11])
        self.assertEqual(s['phase2']['margin'], 1)

    def test_hole_14_is_the_finals(self):
        self.play(14)
        c = self.card(14)
        self.assertEqual(c['phase'], 'finals')
        roles = {p['first']: p['role'] for p in c['players']}
        self.assertEqual(roles, {'Paul': 'finalist', 'Dave': 'third',
                                 'Sam': 'finalist'})
        f = c['finals']
        self.assertEqual(f['names'], ['Paul', 'Sam'])
        self.assertTrue(f['halved'])
        self.assertEqual(f['nets'], [5, 5])
        self.assertEqual(f['leader'], 'Sam')
        self.assertEqual(f['standing'], '1 UP')
        self.assertEqual((f['thru'], f['to_play']), (5, 4))
        self.assertEqual(c['pill']['text'], 'Finals · Sam 1 UP')
        self.assertEqual(c['pill']['sub'], '4 to play')
        self.assertEqual([t['state'] for t in f['tiles']],
                         ['a', 'h', 'b', 'b', 'h', 'x', 'x', 'x', 'x'])
        # The third man's row has no strokes and no net.
        dave = next(p for p in c['players'] if p['first'] == 'Dave')
        self.assertEqual((dave['strokes'], dave['net']), (0, None))

    def test_the_finals_strokes_are_off_the_lower_of_the_two(self):
        self.play(14)
        c = self.card(14)
        # Sam gets 6 from Paul; hole 14 is SI 4, so he strokes on it.
        sam = next(p for p in c['players'] if p['first'] == 'Sam')
        self.assertEqual(sam['strokes'], 1)
        self.assertEqual(sam['net'], 5)

    def test_round_over_sam_wins_and_the_money(self):
        self.play(18)
        c = self.card(18)
        self.assertTrue(c['round_over'])
        self.assertEqual(c['finals']['standing'], '1 UP')
        self.assertEqual(c['winner']['name'], 'Sam Reid')
        self.assertIn('Sam wins the finals 1 UP', c['winner']['text'])
        rows = {r['name']: (r['place'], r['net']) for r in c['result']['rows']}
        self.assertEqual(rows, {'Sam Reid': ('1st', 10.0),
                                'Paul Lipkin': ('2nd', 0.0),
                                'Dave Moran': ('3rd', -10.0)})
        self.assertEqual(c['result']['pot'], 30.0)
        self.assertEqual(sum(r['net'] for r in c['result']['rows']), 0)

    def test_no_money_before_the_last_hole(self):
        self.play(14)
        self.assertIsNone(self.card(14)['result'])


class TheEngineRuleTests(_Base):
    def test_a_clear_second_needs_no_play_on(self):
        g = [r[:] for r in G0]
        g[2] = [x + 3 for x in g[2]]          # Sam far behind
        self.gross = g
        self.play(9)
        s = three_person_match_summary(self.fs)
        self.assertEqual(s['status'], 'phase2')
        c = self.card(9)
        self.assertIn('play the finals, scored from the 10th', c['line'])
        self.assertTrue(c['next']['title'].startswith('Finals '))

    def test_play_on_does_not_stop_at_the_18th(self):
        # Level for 2nd all the way: the engine must not spin past 18.
        self.gross = [[4] * 18] * 3
        setup_three_person_match(self.fs, handicap_mode='gross')
        self.play(18)
        s = three_person_match_summary(self.fs)
        self.assertEqual(s['status'], 'tiebreak')

    def test_the_summary_has_no_sudden_death_rows(self):
        self.play(10)
        s = three_person_match_summary(self.fs)
        self.assertEqual(s['tiebreak']['holes'], [])
        self.assertEqual(s['play_on']['through'], 10)
        self.assertEqual(sorted(s['play_on']['level_ids']),
                         sorted([self.D, self.S]))

    def test_a_halved_finals_splits_first_and_second(self):
        self.gross = [[4] * 18, [4] * 18, [9] * 18]
        setup_three_person_match(
            self.fs, handicap_mode='gross', entry_fee=10,
            payout_config={'1st': 20, '2nd': 10, '3rd': 0})
        self.play(18)
        s = three_person_match_summary(self.fs)
        self.assertEqual(s['status'], 'complete')
        pay = {p['short_name']: p['money'] for p in s['players']}
        # 1st and 2nd split ($20 + $10), 3rd nothing.
        vals = sorted(pay.values())
        self.assertEqual(vals, [0.0, 15.0, 15.0])


class FixtureRegenTests(_Base):
    def _write(self, name, card):
        if os.environ.get('REGEN_M3_FIXTURES') != '1':
            return
        (FIX / f'mini_singles_three_{name}.json').write_text(
            json.dumps(card, indent=1) + '\n')

    def test_points_entry(self):
        self.play(3, skip={(3, 2)})
        self._write('hole3_entry', self.card(3))

    def test_points_tray(self):
        self.play(5)
        self._write('hole5', self.card(5))

    def test_level(self):
        self.play(9)
        self._write('hole9', self.card(9))

    def test_play_on(self):
        self.play(10)
        self._write('hole10', self.card(10))

    def test_clear(self):
        self.play(11)
        self._write('hole11', self.card(11))

    def test_finals(self):
        self.play(14)
        self._write('hole14', self.card(14))

    def test_round_over(self):
        self.play(18)
        self._write('hole18', self.card(18))


class TheLeaderboardScorecardTests(_Base):
    """Gross, points and the stroke index on the board's card, like
    Stableford's — with the strokes planned prospectively."""

    def sc(self):
        return three_person_match_summary(self.fs)['scorecard']

    def test_every_hole_carries_par_index_gross_and_points(self):
        self.play(3)
        sc = self.sc()
        self.assertEqual(sc['holes_in_play'], list(range(1, 19)))
        h1 = sc['holes'][0]
        self.assertEqual((h1['par'], h1['stroke_index']), (4, 7))
        row = {s['player_id']: s for s in h1['scores']}
        self.assertEqual(row[self.P]['gross'], 4)
        self.assertEqual(row[self.P]['points'], 5.0)
        # An unplayed hole has no gross and no points but keeps its index.
        h9 = sc['holes'][8]
        self.assertEqual(h9['stroke_index'], 15)
        self.assertTrue(all(s['gross'] is None and s['points'] is None
                            for s in h9['scores']))

    def test_the_strokes_are_planned_on_holes_nobody_has_played(self):
        self.play(1)
        h4 = self.sc()['holes'][3]          # SI 1
        n = {s['player_id']: s['strokes'] for s in h4['scores']}
        self.assertEqual(n, {self.P: 0, self.D: 1, self.S: 1})

    def test_the_finals_holes_use_the_finals_strokes(self):
        self.play(14)
        sc = self.sc()
        # Hole 14 (SI 4) is a finals hole: Sam strokes off Paul (6), the
        # third man (Dave) gets nothing.
        n = {s['player_id']: s['strokes'] for s in sc['holes'][13]['scores']}
        self.assertEqual(n, {self.P: 0, self.D: 0, self.S: 1})
        # …while a points hole kept the points strokes (Dave off Paul: 3).
        n4 = {s['player_id']: s['strokes'] for s in sc['holes'][3]['scores']}
        self.assertEqual(n4[self.D], 1)

    def test_it_is_there_before_a_score(self):
        self.assertEqual(len(self.sc()['holes']), 18)


class BeforeTheFinalsFirstAndSecondSplitTests(_Base):
    """No edge to finishing first on points — both play the finals."""

    def money(self):
        return {p['short_name']: p['money']
                for p in three_person_match_summary(self.fs)['players']}

    def test_a_clear_top_two_split_first_and_second(self):
        g = [r[:] for r in G0]
        g[2] = [x + 3 for x in g[2]]          # Sam far behind after nine
        self.gross = g
        self.play(9)
        pay = sorted(self.money().values())
        self.assertEqual(pay, [0.0, 15.0, 15.0])   # ($20 + $10) / 2, 3rd: $0

    def test_level_for_second_keeps_everyone_in_the_share(self):
        self.play(9)
        self.assertEqual(sorted(self.money().values()), [10.0, 10.0, 10.0])

    def test_the_finals_still_decides_the_final_money(self):
        self.play(18)
        s = three_person_match_summary(self.fs)
        pay = {p['name']: p['money'] for p in s['players']}
        self.assertEqual(pay['Sam Reid'], 20.0)
        self.assertEqual(pay['Paul Lipkin'], 10.0)
        self.assertEqual(pay['Dave Moran'], 0.0)
