"""
scoring/tests/test_solo_hole_card.py
------------------------------------
The solo score-entry card (`handoff-solo-score-entry`), played through the
engine on the handoff's course and card: Paul, CH 12 at 100%.

`REGEN_SOLO_FIXTURES=1` rewrites the JSON the Dart tests draw.
"""
import json
import os
from pathlib import Path

from django.test import TestCase

from games.models import SoloGame
from services.solo import setup_solo, solo_hole_card

from ._helpers import make_foursome, make_round, make_tee, submit_hole

PAR = [4, 4, 3, 5, 4, 4, 3, 4, 5, 4, 4, 3, 5, 4, 4, 3, 4, 5]
SI = [7, 3, 15, 1, 11, 5, 17, 9, 13, 8, 4, 16, 2, 12, 6, 18, 10, 14]
G0 = [5, 4, 4, 6, 4, 6, 3, 5, 6, 5, 5, 3, 5, 4, 4, 2, 5, 6]
FIX = Path(__file__).resolve().parents[2] / 'mobile' / 'test' / 'fixtures'


class _Base(TestCase):
    variant = SoloGame.Variant.STROKE
    auto_press = False

    def setUp(self):
        self.tee = make_tee(holes=[
            {'number': i + 1, 'par': PAR[i], 'stroke_index': SI[i],
             'yards': 400} for i in range(18)])
        self.round = make_round(
            self.tee.course, active_games=['solo_' + self.variant])
        self.fs = make_foursome(self.round, [('Paul Lipkin', 12)],
                                tee=self.tee)
        self.pid = self.fs.memberships.first().player_id
        setup_solo(self.round, variant=self.variant, net_percent=100,
                   auto_press=self.auto_press)

    def play(self, upto, gross=None):
        g = gross or G0
        for h in range(1, upto + 1):
            submit_hole(self.fs, h, [(self.pid, g[h - 1])])

    def card(self, h):
        return solo_hole_card(self.fs, h)


class TheGolferTests(_Base):
    def test_not_solo_no_card(self):
        self.assertEqual(solo_hole_card(self.fs, 19), {})

    def test_header_facts(self):
        self.play(12)
        c = self.card(12)
        self.assertEqual(c['golfer']['first'], 'Paul')
        self.assertEqual(c['golfer']['strokes_total'], 12)
        self.assertEqual(c['golfer']['si_range'], 'SI 1–12')
        self.assertEqual((c['par'], c['stroke_index']), (3, 16))
        self.assertEqual(c['golfer']['net'], 3)
        self.assertEqual(c['title'], 'Stroke Play')

    def test_a_stroke_hole_shows_its_stroke(self):
        self.play(4)
        c = self.card(4)                       # SI 1
        self.assertEqual(c['golfer']['strokes'], 1)
        self.assertEqual(c['golfer']['net'], 5)

    def test_above_a_full_lap_there_is_no_si_range(self):
        self.round.solo_game.net_percent = 200
        self.round.solo_game.save()
        self.round._state.fields_cache.pop('solo_game', None)
        self.assertEqual(self.card(1)['golfer']['si_range'], '')


class StrokePlayTests(_Base):
    def test_hole_12_net_par_and_net_plus_one_thru_12(self):
        self.play(12)
        c = self.card(12)
        self.assertEqual(c['stroke']['word'], 'Net par')
        self.assertEqual(c['stroke']['to_par'], 1)
        self.assertEqual(c['stroke']['to_par_text'], '+1')
        self.assertEqual(c['stroke']['thru'], 12)
        self.assertEqual((c['stroke']['gross_total'],
                          c['stroke']['net_total']), (56, 48))
        self.assertNotIn('final', c)

    def test_round_over(self):
        self.play(18)
        c = self.card(18)
        self.assertTrue(c['round_over'])
        self.assertEqual(c['final']['line'], 'Net total −2')
        self.assertEqual(c['final']['sub'], 'gross 82 · net 70 · par 72')
        self.assertEqual(c['final']['card'], 'Net 70 · −2')
        self.assertIn('nothing to settle', c['final']['note'])

    def test_the_cut_is_as_of_the_hole(self):
        self.play(18)
        c = self.card(5)
        self.assertEqual(c['stroke']['thru'], 5)
        self.assertFalse(c['round_over'])


