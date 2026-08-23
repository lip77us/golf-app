"""
scoring/tests/test_pairs_handicap.py
------------------------------------
The pairs allowance tables (docs/design-review/handoff-team-pairs/SPEC.md §4).

**The allowance is doing enormous work here, and that is the finding under
test.** The same pair — Maiolini 4, Yau 19 — plays off 4 in a scramble and 12
in an alternate shot. Three times the strokes for the same two golfers, purely from
the format, which is why the format screen prints the figure on every option
before it is chosen.

Every number below is the packet's own worked card.
"""
from decimal import Decimal

from django.test import SimpleTestCase

from services.team_handicap import (
    BEST_BALL_PCT, PAIRS_TABLES, SCRAMBLE_TABLE, allowance_table,
    best_ball_allowance, player_own_ball_handicap, positional_allowance,
    scramble_allowance,
)


def _pairs(handicaps, team_format, **kw):
    return positional_allowance(
        handicaps, PAIRS_TABLES[team_format], **kw)


class PairsAllowanceTests(SimpleTestCase):
    """Maiolini 4 and Yau 19, through all five formats."""

    PAIR = [4, 19]

    def test_scramble_is_35_low_15_high(self):
        # 1.40 + 2.85 = 4.25 → 4. Two balls every shot, so the pair is strong
        # and takes almost nothing.
        a = _pairs(self.PAIR, 'scramble')
        self.assertEqual(a.raw, Decimal('4.25'))
        self.assertEqual(a.strokes, 4)
        self.assertEqual([c.pct for c in a.contributions], [35, 15])

    def test_alternate_shot_is_half_the_combined(self):
        # 23 combined × 50% = 11.50, and half rounds UP → 12. The most generous
        # format by a distance, and correctly so: one ball means both mistakes
        # are the pair's.
        a = _pairs(self.PAIR, 'alternate_shot')
        self.assertEqual(a.raw, Decimal('11.50'))
        self.assertEqual(a.strokes, 12)

    def test_alternate_shot_table_equals_half_of_combined(self):
        """50% low + 50% high IS 50% of the combined, which is why alternate
        shot needs no special case — it is a positional table like the rest."""
        for pair in ([4, 19], [0, 36], [7, 7], [3, 22]):
            a = _pairs(pair, 'alternate_shot')
            self.assertEqual(a.raw, Decimal(sum(pair)) / 2)

    def test_scotch_is_60_40(self):
        # 2.40 + 7.60 = 10.00 → 10.
        a = _pairs(self.PAIR, 'scotch')
        self.assertEqual(a.raw, Decimal('10.00'))
        self.assertEqual(a.strokes, 10)

    def test_chapman_shares_scotch_s_table(self):
        """Both are two drives then one ball. Chapman buys one extra shot of
        position, which is not worth a stroke — the honest answer rather than
        a manufactured difference."""
        self.assertEqual(PAIRS_TABLES['chapman'], PAIRS_TABLES['scotch'])
        self.assertEqual(_pairs(self.PAIR, 'chapman').strokes, 10)

    def test_best_ball_is_per_golfer_not_a_team_figure(self):
        # 3.40 → 3 and 16.15 → 16. The card reads `3 / 16`; the only pairs
        # format whose allowance is per golfer, and the only one entering two
        # scores.
        self.assertEqual(player_own_ball_handicap(4, BEST_BALL_PCT), 3)
        self.assertEqual(player_own_ball_handicap(19, BEST_BALL_PCT), 16)

    def test_the_format_alone_triples_the_strokes(self):
        """The finding to act on: the same two golfers, three times the strokes."""
        figures = {
            fmt: _pairs(self.PAIR, fmt).strokes for fmt in PAIRS_TABLES
        }
        self.assertEqual(figures['scramble'], 4)
        self.assertEqual(figures['alternate_shot'], 12)
        self.assertEqual(figures['alternate_shot'], 3 * figures['scramble'])


