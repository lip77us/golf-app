"""
scoring/tests/test_sequoya_hole_card.py
---------------------------------------
The Sequoya 3s score-entry card (`~/Downloads/handoff-sequoya-score-entry`).

Played through the engine with the handoff's own golfers and its own holes
7-9: Paul (12), Dave (9), Sam (15), Mike (18), strokes off Dave, so Paul gets
3, Sam 6 and Mike 9. Match 3 is Paul + Mike v Dave + Sam.

Set REGEN_SEQUOYA_FIXTURES=1 to rewrite the JSON `mobile/test` draws, so the
tray is tested against what the server really sends.
"""
import json
import os

from django.test import TestCase

from games.models import SequoyaThreesGame
from services.sequoya_threes import (call_press, press_start_hole,
                                     sequoya_hole_card,
                                     sequoya_threes_summary,
                                     setup_sequoya_threes, strokes_by_hole,
                                     _net_by_hole, pairing_for_match)
from ._helpers import make_foursome, make_round, make_tee, submit_hole

# The handoff's card where it states one: 7 is a par 3 on SI 17, 8 a par 4 on
# SI 5, 9 a par 5 on SI 11, 11 on SI 2 and 18 on SI 10.
_SI  = [7, 13, 1, 15, 3, 9, 17, 5, 11, 8, 2, 16, 4, 12, 18, 6, 14, 10]
_PAR = [4, 4, 4, 4, 4, 4, 3, 4, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4]
HOLES = [{'number': n, 'par': _PAR[n - 1], 'stroke_index': _SI[n - 1],
          'yards': 400} for n in range(1, 19)]


class _Base(TestCase):
    PRESS = SequoyaThreesGame.PRESS_MANUAL_AUTO
    MODE  = 'strokes_off'

    def setUp(self):
        self.tee = make_tee(holes=HOLES)
        self.round = make_round(self.tee.course,
                                active_games=['sequoya_threes'])
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 12), ('Dave Kim', 9), ('Sam Reid', 15),
             ('Mike Alvarez', 18)], tee=self.tee)
        self.p = {m.player.name.split()[0]: m.player_id
                  for m in self.fs.memberships.select_related('player')}
        self.game = setup_sequoya_threes(
            self.fs, [self.p['Paul'], self.p['Dave']], bet_amount=5,
            handicap_mode=self.MODE, press_mode=self.PRESS)

    def _play(self, hole, paul, dave, sam, mike):
        submit_hole(self.fs, hole, [(self.p['Paul'], paul),
                                    (self.p['Dave'], dave),
                                    (self.p['Sam'], sam),
                                    (self.p['Mike'], mike)])

    def _halve(self, *holes):
        """Everybody nets a 4, so the hole is halved whatever the pairing."""
        for hole in holes:
            alloc = strokes_by_hole(self.game, self.fs, [hole])
            self._play(hole, *[4 + alloc.get(self.p[n], {}).get(hole, 0)
                               for n in ('Paul', 'Dave', 'Sam', 'Mike')])

    def _win(self, hole, name):
        """`name` nets a 3 and the other three a 4."""
        alloc = strokes_by_hole(self.game, self.fs, [hole])
        self._play(hole, *[(3 if n == name else 4)
                           + alloc.get(self.p[n], {}).get(hole, 0)
                           for n in ('Paul', 'Dave', 'Sam', 'Mike')])

    def _card(self, hole):
        return sequoya_hole_card(self.fs, hole)

    def _money(self, card):
        return {r['name'].split()[0]: r['amount'] for r in card['money']}

    def _chips(self, card):
        return [(c['text'], c['state'], c['status']) for c in card['bets']]

    def _dump(self, card, name):
        if os.environ.get('REGEN_SEQUOYA_FIXTURES'):
            with open(f'mobile/test/fixtures/{name}.json', 'w') as fh:
                json.dump(card, fh, indent=1)