class NassauTests(_Base):
    variant = SoloGame.Variant.NASSAU

    def chips(self, c):
        # The three bets; presses are asserted on their own.
        return [x['text'] for x in c['nassau']['chips']
                if x['label'] in ('Front', 'Back', 'Overall')]

    def test_hole_12_is_halved_front_par_back_level_overall_par(self):
        self.play(12)
        c = self.card(12)
        self.assertEqual(c['result'], 'halved')
        self.assertEqual(self.chips(c),
                         ['Front Par 1 UP', 'Back AS', 'Overall Par 1 UP'])
        self.assertEqual([x['state'] for x in c['nassau']['chips']],
                         ['final', 'live', 'live'])
        self.assertEqual(c['nassau']['chips'][0]['leader'], 2)

    def test_the_back_nine_says_when_it_starts(self):
        self.play(5)
        c = self.card(5)
        back = c['nassau']['chips'][1]
        self.assertEqual(back['text'], 'Back starts 10')
        self.assertEqual(back['state'], 'pending')

    def test_round_over(self):
        self.play(18)
        c = self.card(18)
        self.assertEqual(c['final']['line'], '2 won · 1 lost')
        self.assertIn('front lost, back won, overall won', c['final']['sub'])
        self.assertEqual(self.chips(c)[1], 'Back Paul 4&2')
        self.assertEqual(self.chips(c)[2], 'Overall Paul 3&2')


class AutoPressTests(NassauTests):
    auto_press = True

    def test_a_press_shows_as_a_chip(self):
        # Two down early on the front nine: par pressing.
        self.play(18, gross=[7, 7, 6, 8] + [4] * 14)
        c = self.card(4)
        texts = [x['text'] for x in c['nassau']['chips']]
        self.assertTrue(any(t.startswith('P1') for t in texts), texts)


class MatchPlayTests(_Base):
    variant = SoloGame.Variant.MATCH

    def test_hole_16_is_won_and_the_match_is_decided_3_and_2(self):
        self.play(16)
        c = self.card(16)
        self.assertEqual(c['result'], 'won')
        m = c['match']
        self.assertEqual(m['standing'], 'Paul wins 3&2')
        self.assertEqual((m['decided'], m['decided_on']), ('3&2', 16))
        self.assertEqual((m['thru'], m['to_play']), (16, 2))
        self.assertIn('Decided on 16 · holes 17–18 played out for the card',
                      m['over_line'])
        # Hole 1 (SI 7, par 4): a 5 with a stroke is net 4 — halved; hole 2
        # (SI 3): a 4 with a stroke is net 3 — won; hole 3: a 4 on a par 3
        # (SI 15, no stroke) is lost.
        self.assertEqual([t['state'] for t in m['tiles']][:3],
                         ['h', 'w', 'l'])
        self.assertEqual(m['tiles'][-1]['state'], 'x')

    def test_the_holes_after_the_close_out_are_dimmed(self):
        self.play(18)
        c = self.card(18)
        tiles = {t['hole']: t for t in c['match']['tiles']}
        self.assertFalse(tiles[16]['dimmed'])
        self.assertTrue(tiles[17]['dimmed'] and tiles[18]['dimmed'])
        self.assertEqual(c['match']['after_line'],
                         'MATCH Paul won 3&2 · hole 18 is played out')

    def test_level_is_all_square(self):
        self.play(1)
        c = self.card(1)
        self.assertIn(c['match']['standing'],
                      ('All square', 'Paul 1 UP', 'Par 1 UP'))

    def test_a_live_match_has_no_after_line(self):
        self.play(10)
        self.assertEqual(self.card(10)['match']['after_line'], '')
        self.assertIsNone(self.card(10)['match']['decided'])


class FixtureRegenTests(_Base):
    def _w(self, name, card):
        if os.environ.get('REGEN_SOLO_FIXTURES') == '1':
            (FIX / f'solo_{name}.json').write_text(
                json.dumps(card, indent=1) + '\n')

    def test_stroke(self):
        self.play(12); self._w('stroke12', self.card(12))
        self.play(18); self._w('stroke18', self.card(18))


class NassauFixtures(_Base):
    variant = SoloGame.Variant.NASSAU

    def test_nassau(self):
        self.play(12)
        if os.environ.get('REGEN_SOLO_FIXTURES') == '1':
            (FIX / 'solo_nassau12.json').write_text(
                json.dumps(self.card(12), indent=1) + '\n')
        self.play(18)
        if os.environ.get('REGEN_SOLO_FIXTURES') == '1':
            (FIX / 'solo_nassau18.json').write_text(
                json.dumps(self.card(18), indent=1) + '\n')


class MatchFixtures(_Base):
    variant = SoloGame.Variant.MATCH

    def test_match(self):
        self.play(16)
        if os.environ.get('REGEN_SOLO_FIXTURES') == '1':
            (FIX / 'solo_match16.json').write_text(
                json.dumps(self.card(16), indent=1) + '\n')
        self.play(18)
        if os.environ.get('REGEN_SOLO_FIXTURES') == '1':
            (FIX / 'solo_match18.json').write_text(
                json.dumps(self.card(18), indent=1) + '\n')
