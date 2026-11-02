"""
scoring/tests/test_live_activity_flights.py
-------------------------------------------
The population a personal lock screen is a place IN.

Both personal cards — Stroke Play and Stableford — headline the reader's own
figure and then qualify it four ways: a place, a gap to first, the golfer who
is leading, and (Stroke Play) the field size in the footer. Every one of those
is measured against a list of golfers, and both cards read the ROUND's own
`results`, which is the whole field.

On an event cut into flights that is the wrong list. Each flight ranks and pays
within itself (`services.flights.rank_in_flights`), so a golfer leading B
flight was shown `4TH` behind a leader he is not playing against — and the
sign-off's header literally read `FLIGHT COMPLETE` about a population it had
never looked up, which is the part that made it read as handled.

The fixture is built so the two readings DIFFER on every slot at once: Dan Hill
is 4th of six and 1st of three.
"""
from decimal import Decimal

from django.test import TestCase

from ._helpers import (make_foursome, make_player, make_round, make_tee,
                       make_tournament, submit_hole)


class _FlightedBase(TestCase):
    """Six golfers, two groups, cut into two flights of three.

    Indexes are 1/2/3 and 14/15/16 so the cut is unambiguous, while every
    MEMBERSHIP plays off scratch — the cut reads `Player.handicap_index` and
    the scoring reads the membership, so this keeps net equal to gross and the
    expected figures arithmetic rather than a handicap calculation.
    """
    GAME = 'low_net_round'

    # (name, handicap_index) — distinct surnames, because the strip renders
    # surnames and three golfers called High would all draw `HIGH`.
    LOW  = [('Ann Reed', 1), ('Ben Stock', 2), ('Cal Tate', 3)]
    HIGH = [('Dan Hill', 14), ('Eve Nolan', 15), ('Fay Oates', 16)]

    def setUp(self):
        self.tee        = make_tee()
        self.tournament = make_tournament(name='Flighted Open', total_rounds=1)
        self.round      = make_round(self.tee.course,
                                     active_games=[self.GAME],
                                     tournament=self.tournament)
        self.round.primary_game = self.GAME
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['primary_game', 'bet_unit'])

        self.pid = {}
        self.fs = {}
        for group, roster in ((1, self.LOW), (2, self.HIGH)):
            members = [(make_player(n, handicap_index=idx), 0)
                       for n, idx in roster]
            self.fs[group] = make_foursome(self.round, members, tee=self.tee,
                                           group_number=group)
            for p, _ in members:
                self.pid[p.name] = p.id

        self._cut(2)

    def _cut(self, n_flights):
        """Frozen BEFORE anybody scores — `set_flights` refuses a re-cut once
        a real gross score exists, which is the whole point of freezing it."""
        from services.flights import set_flights
        if n_flights < 2:
            self.tournament.flight_count = 0
            self.tournament.save(update_fields=['flight_count'])
            self.tournament.flights.all().delete()
            return
        set_flights(self.tournament, n_flights)
        self.tournament.refresh_from_db()

    def _play(self):
        """Hole 1 is par 4. Reed −2, Stock/Tate −1, Hill level, Nolan +1,
        Oates +2 — so Hill is 4TH of the field and 1ST of his flight."""
        submit_hole(self.fs[1], 1, [(self.pid['Ann Reed'], 2),
                                    (self.pid['Ben Stock'], 3),
                                    (self.pid['Cal Tate'], 3)])
        submit_hole(self.fs[2], 1, [(self.pid['Dan Hill'], 4),
                                    (self.pid['Eve Nolan'], 5),
                                    (self.pid['Fay Oates'], 6)])