class TheHandoffsMatchThreeTests(_Base):
    """Phones 2-4, with holes 1-6 halved so the money starts from nothing."""

    def setUp(self):
        super().setUp()
        self._halve(1, 2, 3, 4, 5, 6)

    def _seven(self):
        self._play(7, 3, 2, 4, 4)            # Dave's 2: Dave + Sam win, 3 v 2

    def _eight(self):
        self._play(8, 4, 4, 5, 6)            # nets 4, 4, 4, 5: halved

    def _nine(self):
        self._play(9, 4, 5, 6, 6)            # net 4 v 5: Paul + Mike

    def test_the_sides_are_match_threes_in_card_order(self):
        c = self._card(7)
        self.assertEqual([s['label'] for s in c['sides']],
                         ['Paul + Mike', 'Dave + Sam'])
        self.assertEqual(c['match'], {'index': 3, 'start_hole': 7,
                                      'end_hole': 9, 'hole_of': 1,
                                      'holes': 3})
        self.assertEqual(c['label'], 'Hole 7 · Match 3')
        self.assertEqual(c['stake_label'], '$5 a bet')

    def test_the_keypad_has_its_strokes_before_a_score_is_in(self):
        c = self._card(8)
        strokes = {p['first']: p['strokes'] for p in c['players']}
        self.assertEqual(strokes, {'Paul': 0, 'Dave': 0, 'Sam': 1, 'Mike': 1})
        self.assertFalse(c['hole_complete'])
        self.assertIsNone(c['result'])
        self.assertIsNone(c['press'])

    def test_winning_the_first_hole_promises_the_auto_press(self):
        self._seven()
        c = self._card(7)
        self._dump(c, 'sequoya_hole7_auto_press_starts')
        self.assertEqual(c['result'], {'winner': 2, 'text': 'Won hole 7',
                                       'nets': 'net 3 v 2'})
        self.assertEqual(self._chips(c), [
            ('Match', '1 UP', 'live'),
            ('Auto press starts 8', '', 'pending')])
        self.assertEqual(c['bets'][0]['leader'], 2)
        self.assertEqual(c['standing'], {'text': 'Dave + Sam 1 UP',
                                         'leader': 2, 'tail': '2 to play'})
        self.assertEqual(self._money(c),
                         {'Dave': 5, 'Sam': 5, 'Paul': -5, 'Mike': -5})
        self.assertEqual(c['thru'], 7)
        self.assertEqual(c['next_label'], 'Hole 8')
        self.assertIsNone(c['next_match'])

    def test_a_halved_hole_names_both_best_balls(self):
        self._seven(); self._eight()
        c = self._card(8)
        self._dump(c, 'sequoya_hole8_halved')
        self.assertEqual(c['result'], {'winner': None, 'text': 'Halved',
                                       'nets': 'net 4 v 4'})
        self.assertEqual([s['best'] for s in c['sides']], [4, 4])
        self.assertEqual(self._chips(c), [('Match', '1 UP', 'live'),
                                          ('Auto press', 'AS', 'live')])
        self.assertEqual(c['standing']['tail'], '1 to play')

    def test_no_press_is_offered_over_a_level_auto_press(self):
        """The handoff's phone 3 draws a Press button here. The engine
        refuses it, and has since the format shipped: the auto press is
        LEVEL with exactly the 9th left, so a press over the 9th would settle
        on the same golf — a double, not a press."""
        self._seven(); self._eight()
        self.assertIsNone(self._card(8)['press'])
        with self.assertRaises(ValueError):
            call_press(self.fs, match_index=3, side=1,
                       called_by_id=None, current_hole=8)

    def test_the_last_hole_of_a_match_changes_the_partners(self):
        self._seven(); self._eight(); self._nine()
        c = self._card(9)
        self._dump(c, 'sequoya_hole9_partners_change')
        self.assertEqual(self._chips(c), [('Match', 'Halved', 'final'),
                                          ('Auto press', '1 UP', 'final')])
        self.assertEqual(c['bets'][1]['leader'], 1)
        self.assertEqual(c['standing'], {'text': 'Match 3 halved',
                                         'leader': None, 'tail': 'no carry'})
        self.assertEqual(c['next_match'], {
            'index': 4, 'start_hole': 10,
            'side1': 'Paul + Dave', 'side2': 'Sam + Mike',
            'repeats': 'repeats match 1',
            'note': 'Holes 10–12. Win 10 and the auto press opens on 11–12.'})
        self.assertEqual(c['next_label'], 'Match 4 · hole 10')
        self.assertEqual(self._money(c),
                         {'Paul': 5, 'Mike': 5, 'Dave': -5, 'Sam': -5})

    def test_a_reopened_hole_reports_the_round_as_of_that_hole(self):
        """Not the round's totals: the 7th's tray on the 10th tee must still
        say what the 7th did."""
        self._seven(); self._eight(); self._nine()
        c = self._card(7)
        self.assertEqual(self._chips(c), [
            ('Match', '1 UP', 'live'),
            ('Auto press starts 8', '', 'pending')])
        self.assertEqual(self._money(c),
                         {'Dave': 5, 'Sam': 5, 'Paul': -5, 'Mike': -5})
        self.assertEqual(c['thru'], 7)

    def test_the_latest_card_agrees_with_the_board(self):
        self._seven(); self._eight(); self._nine()
        board = {r['player_id']: r['live_money']
                 for r in sequoya_threes_summary(self.fs)['players']}
        card = {r['player_id']: r['amount'] for r in self._card(9)['money']}
        self.assertEqual(card, board)
        self.assertEqual(sum(card.values()), 0)

    def test_money_rows_run_highest_first_then_card_order(self):
        self._seven()
        self.assertEqual([r['name'].split()[0]
                          for r in self._card(7)['money']],
                         ['Dave', 'Sam', 'Paul', 'Mike'])