class PairsRoundingTests(SimpleTestCase):
    """Round ONCE, on the total; half up. The rule that costs a stroke when it
    is got wrong."""

    def test_rounded_once_on_the_total(self):
        # 9 × 0.35 = 3.15 and 23 × 0.15 = 3.45 → 6.60 → 7. Rounding each
        # contribution first would give 3 + 3 = 6.
        a = _pairs([9, 23], 'scramble')
        self.assertEqual(a.raw, Decimal('6.60'))
        self.assertEqual(a.strokes, 7)

    def test_half_rounds_up(self):
        a = _pairs([4, 19], 'alternate_shot')
        self.assertEqual(a.raw, Decimal('11.50'))
        self.assertEqual(a.strokes, 12)

    def test_the_table_is_positional_not_roster_order(self):
        """The percentage attaches to the LOW handicap, not to whoever was
        entered first — so a manual order would be a lie."""
        self.assertEqual(_pairs([19, 4], 'scramble').raw,
                         _pairs([4, 19], 'scramble').raw)
        self.assertEqual([c.course_handicap
                          for c in _pairs([19, 4], 'scramble').contributions],
                         [4, 19])

    def test_override_beats_the_table(self):
        """A group's tradition beats the table, and the worked result is still
        returned so the TD sees what they did."""
        a = _pairs([4, 19], 'scramble', override_pct=50)
        self.assertEqual(a.raw, Decimal('11.50'))
        self.assertEqual([c.pct for c in a.contributions], [50, 50])


class PairsBuilderFieldTests(SimpleTestCase):
    """The six pairs drawn on the build screen, and the balance spread it
    reports: 4 to 7 strokes."""

    FIELD = [
        ('Maiolini & Yau',     [4, 19],  Decimal('4.25'), 4),
        ('Petersen & Reilly',  [6, 21],  Decimal('5.25'), 5),
        ('Mercer & Vaughn',    [5, 24],  Decimal('5.35'), 5),
        ('Morgan & Lipkin',    [7, 20],  Decimal('5.45'), 5),
        ('Ferraro & Nunes',    [3, 22],  Decimal('4.35'), 4),
        ('Bellini & Ortega',   [9, 23],  Decimal('6.60'), 7),
    ]

    def test_every_drawn_pair_reproduces(self):
        for name, hcaps, raw, strokes in self.FIELD:
            a = _pairs(hcaps, 'scramble')
            self.assertEqual(a.raw, raw, name)
            self.assertEqual(a.strokes, strokes, name)

    def test_the_balance_strip_reads_4_to_7(self):
        figures = [_pairs(h, 'scramble').strokes for _, h, _, _ in self.FIELD]
        self.assertEqual((min(figures), max(figures)), (4, 7))

    def test_two_handicaps_do_not_average_out(self):
        """The argument for keeping the strip: 3 and 22 plays off 4 while 9 and
        23 plays off 7 — three strokes on a card the field finishes inside
        six."""
        self.assertEqual(_pairs([3, 22], 'scramble').strokes, 4)
        self.assertEqual(_pairs([9, 23], 'scramble').strokes, 7)


class AllowanceTableLookupTests(SimpleTestCase):
    """Keyed on (size, format), never on the format alone — `scramble` is the
    one format both sizes run and its table is NOT shared."""

    def test_scramble_differs_by_size(self):
        self.assertEqual(allowance_table(4, 'scramble'), SCRAMBLE_TABLE)
        self.assertEqual(allowance_table(2, 'scramble'),
                         PAIRS_TABLES['scramble'])
        self.assertNotEqual(allowance_table(4, 'scramble'),
                            allowance_table(2, 'scramble'))

    def test_a_four_man_scramble_is_untouched(self):
        """The regression that matters: Pine 6.15 → 6 and Clay 7.50 → 8, the
        fours worked examples, still come out of the shared code path."""
        self.assertEqual(scramble_allowance([4, 8, 11, 19]).strokes, 6)
        self.assertEqual(scramble_allowance([6, 9, 14, 21]).strokes, 8)

    def test_own_ball_formats_have_no_table(self):
        self.assertIsNone(allowance_table(2, 'best_ball'))
        self.assertIsNone(allowance_table(4, 'shamble'))


class BestBallAllowanceTests(SimpleTestCase):

    def test_summed_figure_is_a_balance_number_only(self):
        # 3.40 + 16.15 = 19.55 → 20. Never subtracted from anything; the strip
        # uses it to stack one pair against another.
        a = best_ball_allowance([4, 19])
        self.assertEqual(a.raw, Decimal('19.55'))
        self.assertEqual(a.strokes, 20)
        self.assertEqual([c.pct for c in a.contributions], [85, 85])

    def test_a_three_man_best_ball_pair_works_unchanged(self):
        """The odd-field way out: each of the three takes 85% of their own."""
        a = best_ball_allowance([4, 19, 12])
        self.assertEqual([c.course_handicap for c in a.contributions],
                         [4, 12, 19])
        self.assertEqual(len(a.contributions), 3)