class FlightedStrokePlayTests(_FlightedBase):

    def _state(self, who='Dan Hill', thru=1):
        from services.live_activity_stroke_play import stroke_play_activity_state
        return stroke_play_activity_state(
            self.round, self.fs[2 if who in dict(self.HIGH) else 1],
            player_id=self.pid[who] if who else None, thru=thru)

    def _final(self, who='Dan Hill'):
        from services.live_activity_stroke_play import stroke_play_final_state
        return stroke_play_final_state(
            self.round, self.fs[2 if who in dict(self.HIGH) else 1],
            player_id=self.pid[who])

    # -- the place ----------------------------------------------------------

    def test_the_place_is_his_place_in_his_own_flight(self):
        """Hill is 4th of six and 1st of three, and the flight is the one he
        is ranked and paid in."""
        self._play()
        self.assertEqual(self._state()['state']['word'], '1ST')

    def test_the_gap_is_to_his_flights_first_not_the_fields(self):
        """Leading his flight, the slot reads what the lead is WORTH. Against
        the whole field it read `2 STROKES TO 1ST` — a gap to a golfer in
        another competition."""
        self._play()
        st = self._state()['state']
        self.assertIn('CLEAR OF 2ND', st['to_play'])
        self.assertNotIn('TO 1ST', st['to_play'])

    def test_a_chaser_is_told_his_own_flights_leader(self):
        self._play()
        names = self._state(who='Fay Oates')['sides'][0]['names']
        self.assertIn('Dan Hill', names)
        self.assertIn('leads', names)
        self.assertNotIn('Ann Reed', names)

    def test_a_flight_leader_is_shown_his_own_flights_chasers(self):
        self._play()
        names = self._state()['sides'][0]['names']
        self.assertNotIn('leads', names)
        self.assertIn('Nolan', names)
        self.assertNotIn('Reed', names)

    # -- the footer ---------------------------------------------------------

    def test_the_footer_names_the_flight_and_counts_it(self):
        """A place means nothing without knowing what it is a place in, which
        is exactly why this is the slot that names the flight rather than the
        header: the header already carries the game and the mode."""
        self._play()
        self.assertEqual(self._state()['footer']['context'], 'B FLIGHT 3')

    def test_the_lower_flight_gets_its_own_letter(self):
        self._play()
        self.assertEqual(self._state(who='Ann Reed')['footer']['context'],
                         'A FLIGHT 3')

    def test_an_uncut_event_still_says_field(self):
        """Unflighted is the same code path with an empty label, so every
        round that is not flighted is byte-for-byte what it was."""
        self._cut(1)
        self._play()
        self.assertEqual(self._state()['footer']['context'], 'FIELD 6')

    def test_a_watcher_gets_the_whole_field(self):
        """He is in no flight, and narrowing to one he is not in would be a
        card about somebody else."""
        self._play()
        from services.live_activity_stroke_play import stroke_play_activity_state
        s = stroke_play_activity_state(self.round, self.fs[2],
                                       player_id=None, thru=1)
        self.assertEqual(s['footer']['context'], 'FIELD 6')

    # -- the header is left alone ------------------------------------------

    def test_the_header_still_names_only_the_game_and_the_mode(self):
        """The flight went in the footer. A third fact in the header is one
        line two groups read differently."""
        self._play()
        self.assertRegex(self._state()['header']['game'],
                         r'^STROKE PLAY · (GROSS|NET|STROKES OFF)$')

    # -- the sign-off -------------------------------------------------------

    def test_the_sign_off_names_the_flight_that_settled(self):
        self._play()
        self.assertEqual(self._final()['header']['segment'],
                         'B FLIGHT COMPLETE')

    def test_an_uncut_sign_off_never_claims_a_flight(self):
        """`FLIGHT COMPLETE` on an event with no cut named something it does
        not have — and read as a feature that was handled."""
        self._cut(1)
        self._play()
        seg = self._final()['header']['segment']
        self.assertEqual(seg, 'ROUND COMPLETE')
        self.assertNotIn('FLIGHT', seg)

    def test_the_sign_off_counts_his_flight_not_the_field(self):
        """`1st of 3`. Second of four and second of forty are not the same
        afternoon, and neither are first of three and fourth of six."""
        self._play()
        line = self._final()['sides'][0]['names']
        self.assertIn('1st of 3', line)
        self.assertNotIn('of 6', line)

    def test_the_sign_off_footer_says_a_flight_settled(self):
        self._play()
        self.assertTrue(
            self._final()['footer']['context'].startswith(
                'B flight of 3 settled'))

    # -- the alternative layout --------------------------------------------

    def test_the_strip_shows_only_the_golfers_he_is_ranked_against(self):
        """A strip of the whole field's top four would put three golfers
        beside the reader that he is not ranked against — the defect this
        layout is the alternative TO."""
        from services.live_activity_stroke_play import stroke_play_strip
        self._play()
        names = [c['name'] for c in
                 stroke_play_strip(self.round, player_id=self.pid['Dan Hill'])]
        self.assertEqual(names, ['HILL', 'NOLAN', 'OATES'])


