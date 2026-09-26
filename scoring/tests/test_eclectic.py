"""
scoring/tests/test_eclectic.py
------------------------------
Eclectic — the best score on every hole number, across every round.

The engine's whole subject is SELECTION, so most of what follows is about
which candidate wins and which is quietly dropped. Two cases carry the design:

* **across courses**, where the same hole number has two different pars and a
  bigger gross can be the better score;
* **in the net pool**, where the strokes are given PER ROUND before selection,
  so a golfer can keep a worse gross because that day he had a stroke on it.

Both are drawn from the packet's own worked examples.
"""
from datetime import date

from django.test import TestCase

from games.models import EclecticConfig
from services.eclectic import (
    eclectic_available, eclectic_standings, eclectic_summary,
)
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)

#: A second course whose 5th is a PAR 5 where the default course plays a par 4,
#: and whose 1st is a par 3 where the default plays a par 4. Everything else
#: matches, so any difference a test sees is one of those two holes.
RIDGE_HOLES = [
    {**h,
     'par': 5 if h['number'] == 5 else (3 if h['number'] == 1 else h['par'])}
    for h in DEFAULT_HOLES
]

PAR  = {h['number']: h['par'] for h in DEFAULT_HOLES}
SI   = {h['number']: h['stroke_index'] for h in DEFAULT_HOLES}
RPAR = {h['number']: h['par'] for h in RIDGE_HOLES}


class _Base(TestCase):
    """A two-round event on one course, two golfers, scratch."""

    n_rounds  = 2
    ridge_r2  = False          # play round 2 on the second course
    handicaps = (0, 0)

    def setUp(self):
        self.north = make_course('North Links')
        self.north_tee = make_tee(course=self.north, holes=DEFAULT_HOLES)
        self.ridge = make_course('The Ridge')
        self.ridge_tee = make_tee(course=self.ridge, holes=RIDGE_HOLES, par=73)

        self.tourn = make_tournament(name='Club Champs')
        self.tourn.active_games = ['eclectic']
        self.tourn.total_rounds = self.n_rounds
        self.tourn.save()

        self.ann = make_player('Ann', handicap_index=self.handicaps[0])
        self.bea = make_player('Bea', handicap_index=self.handicaps[1])

        self.rounds = []
        self.foursomes = []
        for n in range(1, self.n_rounds + 1):
            ridge = self.ridge_r2 and n == 2
            r = make_round(course=self.ridge if ridge else self.north,
                           tournament=self.tourn, round_number=n)
            r.date = date(2026, 10, 10 + n)
            r.save()
            fs = make_foursome(
                r,
                [(self.ann, self.handicaps[0]), (self.bea, self.handicaps[1])],
                tee=self.ridge_tee if ridge else self.north_tee)
            self.rounds.append(r)
            self.foursomes.append(fs)

        self.config = EclecticConfig.objects.create(
            tournament=self.tourn,
            gross_entry_fee=10, gross_payouts=[{'place': 1, 'amount': 160},
                                               {'place': 2, 'amount': 80}],
            net_entry_fee=10, net_payouts=[{'place': 1, 'amount': 160},
                                           {'place': 2, 'amount': 80}])

    # -- helpers ------------------------------------------------------------
    def par_round(self, idx, player, *, offsets=None):
        """Score every hole at par for `player`, with optional {hole: delta}."""
        pars = RPAR if self.rounds[idx].course_id == self.ridge.id else PAR
        for h in range(1, 19):
            delta = (offsets or {}).get(h, 0)
            submit_hole(self.foursomes[idx], h,
                        [(player.id, pars[h] + delta)])

    def row(self, pool, player):
        rows = eclectic_standings(self.tourn, pool)
        return next(r for r in rows if r['player_id'] == player.id)

    def card(self, pool, player):
        return eclectic_summary(self.tourn)[pool]['cards'][player.id]


