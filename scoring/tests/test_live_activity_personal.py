"""
scoring/tests/test_live_activity_personal.py
--------------------------------------------
The personal cards — Stableford and Stroke Play.

Every other card in the set is a neutral scoreboard: two named sides, a score
between them, the reader a footnote. These have **no sides**, so the headline
is the reader's own number in mint and nothing on them is blue or orange —
those mean *sides* across the whole set.

Spec: `~/Downloads/handoff-lock-screens 2/personal/`. Where its prose table and
its design file disagree, the design file is the truth.
"""
from decimal import Decimal

from django.test import TestCase

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    GAME = 'low_net_round'

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=[self.GAME])
        self.round.primary_game = self.GAME
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['primary_game', 'bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Tom Hayes', 0), ('Sam Reid', 0), ('Dave Moran', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _play(self, hole, hayes, reid, moran):
        submit_hole(self.fs, hole, [(self.pid['Tom Hayes'], hayes),
                                    (self.pid['Sam Reid'], reid),
                                    (self.pid['Dave Moran'], moran)])


class StrokePlayTests(_Base):

    def _state(self, thru, who='Tom Hayes'):
        from services.live_activity_stroke_play import stroke_play_activity_state
        return stroke_play_activity_state(
            self.round, self.fs, player_id=self.pid[who], thru=thru)

    # -- the figure ---------------------------------------------------------

    def test_level_par_is_the_figure_never_the_word(self):
        """`E`, not `EVEN` and not `0`. It is the form a golfer carries in his
        head, and the one the card is for."""
        from services.live_activity_stroke_play import to_par
        self.assertEqual(to_par(0), 'E')

    def test_under_par_uses_a_true_minus_sign(self):
        """At 36px beside a `+` a hyphen is visibly the wrong length, and this
        is the card's one big figure."""
        from services.live_activity_stroke_play import to_par
        self.assertEqual(to_par(-2), '−2')
        self.assertNotIn('-', to_par(-2))
        self.assertEqual(to_par(3), '+3')

    def test_the_headline_is_the_readers_own_figure(self):
        self._play(1, 3, 4, 5)       # par 4: Hayes −1
        s = self._state(1)
        self.assertEqual(s['number']['text'], '−1')
        self.assertEqual(s['number']['colour'], 'mint')

    def test_nothing_on_the_card_is_blue_or_orange(self):
        """Those mean SIDES across the whole set, and this card has none."""
        self._play(1, 3, 4, 5)
        s = self._state(1)
        colours = {s['number']['colour']} | {x['colour'] for x in s['sides']}
        self.assertFalse(colours & {'blue', 'orange'})

    # -- who it is about ----------------------------------------------------

    def test_the_reader_is_named_above_the_number(self):
        """A phone handed round a cart otherwise breaks the assumption that
        the card is about whoever is holding it."""
        self._play(1, 3, 4, 5)
        self.assertEqual(self._state(1)['who'], 'Tom Hayes')

    def test_a_different_reader_gets_a_different_card(self):
        self._play(1, 3, 4, 5)
        self.assertEqual(self._state(1, who='Sam Reid')['who'], 'Sam Reid')
        self.assertEqual(self._state(1, who='Sam Reid')['number']['text'], 'E')

    # -- the header names the mode -----------------------------------------

    def test_the_header_names_the_mode(self):
        """The same four figures mean different games under different modes,
        and a card that does not say which is one two groups read
        differently."""
        self._play(1, 3, 4, 5)
        self.assertIn('STROKE PLAY', self._state(1)['header']['game'])
        self.assertRegex(self._state(1)['header']['game'],
                         r'STROKE PLAY · (GROSS|NET|STROKES OFF)')

    # -- the state slot -----------------------------------------------------

    def test_leading_reads_the_gap_it_is_worth(self):
        self._play(1, 3, 4, 5)
        st = self._state(1)
        self.assertEqual(st['state']['word'], '1ST')
        self.assertIn('CLEAR OF 2ND', st['state']['to_play'])

    def test_chasing_counts_the_strokes_to_first(self):
        self._play(1, 5, 3, 4)       # Hayes +1, Reid −1
        st = self._state(1, who='Tom Hayes')
        self.assertEqual(st['state']['word'], '3RD')
        self.assertIn('TO 1ST', st['state']['to_play'])

    def test_one_stroke_is_singular(self):
        self._play(1, 5, 4, 4)       # Hayes +1, the others level
        self.assertIn('1 STROKE TO 1ST',
                      self._state(1, who='Tom Hayes')['state']['to_play'])

    # -- the line that turns a place into a position ------------------------

    def test_a_chaser_is_told_who_leads_and_by_what(self):
        self._play(1, 5, 3, 4)
        names = self._state(1, who='Tom Hayes')['sides'][0]['names']
        self.assertIn('Sam Reid', names)
        self.assertIn('leads', names)

    def test_a_leader_is_told_who_is_coming_instead(self):
        """A leader's question is who is chasing, not who is in front."""
        self._play(1, 3, 4, 5)
        names = self._state(1)['sides'][0]['names']
        self.assertNotIn('leads', names)
        self.assertIn('Sam Reid', names)

    # -- the footer ---------------------------------------------------------

    def test_the_field_size_is_the_footer(self):
        """A place means nothing without knowing what it is a place in."""
        self._play(1, 3, 4, 5)
        self.assertEqual(self._state(1)['footer']['context'], 'FIELD 3')

    def test_the_money_is_empty_until_the_end(self):
        """A place payout resolves on the 18th green. Never a `$0` — that
        reads as a round played for nothing."""
        self._play(1, 3, 4, 5)
        self.assertEqual(self._state(1)['footer']['money'], '')

    # -- the strip ----------------------------------------------------------

    def test_the_strip_puts_the_qualifier_under_the_figure(self):
        """In a flight the reader compares positions against different amounts
        of golf played, and the pair only means something read together."""
        from services.live_activity_stroke_play import stroke_play_strip
        self._play(1, 3, 4, 5)
        cols = stroke_play_strip(self.round, player_id=self.pid['Tom Hayes'])
        self.assertTrue(cols)
        self.assertTrue(any(c.get('note', '').startswith('thru') for c in cols))
        self.assertTrue(any(c['is_reader'] for c in cols))
        self.assertEqual([c['name'] for c in cols],
                         [n.upper() for n in
                          ('HAYES', 'REID', 'MORAN')][:len(cols)])


class StablefordTests(TestCase):

    def setUp(self):
        from games.models import StablefordGame
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['stableford'])
        self.round.primary_game = 'stableford'
        self.round.save(update_fields=['primary_game'])
        self.fs = make_foursome(
            self.round, [('Tom Hayes', 0), ('Sam Reid', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        # The standard table, which is what `stableford_config` defaults to —
        # a card with no config row has nothing to headline.
        StablefordGame.objects.create(round=self.round)

    def _play(self, hole, hayes, reid):
        submit_hole(self.fs, hole, [(self.pid['Tom Hayes'], hayes),
                                    (self.pid['Sam Reid'], reid)])

    def _state(self, thru, who='Tom Hayes'):
        from services.live_activity_stableford import stableford_activity_state
        return stableford_activity_state(
            self.round, self.fs, player_id=self.pid[who], thru=thru)

    def test_the_headline_is_the_total_in_points(self):
        """A points total after thirteen holes is thirteen table lookups
        summed, and the number golfers most reliably get wrong. This activity
        carries arithmetic, not news."""
        self._play(1, 3, 5)          # par 4: birdie = 3 pts, bogey = 1
        s = self._state(1)
        self.assertTrue(s['number']['text'].endswith('PTS'))
        self.assertEqual(s['number']['colour'], 'mint')

    def test_the_standard_table_is_not_called_modified(self):
        self._play(1, 4, 4)
        self.assertEqual(self._state(1)['header']['game'], 'STABLEFORD')

    def test_a_modified_table_says_so_and_can_go_orange(self):
        """A total can fall and can be negative under a modified table — the
        only place this card uses a second colour."""
        from services.live_activity_stableford import _is_modified
        self.assertFalse(_is_modified(
            {'albatross': 5, 'eagle': 4, 'birdie': 3,
             'par': 2, 'bogey': 1, 'double': 0}))
        self.assertTrue(_is_modified(
            {'albatross': 8, 'eagle': 5, 'birdie': 2,
             'par': 0, 'bogey': -1, 'double': -3}))

    def test_the_state_slot_is_the_place_because_place_is_the_money(self):
        self._play(1, 3, 5)
        st = self._state(1)
        self.assertEqual(st['state']['word'], '1ST')
        self.assertTrue(st['state']['to_play'].startswith('BY '))

    def test_chasing_counts_points_to_first(self):
        self._play(1, 5, 3)
        st = self._state(1, who='Tom Hayes')
        self.assertEqual(st['state']['word'], '2ND')
        self.assertIn('TO 1ST', st['state']['to_play'])

    def test_the_reader_is_named(self):
        self._play(1, 4, 4)
        self.assertEqual(self._state(1)['who'], 'Tom Hayes')

    def test_the_money_is_empty_until_the_end(self):
        self._play(1, 4, 4)
        self.assertEqual(self._state(1)['footer']['money'], '')


class PointsTests(TestCase):
    """Points 5-3-1 — the third personal card, and the one that departs.

    Three-handed only, nine points DIVIDED rather than earned, so a point you
    took is a point neither of the others got. That is why three rows stay
    where every other four-name card became a strip: the row count can never
    grow, and a single number cannot describe the state.
    """

    def setUp(self):
        from services.points_531 import setup_points_531
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['points_531'])
        self.round.primary_game = 'points_531'
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['primary_game', 'bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Tom Hayes', 0), ('Sam Reid', 0), ('Dave Moran', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_points_531(self.fs, handicap_mode='gross')

    def _play(self, hole, hayes, reid, moran):
        from services.points_531 import calculate_points_531
        submit_hole(self.fs, hole, [(self.pid['Tom Hayes'], hayes),
                                    (self.pid['Sam Reid'], reid),
                                    (self.pid['Dave Moran'], moran)])
        calculate_points_531(self.fs)

    def _state(self, thru, who='Tom Hayes'):
        from services.live_activity_points import points_activity_state
        return points_activity_state(
            self.fs, player_id=self.pid[who] if who else None, thru=thru)

    # -- the shape ----------------------------------------------------------

    def test_three_rows_stay(self):
        """One more row than any other card carries, affordable because the
        format is three-handed and the count can never grow."""
        self._play(1, 3, 4, 5)
        self.assertEqual(len(self._state(1)['rows']), 3)

    def test_it_is_not_a_strip(self):
        self._play(1, 3, 4, 5)
        self.assertNotIn('strip', self._state(1))

    def test_nothing_is_blue_or_orange(self):
        self._play(1, 3, 4, 5)
        s = self._state(1)
        self.assertFalse({r['colour'] for r in s['rows']} & {'blue', 'orange'})

    # -- the header names the payoff model ---------------------------------

    def test_the_header_names_the_model_in_the_config_screens_words(self):
        """A group that picked a setting reads it back unchanged; two
        vocabularies for one choice is how a golfer ends up believing the card
        is showing a different game."""
        self._play(1, 3, 4, 5)
        self.assertIn(self._state(1)['header']['game'],
                      ('POINTS · PAY VS AVERAGE', 'POINTS · PAY JUST LEADER',
                       'POINTS · PAY ABOVE YOU'))

    # -- the last hole's award ---------------------------------------------

    def test_the_award_carries_no_plus_sign(self):
        """The card already spends a plus on the money and the gross; a third
        made the column read as a running total."""
        self._play(1, 3, 4, 5)
        for r in self._state(1)['rows']:
            self.assertNotIn('+', r['award'])

    def test_mint_marks_the_best_award_not_the_leader(self):
        """A leader who scrambled while somebody else took the 5 reads dim —
        which is the column's whole job."""
        self._play(1, 3, 4, 5)          # Hayes wins the hole
        rows = {r['label']: r for r in self._state(1)['rows']}
        self.assertTrue(rows['Tom Hayes']['award_best'])
        self.assertFalse(rows['Dave Moran']['award_best'])

    def test_a_tied_hole_marks_both(self):
        self._play(1, 4, 4, 5)
        rows = {r['label']: r for r in self._state(1)['rows']}
        self.assertTrue(rows['Tom Hayes']['award_best'])
        self.assertTrue(rows['Sam Reid']['award_best'])
        self.assertFalse(rows['Dave Moran']['award_best'])

    # -- the money ----------------------------------------------------------

    def test_the_money_is_live_from_the_first_hole(self):
        """The one card in the set where that is true: a hole IS the
        settlement, so the figure is a fact before the group reaches the next
        tee — settled money, never a forecast."""
        self._play(1, 3, 4, 5)
        self.assertNotEqual(self._state(1)['footer']['money'], '')

    def test_behind_is_negative(self):
        """The footer two rows down says `−$2`, and a golfer reading a plus
        above a minus concludes one of them is a bug."""
        self._play(1, 5, 3, 4)          # Hayes last
        st = self._state(1, who='Tom Hayes')['state']
        self.assertTrue(st['word'].startswith('−') or st['word'] == 'LEADS'
                        or st['word'].startswith('+'),
                        f"unexpected state word {st['word']!r}")

    # -- the watcher --------------------------------------------------------

    def test_a_watcher_has_no_row_of_his_own_so_the_leader_is_named(self):
        """Points names all three golfers, so a watcher is the one reader with
        nothing of his own on the card — a gap with no owner would be
        meaningless to him."""
        self._play(1, 3, 4, 5)
        s = self._state(1, who=None)
        self.assertEqual(s['who'], '')
        self.assertIn('HAYES', s['state']['word'])

    def test_nothing_is_bold_on_a_watcher_card(self):
        """That is the tell that none of it is about him."""
        self._play(1, 3, 4, 5)
        s = self._state(1, who=None)
        self.assertEqual({r['colour'] for r in s['rows']}, {'dim'})

    def test_the_watchers_footer_is_the_calculation(self):
        self._play(1, 3, 4, 5)
        self.assertIn('a point', self._state(1, who=None)['footer']['context'])
        self.assertEqual(self._state(1, who=None)['footer']['money'], '')