class CalledPressTests(_Base):

    def test_one_down_after_a_halved_first_hole_may_press(self):
        self._halve(1)
        self._win(2, 'Sam')                  # match 1: Paul + Dave v Sam + Mike
        c = self._card(2)
        self._dump(c, 'sequoya_hole2_press_offered')
        self.assertEqual(c['press'], {
            'side': 1, 'names': 'Paul + Dave', 'start_hole': 3,
            'note': 'Press opens a $5 bet for Paul + Dave on 3. Only '
                    'Paul + Dave can call it, once a match.'})

    def test_calling_it_takes_the_offer_away_and_leaves_a_promise(self):
        self._halve(1)
        self._win(2, 'Sam')
        call_press(self.fs, match_index=1, side=1,
                   called_by_id=self.p['Paul'], current_hole=2)
        c = self._card(2)
        self._dump(c, 'sequoya_hole2_press_called')
        self.assertIsNone(c['press'])
        self.assertEqual(self._chips(c)[-1],
                         ('Press · Paul + Dave starts 3', '', 'pending'))

    def test_two_down_may_still_press_the_last_hole(self):
        """The match is closed and the auto press is dormie, so a fresh bet
        over the last hole repeats neither."""
        self._win(1, 'Sam'); self._win(2, 'Sam')
        c = self._card(2)
        self.assertEqual(c['press']['side'], 1)
        self.assertEqual(c['press']['start_hole'], 3)

    def test_a_level_match_offers_nothing(self):
        self._halve(1, 2)
        self.assertIsNone(self._card(2)['press'])

    def test_the_last_hole_of_a_match_offers_nothing(self):
        self._halve(1, 2)
        self._win(3, 'Sam')
        self.assertIsNone(self._card(3)['press'])

    def test_an_earlier_hole_is_not_handed_a_later_holes_press(self):
        self._halve(1)
        self._win(2, 'Sam')
        self.assertIsNone(self._card(1)['press'])

    def test_a_press_never_covers_a_hole_already_played(self):
        self._win(1, 'Sam'); self._win(2, 'Sam')
        ids = [self.p[n] for n in ('Paul', 'Dave', 'Sam', 'Mike')]
        s1, s2 = pairing_for_match(ids, self.game.match1_side1, 1)
        net = _net_by_hole(self.game, self.fs)
        # Asked from the 1st with the 2nd in the book: the 3rd, not the 2nd.
        self.assertEqual(press_start_hole(net, s1, s2, 1, 1), 3)

    def test_auto_only_rounds_offer_nothing(self):
        setup_sequoya_threes(
            self.fs, [self.p['Paul'], self.p['Dave']], bet_amount=5,
            press_mode=SequoyaThreesGame.PRESS_AUTO)
        self._halve(1)
        self._win(2, 'Sam')
        self.assertIsNone(self._card(2)['press'])