class AvailabilityTests(_Base):
    def test_two_eighteen_hole_rounds_is_available(self):
        ok, reason = eclectic_available(self.tourn)
        self.assertTrue(ok)
        self.assertEqual(reason, '')

    def test_one_round_is_not_an_eclectic(self):
        self.rounds[1].delete()
        ok, reason = eclectic_available(self.tourn)
        self.assertFalse(ok)
        self.assertIn('two or more rounds', reason)

    def test_a_nine_hole_round_disables_it_and_says_why(self):
        # Nine holes would put half the card permanently out of reach.
        self.rounds[1].num_holes = 9
        self.rounds[1].save(update_fields=['num_holes'])
        ok, reason = eclectic_available(self.tourn)
        self.assertFalse(ok)
        self.assertEqual(reason, 'Needs every round to be 18 holes')


class SelectionTests(_Base):
    def test_the_best_of_the_two_rounds_is_kept_hole_by_hole(self):
        # Ann birdies the 3rd on Friday and the 7th on Saturday; par otherwise.
        self.par_round(0, self.ann, offsets={3: -1})
        self.par_round(1, self.ann, offsets={7: -1})
        self.assertEqual(self.row('gross', self.ann)['total'], -2)

    def test_a_bad_hole_is_dropped_entirely(self):
        # A triple on the 5th on Friday, par there on Saturday. The card keeps
        # the par; the triple contributes nothing at all.
        self.par_round(0, self.ann, offsets={5: 3})
        self.par_round(1, self.ann)
        self.assertEqual(self.row('gross', self.ann)['total'], 0)

    def test_a_tie_between_rounds_keeps_the_earlier_one(self):
        self.par_round(0, self.ann)
        self.par_round(1, self.ann)
        card = self.card('gross', self.ann)
        self.assertTrue(card['rounds'][0]['holes'][1]['kept'])
        self.assertFalse(card['rounds'][1]['holes'][1]['kept'])
        # And the total is the same either way, which is why it is a display
        # rule rather than a scoring one.
        self.assertEqual(self.row('gross', self.ann)['total'], 0)

    def test_a_hole_nobody_played_adds_nothing_and_is_not_kept(self):
        # Ann plays 17 holes of R1 and misses R2 entirely.
        pars = PAR
        for h in range(1, 18):
            submit_hole(self.foursomes[0], h, [(self.ann.id, pars[h])])
        row = self.row('gross', self.ann)
        self.assertEqual(row['holes_kept'], 17)
        self.assertEqual(row['total'], 0)
        self.assertNotIn(18, self.card('gross', self.ann)['best'])

    def test_a_missed_round_is_still_eligible(self):
        # Bea plays only round 2 and is ranked, not dropped.
        self.par_round(0, self.ann, offsets={4: -1})
        self.par_round(1, self.ann)
        self.par_round(1, self.bea, offsets={4: -1, 9: -1})
        self.assertEqual(self.row('gross', self.bea)['total'], -2)
        self.assertEqual(self.row('gross', self.bea)['rank'], 1)

    def test_a_golfer_who_has_not_teed_off_is_last_not_first(self):
        # A bare ascending sort would lead him on a total of zero.
        self.par_round(0, self.ann, offsets={4: 1})
        rows = eclectic_standings(self.tourn, 'gross')
        self.assertEqual(rows[0]['player_id'], self.ann.id)
        self.assertIsNone(rows[-1]['total'])
        self.assertEqual(rows[-1]['player_id'], self.bea.id)


