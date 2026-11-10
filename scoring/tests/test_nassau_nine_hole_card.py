"""
scoring/tests/test_nassau_nine_hole_card.py
-------------------------------------------
The Nassau Nine score-entry card (`~/Downloads/handoff-nassau-nine-score-entry`).

**It is the Nassau card over one match.** Nassau Nine is the Nassau engine
with `single_match` — one bet across every hole played, riding the engine's
`front9` slot — so `nassau_hole_card` builds it too. These cover what
differs: one `MATCH` line where a Nassau has three, the span on the tray's
label, and the press rules reaching the 9th.

Set REGEN_NASSAU_FIXTURES=1 to rewrite the JSON `mobile/test` draws.
"""
from services.nassau import add_manual_press, calculate_nassau

from .test_nassau_hole_card import _CardBase


class _NineBase(_CardBase):
    START = 1

    def setUp(self):
        super().setUp()
        self.round.num_holes = 9
        self.round.starting_hole = self.START
        self.round.save(update_fields=['num_holes', 'starting_hole'])

    def _setup(self, **kw):
        kw.setdefault('single_match', True)
        return super()._setup(**kw)

    def _halve(self, *holes):
        for h in holes:
            self._play(h, 4, 5, 4, 5)

    def _texts(self, card, where='lines'):
        lines = card[where] if where == 'lines' else card['bottom']['lines']
        return [c['text'] for c in lines[0]['chips']]

    def _write(self, name, card):
        import json, os, pathlib
        if os.environ.get('REGEN_NASSAU_FIXTURES') != '1':
            return
        path = (pathlib.Path(__file__).resolve().parents[2]
                / 'mobile' / 'test' / 'fixtures' / name)
        path.write_text(json.dumps(card, indent=2, default=str) + '\n')


class OneMatchOneLineTests(_NineBase):

    def test_it_is_a_nassau_nine_card(self):
        self._setup()
        card = self._card(1)
        self.assertEqual(card['kind'], 'nassau_nine')
        self.assertEqual(card['title'], 'Nassau Nine')
        # No span: built from the lowest and highest hole number it was
        # wrong for a nine that wraps the turn and for a match over 18.
        self.assertNotIn('nine', card)
        self.assertEqual(card['press_line'], 'match')

    def test_there_is_no_back_and_no_overall(self):
        self._setup()
        card = self._card(1)
        self.assertEqual([(l['key'], l['label']) for l in card['lines']],
                         [('match', 'MATCH')])

    def test_the_first_tee_reads_all_square_not_unstarted(self):
        self._setup()
        self.assertEqual(self._texts(self._card(1)), ['Match AS'])

    def test_a_full_nassau_keeps_its_three_lines(self):
        """The branch is the game's, not the round's length."""
        super(_NineBase, self)._setup()
        card = self._card(1)
        self.assertEqual([l['key'] for l in card['lines']],
                         ['front', 'back', 'overall'])
        self.assertEqual(card['title'], 'Nassau')
        self.assertEqual(card['press_line'], 'overall')

    def test_the_match_runs_past_the_fourth_hole(self):
        """A Nassau's front nine on a 9-hole round is four holes. The match
        here is all nine, so the 7th still moves it."""
        self._setup(press_mode='none')
        self._halve(1, 2, 3, 4, 5, 6)
        self._play(7, 4, 5, 5, 5)
        self.assertEqual(self._texts(self._card(7)), ['Match 1 UP'])
        self.assertEqual(self._card(7)['lines'][0]['chips'][0]['leader'], 1)


