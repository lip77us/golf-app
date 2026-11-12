"""
scoring/tests/test_triple_nassau_hole_card.py
---------------------------------------------
The Triple Nassau score-entry card (`handoff-triple-nassau-score-entry`),
played through the engine on the handoff's own course and scores:
Paul (4), Dave (9), Sam (14), $10 a bet, $5 presses, auto press at 2 down.

**Sam is 14, not the handoff's 15.** The packet gives him 10 strokes from
Paul and 5 from Dave, which is a 14: off 15 the engine gives him 11 and 6,
and the worked example stops matching on the 3rd.

`REGEN_TN_FIXTURES=1` rewrites the JSON the Dart tests draw.
"""
import json
import os
from pathlib import Path

from django.test import TestCase

from services.nassau import add_manual_press
from services.triple_nassau import (
    setup_triple_nassau, calculate_triple_nassau, triple_nassau_hole_card,
    triple_nassau_summary,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

PAR = [4, 5, 3, 4, 4, 3, 4, 4, 5, 4, 3, 4, 4, 5, 4, 3, 4, 4]
SI = [7, 11, 13, 1, 5, 17, 9, 3, 15, 12, 18, 2, 8, 4, 10, 16, 6, 14]
GROSS = [
    [3, 5, 2, 4, 3, 3, 5, 5, 6, 5, 3, 4, 5, 5, 5, 3, 4, 4],
    [5, 5, 4, 4, 4, 3, 5, 6, 7, 4, 4, 4, 5, 5, 4, 4, 4, 4],
    [5, 5, 4, 4, 5, 5, 6, 5, 7, 5, 3, 6, 4, 5, 4, 5, 5, 5],
]
FIX = Path(__file__).resolve().parents[2] / 'mobile' / 'test' / 'fixtures'


class _Base(TestCase):
    press_mode = 'auto'
    mode = 'strokes_off'

    def setUp(self):
        self.tee = make_tee(holes=[
            {'number': i + 1, 'par': PAR[i], 'stroke_index': SI[i],
             'yards': 400} for i in range(18)])
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 10
        self.round.active_games = ['triple_nassau']
        self.round.save()
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 4), ('Dave Gabe', 9), ('Sam White', 14)],
            tee=self.tee)
        self.ids = [m.player_id for m in self.fs.memberships.all()]
        self.P, self.D, self.S = self.ids
        setup_triple_nassau(self.fs, self.ids, handicap_mode=self.mode,
                            press_mode=self.press_mode, press_unit=5)

    def play(self, upto, skip=()):
        for h in range(1, upto + 1):
            submit_hole(self.fs, h, [(pid, GROSS[i][h - 1])
                                     for i, pid in enumerate(self.ids)
                                     if (h, i) not in skip])
        calculate_triple_nassau(self.fs)

    def card(self, hole):
        return triple_nassau_hole_card(self.fs, hole)

    def match(self, card, a, b):
        return next(m for m in card['matches']
                    if m['player_ids'] == [a, b])

    @staticmethod
    def chips(m):
        return [f"{c['label']} {c['value']}" for c in m['chips']]

    def money(self, card):
        return {e['player_id']: e['amount'] for e in card['money']}