class MixedCourseTests(_Base):
    """The packet's own example: a 4 on the Ridge's par-5 5th is a birdie."""

    ridge_r2 = True

    def test_to_par_beats_gross_across_two_courses(self):
        # North's 5th is a par 4, the Ridge's a par 5. Ann makes 4 on both.
        # The Ridge 4 is a BIRDIE and is the one kept, even though the two
        # gross scores are identical.
        self.par_round(0, self.ann)                    # 4 on North's par-4 5th
        self.par_round(1, self.ann, offsets={5: -1})   # 4 on Ridge's par-5 5th
        card = self.card('gross', self.ann)
        self.assertFalse(card['rounds'][0]['holes'][5]['kept'])
        self.assertTrue(card['rounds'][1]['holes'][5]['kept'])
        self.assertEqual(card['best'][5], -1)

    def test_a_bigger_gross_can_be_the_better_score(self):
        # 5 on the Ridge's par-5 5th (level) against 5 on North's par-4 5th
        # (bogey). The bigger number is not the worse score; here they are the
        # same number and only par separates them.
        self.par_round(0, self.ann, offsets={5: 1})
        self.par_round(1, self.ann)
        card = self.card('gross', self.ann)
        self.assertEqual(card['rounds'][0]['holes'][5]['gross'], 5)
        self.assertEqual(card['rounds'][1]['holes'][5]['gross'], 5)
        self.assertTrue(card['rounds'][1]['holes'][5]['kept'])
        self.assertEqual(card['best'][5], 0)

    def test_the_summary_names_the_courses_and_gives_each_an_initial(self):
        s = eclectic_summary(self.tourn)
        self.assertEqual(s['n_courses'], 2)
        self.assertEqual([r['course_initial'] for r in s['rounds']], ['N', 'T'])

    def test_a_collision_drops_the_initial_scheme_for_the_WHOLE_card(self):
        # **All or nothing.** Giving the first course its letter and blanking
        # the second puts a suffix on one row and nothing on the other, which
        # reads as a rendering fault rather than as a rule.
        #
        # The six-round event in the local database is at Bandon, where the
        # five courses are Bandon Dunes, Bandon Trails, Pacific Dunes,
        # Bandon - Sheep Ranch and Bandon Dunes — Old Macdonald. Every one of
        # them is `B`, so this is the ordinary case at a resort, not an edge.
        self.ridge.name = 'North Ridge'
        self.ridge.save(update_fields=['name'])
        s = eclectic_summary(self.tourn)
        self.assertEqual([r['course_initial'] for r in s['rounds']], ['', ''])

    def test_the_legend_keys_on_the_initial_when_the_scheme_holds(self):
        s = eclectic_summary(self.tourn)
        self.assertEqual(s['course_legend'],
                         [{'key': 'N', 'course': 'North Links'},
                          {'key': 'T', 'course': 'The Ridge'}])

    def test_the_legend_falls_back_to_the_round_label(self):
        # Without initials there is nothing else unique to key it on — and the
        # label is already on the row.
        self.ridge.name = 'North Ridge'
        self.ridge.save(update_fields=['name'])
        s = eclectic_summary(self.tourn)
        self.assertEqual(s['course_legend'],
                         [{'key': 'R1', 'course': 'North Links'},
                          {'key': 'R2', 'course': 'North Ridge'}])


class NetPoolTests(_Base):
    """Strokes are given PER ROUND, before selection."""

    handicaps = (18, 0)

    def test_a_stroke_makes_a_worse_gross_the_better_net(self):
        # Ann is off 18, so one stroke on every hole. Level gross both rounds
        # is one under net on every hole: −18.
        self.par_round(0, self.ann)
        self.par_round(1, self.ann)
        self.assertEqual(self.row('gross', self.ann)['total'], 0)
        self.assertEqual(self.row('net', self.ann)['total'], -18)

    def test_the_allocation_is_that_round_s_course_stroke_index(self):
        # Off 9, strokes fall on SI 1-9. Hole 5 is SI 1 and gets one; hole 7 is
        # SI 17 and does not.
        ann = make_player('Cal', handicap_index=9)
        for idx, fs in enumerate(self.foursomes):
            fs.memberships.create(player=ann, tee=fs.memberships.first().tee,
                                  course_handicap=9, playing_handicap=9)
        self.par_round(0, ann)
        self.par_round(1, ann)
        card = self.card('net', ann)
        self.assertEqual(card['rounds'][0]['holes'][5]['strokes'], 1)
        self.assertEqual(card['rounds'][0]['holes'][7]['strokes'], 0)
        self.assertEqual(card['best'][5], -1)
        self.assertEqual(card['best'][7], 0)

    def test_the_gross_pool_ignores_strokes_entirely(self):
        self.par_round(0, self.ann)
        card = self.card('gross', self.ann)
        self.assertEqual(card['rounds'][0]['holes'][5]['strokes'], 0)
        self.assertEqual(card['best'][5], 0)

    def test_the_two_pools_can_rank_differently(self):
        # Bea (scratch) is better gross; Ann (18) is better net.
        self.par_round(0, self.ann)
        self.par_round(1, self.ann)
        self.par_round(0, self.bea, offsets={2: -1})
        self.par_round(1, self.bea)
        self.assertEqual(self.row('gross', self.bea)['rank'], 1)
        self.assertEqual(self.row('net', self.ann)['rank'], 1)