class PressTests(_NineBase):

    def test_two_down_starts_an_auto_press_on_the_next_hole(self):
        """Phone 2: the 2nd ball takes the 7th, Match 2 UP, P1 starts 8."""
        self._setup(press_mode='auto', variant='tiebreak_2nd')
        self._play(1, 4, 5, 5, 5)                    # pine 1 UP
        self._halve(2, 3, 4, 5, 6)
        self._play(7, 4, 4, 4, 5)                    # tied best, 2nd ball
        card = self._card(7)
        self._write('nassau_nine_hole7_press.json', card)
        self.assertEqual(card['reason'], '2nd ball 4 v 5')
        self.assertEqual(self._texts(card), ['Match 2 UP', 'P1 starts 8'])
        self.assertEqual(card['lines'][0]['chips'][1]['state'], 'pending')

    def test_one_down_may_press_by_hand(self):
        self._setup(press_mode='manual')
        self._play(1, 5, 5, 4, 5)                    # clay 1 UP
        card = self._card(1)
        self._write('nassau_nine_hole1_press_offered.json', card)
        self.assertTrue(card['can_press'])

    def test_a_called_press_joins_the_one_line(self):
        self._setup(press_mode='manual')
        self._play(1, 5, 5, 4, 5)
        add_manual_press(self.fs, 2)
        calculate_nassau(self.fs)
        self._play(2, 4, 5, 5, 5)                    # pine take the 2nd
        self.assertEqual(self._texts(self._card(2)),
                         ['Match AS', 'P1 manual 1 UP'])

    def test_a_press_called_late_runs_to_the_last_hole(self):
        """Called on the 8th for the 9th: it joins the one line, belongs to
        the match's only nine, and settles on the hole it covers."""
        self._setup(press_mode='manual', press_unit=10)
        self._halve(1, 2, 3, 4, 5, 6, 7)
        self._play(8, 5, 5, 4, 5)                    # clay 1 UP
        press = add_manual_press(self.fs, 9)
        self.assertEqual((press.nine, press.end_hole), ('front', 9))
        self._play(9, 4, 5, 5, 5)                    # pine take the 9th
        card = self._card(9)
        self.assertEqual(self._texts(card), ['Push', '1 UP'])
        money = {m['label']: m['amount'] for m in card['money']}
        self.assertEqual(money['Paul + Dave'], 10.0)

    def test_an_early_press_runs_to_the_last_hole_too(self):
        self._setup(press_mode='manual')
        self._play(1, 5, 5, 4, 5)
        self.assertEqual(add_manual_press(self.fs, 2).end_hole, 9)

    def test_the_eighth_can_still_be_pressed_and_the_ninth_cannot(self):
        self._setup(press_mode='manual')
        self._halve(1, 2, 3, 4, 5, 6, 7)
        self._play(8, 5, 5, 4, 5)                    # clay 1 UP, one to play
        self.assertTrue(self._card(8)['can_press'])
        self._play(9, 4, 5, 4, 5)
        self.assertFalse(self._card(9)['can_press'])


class TheNinthTests(_NineBase):

    def test_the_ninth_is_the_end_of_the_round(self):
        """Phone 5: pine win the 9th and both bets are settled.

        The handoff draws the match as `3 UP` final. It cannot be: two up
        with one to play is closed out, so the engine says `2&1` — the 9th
        is still played, because the press is riding on it."""
        self._setup(press_mode='auto', press_unit=10)
        self._play(1, 4, 5, 5, 5)
        self._play(2, 4, 5, 5, 5)                    # 2 UP -> P1 starts 3
        self._halve(3, 4, 5, 6, 7, 8)
        self._play(9, 4, 5, 5, 5)                    # pine win the 9th
        card = self._card(9)
        self._write('nassau_nine_hole9_final.json', card)
        self.assertTrue(card['round_over'])
        self.assertIsNone(card['next_hole'])
        chips = card['lines'][0]['chips']
        self.assertEqual([c['text'] for c in chips], ['2&1', '1 UP'])
        self.assertTrue(all(c['state'] == 'final' for c in chips))
        money = {m['label']: m['amount'] for m in card['money']}
        self.assertEqual(money, {'Paul + Dave': 20.0, 'Sam + Mike': -20.0})