class TheRosterTests(_Base):
    def test_no_game_no_card(self):
        from games.models import TripleNassauGame
        TripleNassauGame.objects.all().delete()
        self.assertEqual(self.card(1), {})

    def test_a_hole_not_in_play_has_no_card(self):
        self.assertEqual(self.card(19), {})

    def test_the_card_draws_before_any_score(self):
        c = self.card(1)
        self.assertEqual(c['scored'], 0)
        self.assertFalse(c['hole_complete'])
        self.assertEqual([p['player_id'] for p in c['players']], self.ids)
        self.assertEqual([m['player_ids'] for m in c['matches']],
                         [[self.P, self.D], [self.P, self.S],
                          [self.D, self.S]])

    def test_strokes_by_match_are_the_pills(self):
        c = self.card(1)
        pills = {p['first']: [x['text'] for x in p['pills']]
                 for p in c['players']}
        self.assertEqual(pills, {
            'Paul': ['plays off scratch'],
            'Dave': ['5 v Paul'],
            'Sam': ['10 v Paul', '5 v Dave'],
        })
        sam = c['players'][2]
        self.assertEqual([x['vs_id'] for x in sam['pills']],
                         [self.P, self.D])

    def test_a_dot_per_match_on_the_hole(self):
        # Hole 4 is SI 1: Dave strokes v Paul, Sam v Paul and v Dave.
        by = {p['first']: p for p in self.card(4)['players']}
        self.assertEqual(by['Paul']['dots'], [])
        self.assertEqual(by['Dave']['dots'], [self.P])
        self.assertEqual(by['Sam']['dots'], [self.P, self.D])
        self.assertEqual(by['Sam']['stroke_text'], 'stroke v Paul, Dave')
        self.assertEqual(by['Sam']['strokes'], 1)
        # Hole 1 is SI 7: only Sam v Paul.
        by = {p['first']: p for p in self.card(1)['players']}
        self.assertEqual(by['Sam']['dots'], [self.P])
        self.assertEqual(by['Sam']['stroke_text'], 'stroke v Paul')
        self.assertEqual(by['Dave']['stroke_text'], 'no strokes')

    def test_a_partly_scored_hole_is_not_complete(self):
        self.play(2)
        submit_hole(self.fs, 3, [(self.P, 2), (self.D, 4)])
        calculate_triple_nassau(self.fs)
        c = self.card(3)
        self.assertEqual(c['scored'], 2)
        self.assertFalse(c['hole_complete'])
        self.assertIsNone(c['players'][2]['gross'])


class NetModeTests(_Base):
    mode = 'net'

    def test_one_allowance_one_pill(self):
        c = self.card(4)
        by = {p['first']: p for p in c['players']}
        self.assertEqual([x['text'] for x in by['Sam']['pills']],
                         ['gets 14'])
        self.assertEqual(by['Sam']['dots'], [None])
        self.assertEqual(by['Paul']['dots'], [None])
        self.assertEqual(by['Sam']['stroke_text'], '1 stroke')


class GrossModeTests(_Base):
    mode = 'gross'

    def test_nobody_gets_anything(self):
        for p in self.card(4)['players']:
            self.assertEqual(p['pills'], [])
            self.assertEqual(p['dots'], [])
            self.assertEqual(p['stroke_text'], 'no strokes')


class TheWorkedExampleTests(_Base):
    def test_hole_3_auto_press_in_both_of_pauls_matches(self):
        self.play(3)
        c = self.card(3)
        pd, ps, ds = (self.match(c, self.P, self.D),
                      self.match(c, self.P, self.S),
                      self.match(c, self.D, self.S))
        self.assertEqual(pd['nets'], [2, 4])
        self.assertEqual(pd['winner_id'], self.P)
        self.assertEqual(self.chips(pd),
                         ['Front 2 UP', 'P1 starts 4', 'Overall 2 UP'])
        self.assertEqual(self.chips(ps),
                         ['Front 2 UP', 'P1 starts 4', 'Overall 2 UP'])
        self.assertEqual([x['state'] for x in pd['chips']],
                         ['live', 'pending', 'live'])
        self.assertEqual(pd['chips'][0]['leader_id'], self.P)
        self.assertTrue(ds['halved'])
        self.assertIsNone(ds['winner_id'])
        self.assertEqual(self.chips(ds), ['Front AS', 'Overall AS'])
        self.assertEqual(self.money(c),
                         {self.P: 40, self.D: -20, self.S: -20})
        self.assertEqual(c['money'][0]['player_id'], self.P)
        self.assertEqual(c['pays'], [])
        self.assertEqual(c['next_hole'], 4)
        self.assertEqual(c['thru'], 3)

    def test_the_turn(self):
        self.play(9)
        c = self.card(9)
        self.assertEqual(
            self.chips(self.match(c, self.P, self.D)),
            ['Front 2 UP', 'P1 Push', 'Overall 2 UP'])
        self.assertEqual(
            self.chips(self.match(c, self.P, self.S)),
            ['Front 3&2', 'P1 1 UP', 'Overall 3 UP'])
        self.assertEqual(
            self.chips(self.match(c, self.D, self.S)),
            ['Front Push', 'Overall AS'])
        pd = self.match(c, self.P, self.D)
        self.assertEqual([x['state'] for x in pd['chips']],
                         ['final', 'final', 'live'])
        self.assertEqual(self.money(c),
                         {self.P: 45, self.D: -20, self.S: -25})

    def test_the_back_nine_drops_the_front(self):
        self.play(14)
        c = self.card(14)
        pd = self.match(c, self.P, self.D)
        labels = [x['label'] for x in pd['chips']]
        self.assertNotIn('Front', labels)
        self.assertEqual(labels[0], 'Back')
        self.assertEqual(labels[-1], 'Overall')
        # Dave goes 2 up on Paul on the back: P1 starts 15.
        self.assertIn('P1 starts 15', self.chips(pd))
        self.assertEqual(pd['chips'][0]['leader_id'], self.D)

    def test_round_over(self):
        self.play(18)
        c = self.card(18)
        self.assertTrue(c['round_over'])
        self.assertIsNone(c['next_hole'])
        self.assertEqual(self.money(c),
                         {self.P: 30, self.D: 20, self.S: -50})
        self.assertEqual(c['pays'], [
            'Paul and Dave are square',
            'Sam pays Paul $30',
            'Sam pays Dave $20',
        ])
        for m in c['matches']:
            self.assertTrue(all(x['state'] == 'final' for x in m['chips']),
                            m['chips'])
            self.assertIsNone(m['press_start'])

    def test_the_money_is_the_summarys(self):
        self.play(18)
        c = self.card(18)
        s = triple_nassau_summary(self.fs)
        self.assertEqual(self.money(c),
                         {p['player_id']: p['net'] for p in s['players']})
        self.assertEqual(sum(self.money(c).values()), 0)

    def test_auto_only_offers_no_press(self):
        self.play(7)
        for m in self.card(7)['matches']:
            self.assertIsNone(m['press_start'])

    def test_no_stake_no_money(self):
        self.round.bet_unit = 0
        self.round.save()
        self.play(3)
        c = self.card(3)
        self.assertEqual(c['money'], [])
        self.assertEqual(c['pays'], [])


