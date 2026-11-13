"""
The solo games' lock screens
(`handoff-lock-screens-mgskins-minisingles-nassaunine-solo`, section 4),
played on the handoff's course and card: Paul Lipkin, CH 12 at 100%.
"""
from django.test import TestCase

from games.models import SoloGame
from services.live_activity_registry import (BUILDERS, UNSHIPPED_KINDS,
                                             card_kind)
from services.live_activity_solo import solo_activity_state, solo_final_state
from services.solo import setup_solo

from ._helpers import make_foursome, make_round, make_tee, submit_hole

PAR = [4, 4, 3, 5, 4, 4, 3, 4, 5, 4, 4, 3, 5, 4, 4, 3, 4, 5]
SI = [7, 3, 15, 1, 11, 5, 17, 9, 13, 8, 4, 16, 2, 12, 6, 18, 10, 14]
YDS = [392, 415, 168, 512, 376, 402, 155, 388, 521, 401, 422, 168, 535, 396,
       410, 142, 384, 528]
G0 = [5, 4, 4, 6, 4, 6, 3, 5, 6, 5, 5, 3, 5, 4, 4, 2, 5, 6]


class _Base(TestCase):
    variant = SoloGame.Variant.STROKE
    auto_press = False

    def setUp(self):
        self.tee = make_tee(holes=[
            {'number': i + 1, 'par': PAR[i], 'stroke_index': SI[i],
             'yards': YDS[i]} for i in range(18)])
        self.round = make_round(self.tee.course,
                                active_games=['solo_' + self.variant])
        self.fs = make_foursome(self.round, [('Paul Lipkin', 12)],
                                tee=self.tee)
        self.pid = self.fs.memberships.first().player_id
        setup_solo(self.round, variant=self.variant, net_percent=100,
                   auto_press=self.auto_press)

    def play(self, n):
        for h in range(1, n + 1):
            submit_hole(self.fs, h, [(self.pid, G0[h - 1])])

    def card(self, **kw):
        return solo_activity_state(self.fs, player_id=self.pid, **kw)

    def final(self):
        return solo_final_state(self.fs, player_id=self.pid)


class RegistrationTests(TestCase):
    def test_each_solo_game_draws_a_card_the_app_already_has(self):
        for slug, kind in (('solo_stroke', 'stroke_play'),
                           ('solo_nassau', 'nassau'),
                           ('solo_match', 'match')):
            self.assertIn(slug, BUILDERS)
            self.assertEqual(card_kind(slug), kind)
            # No new layout, so nothing to hold back.
            self.assertNotIn(kind, UNSHIPPED_KINDS)


class StrokePlayTests(_Base):
    def test_running_card(self):
        self.play(12)
        c = self.card()
        self.assertEqual(c['kind'], 'stroke_play')
        self.assertEqual(c['header']['game'], 'SOLO · STROKE PLAY')
        self.assertEqual(c['header']['segment'], 'HOLE 13 · PAR 5 · 535')
        self.assertEqual(c['who'], 'PAUL LIPKIN · NET')
        self.assertEqual(c['number'], {'text': '+1', 'colour': 'mint'})
        self.assertEqual(c['state'], {'word': '6 TO PLAY',
                                      'to_play': '12 STROKES'})
        self.assertEqual(c['sides'], [])
        self.assertEqual(c['thru'], 'THRU 12 · GROSS +9')
        self.assertEqual(c['footer'], {'context': '', 'money': ''})

    def test_no_money_anywhere(self):
        self.play(12)
        c = self.card()
        self.assertEqual(c['footer']['money'], '')
        self.assertNotIn('$', repr(c))

    def test_before_any_score(self):
        c = self.card()
        self.assertEqual(c['thru'], 'TEE OFF')

    def test_final(self):
        self.play(18)
        c = self.final()
        self.assertEqual(c['header']['segment'], 'ROUND COMPLETE')
        self.assertEqual(c['number'], {'text': '−2', 'colour': 'mint'})
        self.assertEqual(c['state'], {'word': '82',
                                      'to_play': 'GROSS, 18 HOLES'})
        self.assertEqual(c['sides'][0]['names'],
                         'Net 70 · par 72 · for fun, nothing to settle')
        self.assertEqual(c['footer']['context'], 'Saved to your rounds · 5 min')
        self.assertEqual(c['thru'], 'THRU 18 · GROSS +10')
        self.assertTrue(c['closed'])