class ClosedEarlyTests(_Base):

    def test_a_closed_match_says_so_and_names_the_live_press(self):
        """Phone 5: 2 up with 1 to play, the auto press still running."""
        self._halve(*range(1, 10))
        self._win(10, 'Paul'); self._win(11, 'Paul')
        c = self._card(11)
        self._dump(c, 'sequoya_hole11_closed_early')
        self.assertEqual(self._chips(c), [('Match', '2&1', 'final'),
                                          ('Auto press', '1 UP', 'live')])
        self.assertEqual(c['standing'], {
            'text': 'Paul + Dave win 2&1', 'leader': 1,
            'tail': 'match 4 over · press live on 12'})

    def test_the_closed_out_chip_survives_the_last_hole(self):
        """The margin keeps moving after a close-out; the chip must not."""
        self._halve(*range(1, 10))
        self._win(10, 'Paul'); self._win(11, 'Paul'); self._win(12, 'Paul')
        c = self._card(12)
        self.assertEqual(self._chips(c)[0], ('Match', '2&1', 'final'))
        self.assertEqual(c['standing']['tail'], 'match 4 over')


class ClosedWithNothingRidingTests(_Base):
    PRESS = SequoyaThreesGame.PRESS_NONE

    def test_a_closed_match_with_no_press_says_nothing_rides(self):
        self._halve(*range(1, 10))
        self._win(10, 'Paul'); self._win(11, 'Paul')
        c = self._card(11)
        self.assertEqual(c['standing']['tail'],
                         'match 4 over · nothing riding on 12')

    def test_the_next_match_note_promises_no_auto_press(self):
        self._halve(1, 2, 3)
        self.assertEqual(self._card(3)['next_match']['note'], 'Holes 4–6.')
        self.assertEqual(self._card(3)['next_match']['repeats'], '')


class RoundOverTests(_Base):

    def test_the_eighteenth_is_the_end(self):
        self._halve(*range(1, 18))
        self._win(18, 'Paul')
        c = self._card(18)
        self._dump(c, 'sequoya_hole18_round_over')
        self.assertTrue(c['round_over'])
        self.assertIsNone(c['next_hole'])
        self.assertIsNone(c['next_label'])
        self.assertIsNone(c['next_match'])
        self.assertEqual(c['standing']['text'], 'Paul + Mike win 1 UP')
        self.assertEqual(c['standing']['tail'], 'match 6 over')

    def test_an_unfinished_eighteenth_is_not_round_over(self):
        self._halve(*range(1, 18))
        self.assertFalse(self._card(18)['round_over'])


class GrossTests(_Base):
    MODE = 'gross'

    def test_a_gross_game_does_not_call_its_scores_net(self):
        self._play(1, 4, 5, 5, 5)
        c = self._card(1)
        self.assertEqual(c['result']['nets'], 'gross 4 v 5')
        self.assertTrue(all(p['strokes'] == 0 for p in c['players']))


class GateTests(_Base):

    def test_no_game_is_no_card(self):
        SequoyaThreesGame.objects.filter(foursome=self.fs).delete()
        self.fs._state.fields_cache.pop('sequoya_threes_game', None)
        self.assertEqual(sequoya_hole_card(self.fs, 1), {})

    def test_the_card_exists_before_anything_is_scored(self):
        """No card means no keypad, so the first tee must have one."""
        c = self._card(1)
        self.assertEqual(c['hole'], 1)
        self.assertEqual(c['scored'], 0)
        self.assertEqual(self._chips(c), [('Match', 'AS', 'live')])
        self.assertEqual(c['standing'], {'text': 'AS', 'leader': None,
                                         'tail': '3 to play'})
        self.assertTrue(all(v == 0 for v in self._money(c).values()))