class FlightedStablefordTests(_FlightedBase):
    """The same narrowing on the other personal card, because the place IS the
    money here and on a flighted event the money is the flight's."""
    GAME = 'stableford'

    def setUp(self):
        super().setUp()
        from games.models import StablefordGame
        # The standard table, which is what `stableford_config` defaults to —
        # a card with no config row has nothing to headline.
        StablefordGame.objects.create(round=self.round)

    def _state(self, who='Dan Hill'):
        from services.live_activity_stableford import stableford_activity_state
        return stableford_activity_state(
            self.round, self.fs[2 if who in dict(self.HIGH) else 1],
            player_id=self.pid[who], thru=1)

    def _final(self, who='Dan Hill'):
        from services.live_activity_stableford import stableford_final_state
        return stableford_final_state(
            self.round, self.fs[2 if who in dict(self.HIGH) else 1],
            player_id=self.pid[who])

    def test_the_place_is_his_place_in_his_own_flight(self):
        self._play()
        self.assertEqual(self._state()['state']['word'], '1ST')

    def test_a_chaser_is_told_his_own_flights_leader(self):
        self._play()
        names = self._state(who='Fay Oates')['sides'][0]['names']
        self.assertIn('Dan Hill', names)
        self.assertNotIn('Ann Reed', names)

    def test_the_sign_off_names_the_flight_that_settled(self):
        self._play()
        self.assertEqual(self._final()['header']['segment'],
                         'B FLIGHT COMPLETE')

    def test_the_sign_off_counts_his_flight_not_the_field(self):
        self._play()
        self.assertIn(' of 3', self._final()['sides'][0]['names'])

    def test_a_flighted_sign_off_names_no_prize_figure(self):
        """The place beside it is this FLIGHT's and `payout` is the ROUND's
        own table, paid over the whole field by `stableford_summary`.
        `1st of 3 · collect $60` reads as the one having produced the other,
        and the case it is worst in is the golfer whose flight place and round
        prize do not correspond at all.

        Reed is the one who collects here — 1st of the whole field — which is
        why she is the reader: a golfer with no round prize would prove
        nothing about the format."""
        self._pay_the_round()
        self._play()
        line = self._final(who='Ann Reed')['sides'][0]['names']
        self.assertIn('collect at the desk', line)
        self.assertNotIn('$', line)

    def test_an_uncut_sign_off_still_names_the_figure(self):
        """Unflighted there is one competition, so the place and the money are
        about the same thing and the figure is worth having."""
        self._pay_the_round()
        self._cut(1)
        self._play()
        self.assertIn('collect $',
                      self._final(who='Ann Reed')['sides'][0]['names'])

    def _pay_the_round(self):
        g = self.round.stableford_config
        g.entry_fee = Decimal('10.00')
        g.payouts = [{'place': 1, 'amount': 60}]
        g.save(update_fields=['entry_fee', 'payouts'])


class RankedPositionsTests(TestCase):
    """The tie rule, as a pure unit — one writer for three numbers (a board's
    display rank, the prize rank beside it, and the place a lock screen
    headlines), two of which are money."""

    def _ranks(self, values):
        from services.flights import ranked_positions
        return ranked_positions([{'v': v} for v in values],
                                lambda r: r['v'])

    def test_ties_share_a_rank_and_the_next_rank_skips(self):
        """A T2 pair is followed by 4th, never 3rd."""
        self.assertEqual(self._ranks([-2, 0, 0, 1]), [1, 2, 2, 4])

    def test_the_unplayed_rows_share_one_rank(self):
        """`None` is the golfer with no holes in. They sort last and compare
        as level with each other, which is what the leaderboard's own walk
        does."""
        self.assertEqual(self._ranks([-1, None, None]), [1, 2, 2])

    def test_everybody_level_shares_first(self):
        self.assertEqual(self._ranks([0, 0, 0]), [1, 1, 1])


class FlightFieldTests(_FlightedBase):

    def _field(self, who=None):
        from services.flights import flight_field
        from services.low_net_round import low_net_round_summary
        rows = low_net_round_summary(self.round)['results']
        return rows, flight_field(
            self.round, rows, self.pid[who] if who else None,
            rank_key=lambda r: r.get('net_to_par'))

    def test_it_does_not_re_rank_the_board_it_is_reading(self):
        """`results` is the leaderboard's own list. The rows are shallow-copied
        before a flight rank is written, so a card cannot rewrite the board."""
        self._play()
        rows, (kept, label) = self._field('Dan Hill')
        self.assertEqual(label, 'B')
        hill = next(r for r in kept if r['player_id'] == self.pid['Dan Hill'])
        self.assertEqual(hill['rank'], 1)
        board = next(r for r in rows
                     if r['player_id'] == self.pid['Dan Hill'])
        self.assertEqual(board['rank'], 4)

    def test_a_casual_round_is_the_same_rows_and_no_label(self):
        from services.flights import flight_field
        self._play()
        casual = make_round(self.tee.course, active_games=[self.GAME])
        rows = [{'player_id': self.pid['Dan Hill'], 'rank': 4,
                 'net_to_par': 0}]
        kept, label = flight_field(casual, rows, self.pid['Dan Hill'],
                                   rank_key=lambda r: r.get('net_to_par'))
        self.assertEqual(label, '')
        self.assertEqual(kept, rows)