class ManualPressTests(_Base):
    press_mode = 'both'

    def test_a_press_is_offered_per_match_by_the_engine(self):
        self.play(7)
        c = self.card(7)
        s = triple_nassau_summary(self.fs)
        for m, sm in zip(c['matches'], s['matches']):
            self.assertEqual(m['press_start'] is not None,
                             bool(sm['match']['can_press']), m)
            if m['press_start'] is not None:
                self.assertEqual(m['press_start'], 8)

    def test_no_press_on_an_unfinished_hole(self):
        self.play(6)
        submit_hole(self.fs, 7, [(self.P, 5)])
        calculate_triple_nassau(self.fs)
        for m in self.card(7)['matches']:
            self.assertIsNone(m['press_start'])

    def test_calling_one_adds_the_chip_and_takes_the_button(self):
        self.play(7)
        m = next(m for m in self.card(7)['matches']
                 if m['press_start'] is not None)
        add_manual_press(self.fs, 8, game_type=m['game_type'])
        calculate_triple_nassau(self.fs)
        after = next(x for x in self.card(7)['matches']
                     if x['game_type'] == m['game_type'])
        self.assertIsNone(after['press_start'])
        pend = [x for x in after['chips'] if x['state'] == 'pending']
        self.assertEqual(len(pend), 1)
        self.assertTrue(pend[0]['manual'])
        self.assertEqual(pend[0]['value'], 'starts 8')
        self.assertTrue(pend[0]['label'].endswith('manual'))
        # …and only in that match.
        for x in self.card(7)['matches']:
            if x['game_type'] != m['game_type']:
                self.assertFalse(
                    any(ch['manual'] for ch in x['chips']), x)


class FixtureRegenTests(_Base):
    press_mode = 'both'

    def _write(self, name, card):
        if os.environ.get('REGEN_TN_FIXTURES') != '1':
            return
        (FIX / name).write_text(json.dumps(card, indent=1) + '\n')

    def test_entry(self):
        self.play(3, skip={(3, 2)})
        self._write('triple_nassau_hole3_entry.json', self.card(3))

    def test_auto_press(self):
        self.play(3)
        self._write('triple_nassau_hole3.json', self.card(3))

    def test_manual_offered(self):
        self.play(7)
        self._write('triple_nassau_hole7.json', self.card(7))

    def test_back_nine(self):
        self.play(14)
        self._write('triple_nassau_hole14.json', self.card(14))

    def test_round_over(self):
        self.play(18)
        self._write('triple_nassau_hole18.json', self.card(18))