class NassauTests(_Base):
    variant = SoloGame.Variant.NASSAU

    def test_front_nine_rows(self):
        self.play(4)
        c = self.card()
        self.assertEqual(c['kind'], 'nassau')
        self.assertEqual(c['header']['game'], 'SOLO · NASSAU')
        self.assertEqual([r['label'] for r in c['rows']],
                         ['FRONT 9', 'OVERALL'])
        self.assertEqual(c['sides'], [])      # the sides line comes off
        self.assertEqual(c['footer']['money'], '')

    def test_after_the_turn_the_front_is_in_the_footer(self):
        self.play(12)
        c = self.card()
        self.assertEqual([r['label'] for r in c['rows']],
                         ['BACK 9', 'OVERALL'])
        self.assertEqual(c['footer']['context'], 'Front · Par 1 UP')
        back, overall = c['rows']
        self.assertEqual(back['text'], 'ALL SQ')
        self.assertEqual(back['note'], '6 TO PLAY')      # level: count alone
        self.assertEqual(overall['text'], '1 UP')
        self.assertEqual(overall['colour'], 'orange')
        self.assertEqual(overall['note'], 'PAR · 6 TO PLAY')
        self.assertEqual(overall['leader'], 'PAR')
        self.assertEqual(c['thru'], 'THRU 12 · GROSS +9')

    def test_the_golfers_lead_names_him(self):
        self.play(4)
        c = self.card()
        front = c['rows'][0]
        if front['colour'] == 'blue':
            self.assertTrue(front['note'].startswith('PAUL · '))

    def test_final(self):
        self.play(18)
        c = self.final()
        self.assertEqual(c['number']['text'], '2 – 1')
        self.assertEqual(c['state'], {'word': '82',
                                      'to_play': 'GROSS, 18 HOLES'})
        self.assertEqual(c['sides'][0]['names'],
                         'Front lost · back won 4&2 · overall won 3&2')
        self.assertEqual(c['footer']['context'], 'For fun · 5 min')


class MatchPlayTests(_Base):
    variant = SoloGame.Variant.MATCH

    def test_running_match(self):
        self.play(12)
        c = self.card()
        self.assertEqual(c['kind'], 'match')
        self.assertEqual(c['header']['game'], 'SOLO · MATCH PLAY')
        # The handoff's card has Paul one up here; the worked CARD has par one
        # up after twelve (the Nassau's overall says the same), so the leader
        # is par and sits first.
        self.assertEqual(c['number'], {'text': '1 UP', 'colour': 'orange'})
        self.assertEqual(c['state'], {'word': '6 TO PLAY',
                                      'to_play': '12 STROKES'})
        self.assertEqual([s['names'] for s in c['sides']],
                         ['Par', 'Paul Lipkin'])

    def test_par_ahead_leads_the_sides(self):
        # Hole 1 lost, hole 2 lost: par two up.
        submit_hole(self.fs, 1, [(self.pid, 8)])
        submit_hole(self.fs, 2, [(self.pid, 8)])
        c = self.card()
        self.assertEqual([s['names'] for s in c['sides']],
                         ['Par', 'Paul Lipkin'])
        self.assertEqual(c['number'], {'text': '2 UP', 'colour': 'orange'})

    def test_closed_holds_and_the_last_holes_are_for_the_card(self):
        self.play(16)
        c = self.card()
        self.assertEqual(c['number'], {'text': '3 & 2', 'colour': 'blue'})
        self.assertEqual(c['state'], {'word': 'CLOSED',
                                      'to_play': 'ON THE 16TH'})
        self.assertEqual(c['sides'][0]['names'], 'Paul Lipkin beat Par')
        self.assertEqual(c['footer']['context'], '17–18 for the card')
        self.assertEqual(c['thru'], 'THRU 16 · GROSS +8')
        self.assertEqual(c['header']['segment'], 'HOLE 17 · PAR 4 · 384')

    def test_final(self):
        self.play(18)
        c = self.final()
        self.assertEqual(c['number'], {'text': '3 & 2', 'colour': 'blue'})
        self.assertEqual(c['state'], {'word': '82',
                                      'to_play': 'GROSS, 18 HOLES'})
        self.assertEqual(c['sides'][0]['names'],
                         'Beat par, decided on the 16th · for fun')
        self.assertEqual(c['footer']['context'], 'Saved to your rounds · 5 min')

    def test_an_unconfigured_round_has_no_card(self):
        from games.models import SoloGame as S
        S.objects.all().delete()
        self.round._state.fields_cache.pop('solo_game', None)
        self.assertEqual(self.card(), {})
