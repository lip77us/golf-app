"""
scoring/tests/test_live_activity_triple_nassau.py
-------------------------------------------------
The Triple Nassau lock screen.

**The card exists for one confusion: a golfer knows he is two up, and cannot
remember two up on whom.** Two-player Nassau never has it — one opponent, so a
bare number is unambiguous. Here a bare number is worthless.
"""
from django.test import TestCase

from services.triple_nassau import (setup_triple_nassau, calculate_triple_nassau,
                                    triple_nassau_summary)
from services.live_activity_triple_nassau import (
    triple_nassau_activity_state, triple_nassau_final_state)
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    """Ann, Ben and Cal, gross, $5 a bet — so the nets are the scores."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['triple_nassau'])
        self.round.bet_unit = 5
        self.round.primary_game = 'triple_nassau'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Ben', 0), ('Cal', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.A, self.B, self.C = (self.pid['Ann'], self.pid['Ben'],
                                  self.pid['Cal'])
        setup_triple_nassau(self.fs, [self.A, self.B, self.C],
                            handicap_mode='gross', net_percent=100)

    def _play(self, hole, a, b, c):
        submit_hole(self.fs, hole, [(self.A, a), (self.B, b), (self.C, c)])
        calculate_triple_nassau(self.fs)

    def _state(self, thru, who=None):
        return triple_nassau_activity_state(
            self.fs, player_id=who if who is not None else self.A, thru=thru)

    def _col(self, state, label):
        return next(c for c in state['strip'] if c['label'] == label)


class ColourTests(_Base):
    """**Colour says who is up, so the card never says down.**"""

    def test_the_reader_is_blue_on_his_own_phone(self):
        """The packet's sharpest open question, and sharper here than on Las
        Vegas because there are three of them. Assigned per reader, never per
        player record — or three golfers in one group read the same match in
        three different colour schemes."""
        self._play(1, 4, 5, 5)
        for who in (self.A, self.B, self.C):
            s = self._state(1, who=who)
            mine = [c for c in s['strip'] if c['is_reader']]
            self.assertEqual(len(mine), 2)
            self.assertTrue(all('blue' in c['dots'] for c in mine),
                            'the reader owns blue in both his own matches')

    def test_the_third_match_carries_the_other_two_colours(self):
        self._play(1, 4, 5, 5)
        third = [c for c in self._state(1)['strip'] if not c['is_reader']][0]
        self.assertEqual(set(third['dots']), {'orange', 'plum'})

    def test_the_card_never_says_down(self):
        """A direction word is relative to a reader, and in `BEN·CAL` there is
        no reader to be relative to — `1 UP` between two other men is
        meaningless until you know which. Colour answers it inside the same
        glyph that carries the number."""
        for thru in (1, 5, 9, 13, 18):
            for h in range(1, thru + 1):
                self._play(h, 4, 5, 6)
            for who in (self.A, self.B, self.C):
                for col in self._state(thru, who=who)['strip']:
                    self.assertNotIn('DN', col['figure'])
                    self.assertNotIn('DOWN', col['figure'].upper())

    def test_a_figure_wears_the_colour_of_whoever_is_winning_it(self):
        """`2 UP` in orange under `YOU·BEN` is Ben, two up on you."""
        self._play(1, 5, 4, 6)          # Ben beats Ann; Ann beats Cal
        s = self._state(1, who=self.A)
        self.assertEqual(self._col(s, 'YOU·BEN')['colour'], 'orange')
        self.assertEqual(self._col(s, 'YOU·CAL')['colour'], 'blue')

    def test_level_is_white_and_owns_no_side(self):
        self._play(1, 4, 4, 4)
        col = self._col(self._state(1), 'YOU·BEN')
        self.assertEqual(col['figure'], 'ALL SQ')
        self.assertEqual(col['colour'], '')
        self.assertEqual(col['rule'], '')

    def test_a_watcher_gets_three_equal_columns(self):
        """None of it is his money, and dimming one would imply the other two
        were his."""
        self._play(1, 4, 5, 6)
        s = self._state(1, who=0)
        self.assertEqual([c['dim'] for c in s['strip']], [False] * 3)


class StripTests(_Base):

    def test_three_figures_and_no_more(self):
        """The grid version fit the ceiling at 148pt and was unreadable — a
        table of numbers on a phone held at a tee box is a thing you resolve
        to look at later."""
        self._play(1, 4, 5, 6)
        self.assertEqual(len(self._state(1)['strip']), 3)

    def test_the_readers_two_come_first(self):
        """His are what he acts on; the third is context for the settlement he
        is about to be part of."""
        self._play(1, 4, 5, 6)
        s = self._state(1, who=self.B)
        self.assertEqual([c['is_reader'] for c in s['strip']],
                         [True, True, False])

    def test_the_label_names_the_reader_as_you(self):
        """On his own phone his own name is the one string that tells him
        nothing."""
        self._play(1, 4, 5, 6)
        labels = [c['label'] for c in self._state(1, who=self.A)['strip']]
        self.assertEqual(labels, ['YOU·BEN', 'YOU·CAL', 'BEN·CAL'])

    def test_the_third_match_is_dimmed_but_never_dropped(self):
        """Triple Nassau settles three ways, and the question after the round
        is not *did I win* but who owes whom."""
        self._play(1, 4, 5, 6)
        third = self._col(self._state(1), 'BEN·CAL')
        self.assertTrue(third['dim'])
        self.assertTrue(third['figure'])

    def test_a_settled_match_goes_quiet_not_away(self):
        """Removing it would leave a gap the reader has to interpret, and the
        roster of three is the one thing on this card that never changes."""
        for h in range(1, 8):            # Ann closes the front out; Ben v Cal
            self._play(h, 4, 6, 6)       # stays all square
        s = self._state(7)
        col = self._col(s, 'YOU·BEN')
        self.assertEqual(len(s['strip']), 3)
        self.assertIn('&', col['figure'])
        self.assertEqual(col['colour'], 'dim')
        self.assertEqual(col['rule'], '',
                         'a closed match keeps a grey rule, not the winner’s')


class BetTests(_Base):

    def test_the_header_names_the_hole_and_the_bet(self):
        """Two facts, one string — and the bet label has to be here rather
        than in the strip, because three columns cannot each carry it and they
        are all on the same one."""
        self._play(1, 4, 5, 6)
        # The hole IN PLAY, which is the next one — the locked corner is the
        # round behind you and this is the round in front.
        seg = self._state(1)['header']['segment']
        self.assertIn('HOLE 2', seg)
        self.assertIn('FRONT 9', seg)

    def test_the_overall_takes_over_once_both_nines_are_in(self):
        for h in range(1, 19):
            self._play(h, 4, 5, 6)
        self.assertIn('OVERALL', self._state(18)['header']['segment'])

    def test_the_nine_leads_while_a_nine_is_live(self):
        """It settles sooner and it is the one that gets urgent — same
        precedence as the two-player card."""
        for h in range(1, 13):
            self._play(h, 4, 4, 4)
        self.assertIn('BACK 9', self._state(12)['header']['segment'])

    def test_a_decided_nine_does_not_move_the_strip_off_it(self):
        """A front nine can be 5&4 in two matches and all square in the third.
        An earlier version keyed on `result` and jumped to the back nine on
        the EIGHTH hole — reporting a bet with no holes played while two of
        the front nine were still to come. **The clock is shared because the
        HOLES are shared**, which is the only sense in which it is shared."""
        for h in range(1, 8):
            self._play(h, 4, 6, 6)
        self.assertIn('FRONT 9', self._state(7)['header']['segment'])

    def test_there_is_no_headline_number_while_the_round_runs(self):
        """The strip IS the content, and a single figure above three matches
        would be the bare number this card exists to abolish."""
        self._play(1, 4, 5, 6)
        self.assertEqual(self._state(1)['number']['text'], '')


class FooterTests(_Base):

    def test_the_exposure_is_six_bets_wide(self):
        """Six of the nine bets are his, so a $5 Triple Nassau opens at
        −$30 to +$30."""
        self._play(1, 4, 4, 4)
        self.assertEqual(self._state(1)['footer']['money'], '−$30 to +$30')

    def test_the_third_match_never_enters_it(self):
        """The second reason that column is drawn quieter: it is the only
        thing on the card that does not move the number at the bottom."""
        for h in range(1, 10):           # Ben and Cal settle a front nine too
            self._play(h, 4, 5, 6)
        s = self._state(9)
        # Ann's own exposure must not move when Ben v. Cal settles, beyond
        # what her OWN two matches did — six bets, never nine.
        self.assertEqual(s['footer']['money'].count('$'), 2)

    def test_the_left_half_carries_the_round_in_words(self):
        self._play(1, 4, 5, 6)
        self.assertEqual(self._state(1)['footer']['context'], '$5 a bet')

    def test_it_says_front_nines_in_once_they_are(self):
        # Close scores, so nothing settles outright and the left half is
        # reporting the round's state rather than a finished match.
        for h in range(1, 11):
            self._play(h, 4, 4, 4)
        self.assertEqual(self._state(10)['footer']['context'], 'front nines in')

    def test_a_settled_match_outranks_the_bets_state(self):
        """`Moran settled · 2 to play` is the latest thing the round has to
        say, and the left half carries the latest thing."""
        for h in range(1, 11):
            self._play(h, 4, 6, 6)       # Ann closes both her matches out
        self.assertIn('settled', self._state(10)['footer']['context'])


class FinalTests(_Base):

    def _final(self, who=None):
        return triple_nassau_final_state(
            self.fs, player_id=who if who is not None else self.A)

    def test_it_is_a_three_way_settlement(self):
        for h in range(1, 19):
            self._play(h, 4, 5, 6)
        s = self._final()
        self.assertTrue(s['closed'])
        self.assertEqual(len(s['strip']), 3)
        self.assertTrue(all('$' in c['figure'] or c['figure'] == 'EVEN'
                            for c in s['strip']))

    def test_the_footer_names_the_actions(self):
        """Two of the three figures are his to act on and the card says
        which."""
        for h in range(1, 19):
            self._play(h, 4, 5, 6)
        self.assertTrue(self._final()['footer']['context'].startswith(
            ('Collect', 'pay', 'Nothing')))

    def test_the_rules_are_dropped(self):
        """The money is already colour-coded, and an underline repeating it is
        decoration once nothing can change."""
        for h in range(1, 19):
            self._play(h, 4, 5, 6)
        self.assertEqual({c['rule'] for c in self._final()['strip']}, {''})


class ContractTests(_Base):

    def test_the_kind_is_gated_until_a_build_carries_the_layout(self):
        from services.live_activity_registry import (BUILDERS, card_kind,
                                                     UNSHIPPED_KINDS)
        self.assertIn('triple_nassau', BUILDERS)
        self.assertIn(card_kind('triple_nassau'), UNSHIPPED_KINDS)

    def test_the_widget_can_already_draw_it(self):
        import re
        from pathlib import Path
        from django.conf import settings
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        known = re.search(r'static let known: Set<String> = \[(.*?)\]',
                          swift, re.S).group(1)
        self.assertIn('"triple_nassau"', known)

    def test_every_strip_key_decodes(self):
        from pathlib import Path
        from django.conf import settings
        contract = (Path(settings.BASE_DIR) / 'mobile' / 'ios'
                    / 'SixesActivity' / 'SixesActivity.swift').read_text()
        self._play(1, 4, 5, 6)
        for key in self._state(1)['strip'][0]:
            camel = ''.join(w if i == 0 else w.title()
                            for i, w in enumerate(key.split('_')))
            self.assertTrue(f'case {camel} = "{key}"' in contract
                            or f'var {camel}:' in contract
                            or f'let {camel}:' in contract,
                            f'strip.{key} has no field in StripCol')