class TheMoneyIsOneBetTests(_NineBase):

    def test_a_live_match_is_worth_one_stake_not_two(self):
        """`Each · now` counted an Overall this game does not play, so a
        match two up read +$20 at $10 a bet and then settled at $10."""
        self._setup(press_mode='none')
        self._play(1, 4, 5, 5, 5)
        self._play(2, 4, 5, 5, 5)                    # pine 2 UP, live
        money = {m['label']: m['amount'] for m in self._card(2)['money']}
        self.assertEqual(money, {'Paul + Dave': 10.0, 'Sam + Mike': -10.0})

    def test_the_live_figure_becomes_the_settled_one(self):
        self._setup(press_mode='none')
        self._play(1, 4, 5, 5, 5)
        self._halve(2, 3, 4, 5, 6, 7, 8, 9)          # pine win 1 UP
        money = {m['label']: m['amount'] for m in self._card(9)['money']}
        self.assertEqual(money, {'Paul + Dave': 10.0, 'Sam + Mike': -10.0})

    def test_a_full_nassau_still_counts_front_and_overall(self):
        super(_NineBase, self)._setup(press_mode='none')
        self.round.num_holes = 18
        self.round.save(update_fields=['num_holes'])
        self._play(1, 4, 5, 5, 5)                    # front 1 UP, overall 1 UP
        money = {m['label']: m['amount'] for m in self._card(1)['money']}
        self.assertEqual(money['Paul + Dave'], 20.0)


class ClaremontNineTests(_NineBase):

    def test_both_games_are_one_match_line_each(self):
        self._setup(variant='claremont')
        self._halve(1, 2, 3, 4, 5, 6)
        self._play(7, 4, 4, 4, 5)                    # low halved, high pine
        card = self._card(7)
        self._write('nassau_nine_claremont_hole7.json', card)
        self.assertTrue(card['claremont'])
        self.assertEqual([l['key'] for l in card['lines']], ['match'])
        self.assertEqual([l['key'] for l in card['bottom']['lines']],
                         ['match'])
        self.assertEqual(self._texts(card), ['Match AS'])
        self.assertEqual(self._texts(card, 'bottom'), ['Match +1'])
        self.assertEqual(card['bottom']['points'], 1)


class BackNineTests(_NineBase):
    """The handoff's open question: a group playing 10–18."""
    START = 10

    def test_the_end_follows_the_holes_played(self):
        self._setup(press_mode='manual')
        card = self._card(10)
        self.assertEqual(card['thru'], 1)
        for h in range(10, 17):
            self._halve(h)
        self._play(17, 5, 5, 4, 5)
        self.assertTrue(self._card(17)['can_press'])     # 18 is left
        self._play(18, 4, 5, 4, 5)
        last = self._card(18)
        self.assertFalse(last['can_press'])
        self.assertTrue(last['round_over'])


class APressOverOneHoleSettlesTests(_CardBase):
    """Found building Nassau Nine, and true of every Nassau: a manual press
    called for the LAST hole of a nine was never closed, so it read as in
    progress after the round and paid nothing."""

    def test_a_press_for_the_ninth_of_a_full_nassau_settles(self):
        self._setup(press_mode='manual', press_unit=10)
        for h in range(1, 8):
            self._play(h, 4, 5, 4, 5)
        self._play(8, 5, 5, 4, 5)                    # clay 1 UP on the front
        add_manual_press(self.fs, 9)
        self._play(9, 4, 5, 5, 5)                    # pine take the 9th
        from services.nassau import nassau_summary
        press = nassau_summary(self.fs)['presses'][0]
        self.assertEqual(press['result'], 'team1')
        self.assertEqual(nassau_summary(self.fs)['payouts']['presses'], 10.0)

    def test_a_press_with_holes_left_is_still_live(self):
        self._setup(press_mode='manual', press_unit=10)
        self._play(1, 5, 5, 4, 5)
        add_manual_press(self.fs, 2)
        self._play(2, 4, 5, 5, 5)
        from services.nassau import nassau_summary
        self.assertIsNone(nassau_summary(self.fs)['presses'][0]['result'])