class MoneyTests(_Base):
    def test_the_winner_takes_first(self):
        self.par_round(0, self.ann, offsets={2: -1})
        self.par_round(1, self.ann)
        self.par_round(0, self.bea)
        self.par_round(1, self.bea)
        self.assertEqual(self.row('gross', self.ann)['payout'], 160.0)
        self.assertEqual(self.row('gross', self.bea)['payout'], 80.0)

    def test_a_tie_splits_the_places_it_covers(self):
        # Both level: they share 1st and 2nd, $160 + $80 = $240, $120 each.
        self.par_round(0, self.ann)
        self.par_round(1, self.ann)
        self.par_round(0, self.bea)
        self.par_round(1, self.bea)
        for p in (self.ann, self.bea):
            row = self.row('gross', p)
            self.assertEqual(row['rank'], 1)
            self.assertTrue(row['tied'])
            self.assertEqual(row['payout'], 120.0)

    def test_an_excluded_golfer_is_ranked_but_not_paid(self):
        self.config.excluded_player_ids = [self.ann.id]
        self.config.save(update_fields=['excluded_player_ids'])
        self.par_round(0, self.ann, offsets={2: -1})
        self.par_round(1, self.ann)
        self.par_round(0, self.bea)
        self.par_round(1, self.bea)
        ann = self.row('gross', self.ann)
        self.assertEqual(ann['rank'], 1)          # still on the board
        self.assertTrue(ann['excluded'])
        self.assertFalse(ann['payout'])
        # The place moves UP to the golfer behind him.
        self.assertEqual(self.row('gross', self.bea)['payout'], 160.0)

    def test_a_pool_that_is_off_has_no_standings_and_no_block(self):
        self.config.net_on = False
        self.config.save(update_fields=['net_on'])
        self.par_round(0, self.ann)
        self.assertEqual(eclectic_standings(self.tourn, 'net'), [])
        s = eclectic_summary(self.tourn)
        self.assertEqual(s['pools'], ['gross'])
        self.assertNotIn('net', s)

    def test_no_config_means_no_game(self):
        self.config.delete()
        self.tourn.refresh_from_db()
        self.assertEqual(eclectic_standings(self.tourn, 'gross'), [])
        self.assertEqual(eclectic_summary(self.tourn), {})


class SummaryTests(_Base):
    def test_the_chip_names_the_live_round_until_the_event_closes(self):
        s = eclectic_summary(self.tourn)
        self.assertFalse(s['is_final'])
        self.assertEqual(s['live_label'], '2 rounds live')

        from core.models import RoundStatus
        self.rounds[0].status = RoundStatus.COMPLETE
        self.rounds[0].save(update_fields=['status'])
        self.assertEqual(eclectic_summary(self.tourn)['live_label'], 'R2 live')

        self.rounds[1].status = RoundStatus.COMPLETE
        self.rounds[1].save(update_fields=['status'])
        s = eclectic_summary(self.tourn)
        self.assertTrue(s['is_final'])
        self.assertEqual(s['live_label'], '')

    def test_the_pool_is_the_fee_times_the_field(self):
        self.par_round(0, self.ann)
        self.par_round(0, self.bea)
        s = eclectic_summary(self.tourn)
        self.assertEqual(s['gross']['entry_fee'], 10.0)
        self.assertEqual(s['gross']['pool'], 20.0)
