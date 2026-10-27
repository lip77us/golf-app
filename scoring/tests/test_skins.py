"""
scoring/tests/test_skins.py
---------------------------
Regression tests for services/skins.py.

Scenarios cover the main behaviors that have broken (or that we want
to make sure don't): per-hole winner, carryover, no-carryover dead
skins, strokes-off-low, manual junk, gross mode.

Each test sets up a tiny scenario (2–4 players, a few holes) and
asserts on the skins_summary payload, since that's what the mobile
client consumes.
"""
from django.test import TestCase

from games.models import SkinsGame
from services.skins import calculate_skins, setup_skins, skins_summary

from ._helpers import (
    make_foursome,
    make_round,
    make_tee,
    submit_hole,
)


class SkinsTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        # Four players with distinct handicaps so SO and Net produce
        # different stroke allocations.
        self.fs = make_foursome(
            self.round,
            [('Alice', 8), ('Bob', 12), ('Carol', 16), ('Dave', 20)],
            tee=self.tee,
        )
        self.players = list(
            self.fs.memberships.order_by('id').select_related('player')
        )
        # Player IDs by name for readable assertions
        self.pid = {m.player.name: m.player_id for m in self.players}

    # ── Net winner ─────────────────────────────────────────────────────────

    def test_simple_net_winner_takes_one_skin(self):
        """Lowest net score on a hole wins exactly 1 skin, others get 0."""
        setup_skins(self.fs, handicap_mode='net', carryover=True)
        # Hole 1 (SI 7) — Alice (8 hcp, gets 0 strokes on SI 7) makes par,
        # everyone else makes bogey.  Alice should win 1 skin.
        submit_hole(self.fs, 1, [
            (self.pid['Alice'], 4),
            (self.pid['Bob'],   5),
            (self.pid['Carol'], 5),
            (self.pid['Dave'],  5),
        ])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        totals = {p['name']: p['skins_won'] for p in summary['players']}
        assert totals == {'Alice': 1, 'Bob': 0, 'Carol': 0, 'Dave': 0}, totals

    def test_scorecard_prospective_strokes_off_before_any_score(self):
        # The scorecard shows a player's strokes-off stroke holes UP FRONT
        # (before any hole is played), so you can see where strokes fall.
        setup_skins(self.fs, handicap_mode='strokes_off')
        summary = skins_summary(self.fs)   # nothing scored yet

        def stroke_holes(name):
            pid = self.pid[name]
            return [h['hole'] for h in summary['holes']
                    for s in h['scores']
                    if s['player_id'] == pid and s['strokes'] > 0]

        self.assertGreater(len(stroke_holes('Dave')), 0)   # high hcp gets strokes
        self.assertEqual(stroke_holes('Alice'), [])        # low plays to 0
        # Prospective: every gross is still null.
        self.assertTrue(all(s['gross'] is None
                            for h in summary['holes'] for s in h['scores']))

    def test_summary_holes_carry_stroke_index(self):
        # The scorecard grid needs each hole's stroke index so the leaderboard
        # can render an "Index" row (which holes get strokes in strokes-off).
        setup_skins(self.fs, handicap_mode='strokes_off')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 4), (self.pid['Bob'], 5),
                                 (self.pid['Carol'], 5), (self.pid['Dave'], 5)])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        h1 = next(h for h in summary['holes'] if h['hole'] == 1)
        self.assertEqual(h1['stroke_index'], self.tee.hole(1)['stroke_index'])

    # ── Carryover ──────────────────────────────────────────────────────────

    def test_carryover_resolves_with_three_skins_on_winning_hole(self):
        """Two consecutive tied holes carry the pot; the winner of the
        third hole takes all 3 skins at once."""
        setup_skins(self.fs, handicap_mode='gross', carryover=True)
        # Hole 1 (par 4): all par → tie → 1 skin carries
        submit_hole(self.fs, 1, [(self.pid['Alice'], 4),
                                  (self.pid['Bob'],   4),
                                  (self.pid['Carol'], 4),
                                  (self.pid['Dave'],  4)])
        # Hole 2 (par 4): all bogey → tie → 2 skins carry
        submit_hole(self.fs, 2, [(self.pid['Alice'], 5),
                                  (self.pid['Bob'],   5),
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        # Hole 3 (par 3): Alice birdies, others par → Alice takes 3 skins
        submit_hole(self.fs, 3, [(self.pid['Alice'], 2),
                                  (self.pid['Bob'],   3),
                                  (self.pid['Carol'], 3),
                                  (self.pid['Dave'],  3)])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        totals = {p['name']: p['skins_won'] for p in summary['players']}
        assert totals == {'Alice': 3, 'Bob': 0, 'Carol': 0, 'Dave': 0}, totals

    # ── Payout modes (signed net) ──────────────────────────────────────────

    def test_pool_net_is_signed_and_zero_sum(self):
        """Pool mode exposes a signed net (pot share − ante) that sums to 0."""
        setup_skins(self.fs, handicap_mode='gross', carryover=True,
                    payout_style='pool')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3), (self.pid['Bob'], 4),
                                 (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_skins(self.fs)
        s = skins_summary(self.fs)
        nets = {p['name']: p['net'] for p in s['players']}
        assert round(sum(nets.values()), 2) == 0.0, nets
        assert nets['Alice'] > 0, nets
        assert all(nets[n] < 0 for n in ('Bob', 'Carol', 'Dave')), nets

    def test_no_skins_won_yet_is_zero_not_ante_loss(self):
        """In progress with no skin decided (a tie carries): nobody has won the
        pot, so every player nets 0 — not −ante, which would break zero-sum."""
        setup_skins(self.fs, handicap_mode='gross', carryover=True,
                    payout_style='pool')
        # All tied → the skin carries, nothing awarded yet.
        submit_hole(self.fs, 1, [(self.pid['Alice'], 5), (self.pid['Bob'], 5),
                                 (self.pid['Carol'], 5), (self.pid['Dave'], 5)])
        calculate_skins(self.fs)
        s = skins_summary(self.fs)
        nets = {p['name']: p['net'] for p in s['players']}
        assert all(v == 0 for v in nets.values()), nets
        assert round(sum(nets.values()), 2) == 0.0, nets

    def test_per_point_pay_leader(self):
        """Per-skin 'first' — the leader collects the margin from everyone."""
        setup_skins(self.fs, handicap_mode='gross', carryover=True,
                    payout_style='per_point', per_point_mode='first',
                    per_point_rate=5)
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3), (self.pid['Bob'], 4),
                                 (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_skins(self.fs)
        s = skins_summary(self.fs)
        nets = {p['name']: p['net'] for p in s['players']}
        assert round(sum(nets.values()), 2) == 0.0, nets
        # Alice (1 skin) collects $5 from each of the 3 others.
        assert nets['Alice'] == 15.0, nets
        assert nets['Bob'] == nets['Carol'] == nets['Dave'] == -5.0, nets

    def test_no_carryover_dead_skins_on_tie(self):
        """With carryover off, a tied hole simply produces zero skins —
        no one wins anything and the next hole starts fresh at 1 skin."""
        setup_skins(self.fs, handicap_mode='gross', carryover=False)
        # Tied hole 1
        submit_hole(self.fs, 1, [(self.pid['Alice'], 4),
                                  (self.pid['Bob'],   4),
                                  (self.pid['Carol'], 4),
                                  (self.pid['Dave'],  4)])
        # Hole 2: Bob alone makes birdie
        submit_hole(self.fs, 2, [(self.pid['Alice'], 4),
                                  (self.pid['Bob'],   3),
                                  (self.pid['Carol'], 4),
                                  (self.pid['Dave'],  4)])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        totals = {p['name']: p['skins_won'] for p in summary['players']}
        assert totals == {'Alice': 0, 'Bob': 1, 'Carol': 0, 'Dave': 0}, totals

    # ── Strokes-Off-Low ────────────────────────────────────────────────────

    def test_strokes_off_low_player_plays_to_zero(self):
        """In SO mode the foursome low (Alice, 8) plays to scratch.
        SO values: Bob 4, Carol 8, Dave 12.  Hole 13 is SI 10 (par 5):
        Dave is the ONLY player getting a stroke (SI 10 ≤ 12).  All
        four shoot par (5) — Dave nets 4, the others net 5 → Dave wins
        the skin outright."""
        setup_skins(self.fs, handicap_mode='strokes_off', carryover=False)
        submit_hole(self.fs, 13, [(self.pid['Alice'], 5),
                                   (self.pid['Bob'],   5),
                                   (self.pid['Carol'], 5),
                                   (self.pid['Dave'],  5)])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        totals = {p['name']: p['skins_won'] for p in summary['players']}
        assert totals['Dave']  == 1, totals
        assert totals['Alice'] == 0, totals

    # ── Junk skins ─────────────────────────────────────────────────────────

    def test_junk_skins_add_to_total(self):
        """When allow_junk is on, junk counts persisted on a hole add
        to the player's total_skins (separate from regular skins).

        **`junk_types` is named explicitly** so this tests one thing. With
        the defaults it would also pay Alice a birdie — correct, and the
        subject of `JunkTypesTests` below rather than of this.
        """
        from games.models import SkinsPlayerHoleResult
        game = setup_skins(self.fs, handicap_mode='gross',
                           carryover=False, allow_junk=True,
                           junk_types=['sandy'])
        # Hole 1: Alice wins outright + records 2 junk
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3),
                                  (self.pid['Bob'],   4),
                                  (self.pid['Carol'], 4),
                                  (self.pid['Dave'],  4)])
        calculate_skins(self.fs)
        # Manually attach junk to Alice's hole-1 row, mimicking what
        # the junk-entry endpoint does.
        SkinsPlayerHoleResult.objects.update_or_create(
            game=game, player_id=self.pid['Alice'], hole_number=1,
            defaults={'junk_count': 2},
        )
        summary = skins_summary(self.fs)
        alice = next(p for p in summary['players'] if p['name'] == 'Alice')
        assert alice['skins_won']   == 1, alice
        assert alice['junk_skins']  == 2, alice
        assert alice['total_skins'] == 3, alice

    # ── Mid-round withdrawal ────────────────────────────────────────────────

    def _withdraw(self, name, after_hole, *, killed_next=False):
        m = self.fs.memberships.get(player_id=self.pid[name])
        m.withdrew_after_hole       = after_hole
        m.withdrew_killed_next_hole = killed_next
        m.save(update_fields=['withdrew_after_hole', 'withdrew_killed_next_hole'])

    def test_withdrawal_splits_pool_into_segments(self):
        """A WD partitions the round: holes 1–9 (4 players) are one pool,
        holes 11–18 (survivors) another, the abandoned hole 10 evaporates.
        Mirrors the product example: $10/player → $20 over the first 9 holes
        split among 2 skins = $10/skin; survivors play for 8/18 of the pot."""
        self.round.bet_unit = 10
        self.round.save(update_fields=['bet_unit'])
        setup_skins(self.fs, handicap_mode='gross', carryover=False)

        # Segment A (4 players): Alice wins hole 4, Bob wins hole 7.
        submit_hole(self.fs, 4, [(self.pid['Alice'], 3), (self.pid['Bob'], 5),
                                  (self.pid['Carol'], 5), (self.pid['Dave'], 5)])
        submit_hole(self.fs, 7, [(self.pid['Alice'], 4), (self.pid['Bob'], 2),
                                  (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        # Dave hurts his back after hole 9; hole 10 is abandoned.
        self._withdraw('Dave', 9, killed_next=True)
        # Segment B (Alice, Bob, Carol): Carol wins hole 11.
        submit_hole(self.fs, 11, [(self.pid['Alice'], 5), (self.pid['Bob'], 5),
                                   (self.pid['Carol'], 3)])

        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        pay = {p['name']: p['payout'] for p in summary['players']}
        # Segment A (9 holes × 4 players × $10/18 = $20) / 2 skins → $10 each.
        assert pay['Alice'] == 10.0, pay
        assert pay['Bob']   == 10.0, pay
        # Segment B is funded by the THREE remaining players only (the
        # withdrawn player stops contributing): 8 × 3 × $10/18 = $13.33.
        assert pay['Carol'] == 13.33, pay
        # Withdrawn player keeps only what he won before leaving (nothing here).
        assert pay['Dave']  == 0.0, pay
        assert summary['money']['pool'] == 40.0, summary['money']
        assert summary['money']['pool_at_risk'] == 33.33, summary['money']
        killed = [h for h in summary['holes'] if h.get('is_killed')]
        assert [h['hole'] for h in killed] == [10], killed

    def test_lone_survivor_reduces_pool_by_unplayed_fraction(self):
        """2-player skins: when one withdraws the game is over (one player
        can't contest a skin), and only the played fraction of the pool is
        at risk — the rest evaporates."""
        fs = make_foursome(self.round, [('Eve', 10), ('Finn', 10)],
                           tee=self.tee, group_number=2)
        pid = {m.player.name: m.player_id for m in fs.memberships.all()}
        self.round.bet_unit = 10
        self.round.save(update_fields=['bet_unit'])
        setup_skins(fs, handicap_mode='gross', carryover=False)
        # Eve wins holes 1–3 outright.
        for h, par in ((1, 4), (2, 4), (3, 3)):
            submit_hole(fs, h, [(pid['Eve'], par - 1), (pid['Finn'], par)])
        # Finn withdraws after hole 9 → only Eve remains → game over.
        m = fs.memberships.get(player_id=pid['Finn'])
        m.withdrew_after_hole = 9
        m.save(update_fields=['withdrew_after_hole'])

        calculate_skins(fs)
        summary = skins_summary(fs)
        pay = {p['name']: p['payout'] for p in summary['players']}
        # Pool $20; 9/18 in play → $10, all to Eve (3 skins, sole winner).
        assert pay['Eve']  == 10.0, pay
        assert pay['Finn'] == 0.0, pay
        assert summary['money']['pool'] == 20.0, summary['money']
        assert summary['money']['pool_at_risk'] == 10.0, summary['money']

    def test_withdrawal_round_reaches_complete(self):
        """A round with a WD still flips to COMPLETE once every contested
        hole is scored — the withdrawn player's later holes aren't expected
        and the killed hole needs no score."""
        setup_skins(self.fs, handicap_mode='gross', carryover=False)
        self._withdraw('Dave', 9, killed_next=True)
        # Holes 1–9: all four players. Holes 11–18: the three survivors.
        for h in range(1, 10):
            submit_hole(self.fs, h, [(self.pid[n], 4) for n in
                                     ('Alice', 'Bob', 'Carol', 'Dave')])
        for h in range(11, 19):
            submit_hole(self.fs, h, [(self.pid[n], 4) for n in
                                     ('Alice', 'Bob', 'Carol')])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        assert summary['status'] == 'complete', summary['status']

    # ── Gross mode ─────────────────────────────────────────────────────────

    def test_gross_mode_ignores_handicap(self):
        """In gross mode, a high-handicapper's net stroke advantage
        evaporates — only raw scores matter."""
        setup_skins(self.fs, handicap_mode='gross', carryover=False)
        # Hole 5 (SI 1).  Dave (20) would get 2 strokes net.  In gross
        # mode he gets 0.  Alice's bogey beats Dave's double-bogey gross.
        submit_hole(self.fs, 5, [(self.pid['Alice'], 5),
                                  (self.pid['Bob'],   6),
                                  (self.pid['Carol'], 6),
                                  (self.pid['Dave'],  6)])
        calculate_skins(self.fs)
        summary = skins_summary(self.fs)
        totals = {p['name']: p['skins_won'] for p in summary['players']}
        assert totals == {'Alice': 1, 'Bob': 0, 'Carol': 0, 'Dave': 0}, totals


class JunkTypesTests(TestCase):
    """Junk, set up like Spots (`handoff-skins-junk`, 15 Oct 2026).

    **A junk is worth a skin** — one share of the same pot — so these check
    the types reach `total_skins` rather than settling on their own. The
    vocabulary, the greenie carry and the reading of birdies are all
    `services/spot_types.py`, shared with Spots and tested there; what is
    tested here is that junk wires into them and that a junk's worth lands in
    the skins arithmetic.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['skins'])
        self.fs = make_foursome(
            self.round,
            [('Alice', 8), ('Bob', 12), ('Carol', 16), ('Dave', 20)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _game(self, **over):
        over.setdefault('handicap_mode', 'gross')
        over.setdefault('allow_junk', True)
        return setup_skins(self.fs, **over)

    def _junk(self, summary):
        return {p['name']: p['junk_skins'] for p in summary['players']}

    def tick(self, hole, name, *types):
        from services.skins import tally_skins_junk
        tally_skins_junk(self.fs, hole, [{'player_id': self.pid[name],
                                          'types': list(types)}])

    # ── the types ───────────────────────────────────────────────────────────

    def test_a_tick_is_one_junk_and_lands_in_the_total(self):
        self._game(junk_types=['sandy', 'chippy'])
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3), (self.pid['Bob'], 4),
                                 (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_skins(self.fs)
        self.tick(1, 'Bob', 'sandy', 'chippy')
        s = skins_summary(self.fs)
        bob = next(p for p in s['players'] if p['name'] == 'Bob')
        self.assertEqual(bob['junk_skins'], 2)
        self.assertEqual(bob['skins_won'], 0)       # Alice won the hole
        self.assertEqual(bob['total_skins'], 2)

    def test_a_birdie_that_WINS_the_skin_is_a_skin_AND_a_junk(self):
        """The handoff is explicit: skins and junk are independent, so one
        hole can give one golfer several shares."""
        self._game(junk_types=['birdie'])
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3), (self.pid['Bob'], 4),
                                 (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_skins(self.fs)
        s = skins_summary(self.fs)
        alice = next(p for p in s['players'] if p['name'] == 'Alice')
        self.assertEqual(alice['skins_won'], 1)
        self.assertEqual(alice['junk_skins'], 1)
        self.assertEqual(alice['total_skins'], 2)

    def test_junk_OFF_pays_nothing_however_they_scored(self):
        self._game(allow_junk=False, junk_types=['birdie'])
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3), (self.pid['Bob'], 4),
                                 (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_skins(self.fs)
        self.assertEqual(sum(self._junk(skins_summary(self.fs)).values()), 0)

    def test_a_type_not_in_play_cannot_be_ticked(self):
        self._game(junk_types=['sandy'])
        self.tick(1, 'Bob', 'sandy', 'poley')
        self.assertEqual(self._junk(skins_summary(self.fs))['Bob'], 1)

    # ── the greenie, and ITS carry ──────────────────────────────────────────

    def test_a_carried_greenie_is_worth_that_many_JUNK(self):
        """Hole 3 is the fixture's par 3; 7, 12 and 16 follow."""
        from services.skins import pick_skins_greenie
        self._game(junk_types=['greenie'])
        for name in ('Alice', 'Bob', 'Carol', 'Dave'):
            submit_hole(self.fs, 3, [(self.pid[name], 4)])
        pick_skins_greenie(self.fs, 7, self.pid['Bob'])
        submit_hole(self.fs, 7, [(self.pid['Bob'], 3)])      # par, he keeps it
        s = skins_summary(self.fs)
        self.assertEqual(self._junk(s)['Bob'], 2)            # 1 + the carry
        g7 = next(h for h in s['junk_greenie']['holes'] if h['hole'] == 7)
        self.assertEqual((g7['worth'], g7['carried_from']), (2, 3))

    def test_the_skin_carry_and_the_greenie_carry_are_SEPARATE(self):
        """A tied par 3 can carry the skin while somebody takes the greenie.
        Two carries, tracked independently — the handoff says so and it is
        the thing most likely to get quietly fused."""
        from services.skins import pick_skins_greenie
        self._game(junk_types=['greenie'], carryover=True)
        submit_hole(self.fs, 3, [(self.pid['Alice'], 3), (self.pid['Bob'], 3),
                                 (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_skins(self.fs)
        pick_skins_greenie(self.fs, 3, self.pid['Alice'])
        s = skins_summary(self.fs)
        hole3 = next(h for h in s['holes'] if h['hole'] == 3)
        self.assertIsNone(hole3['winner_id'])                # skin tied, carries
        self.assertEqual(self._junk(s)['Alice'], 1)          # greenie taken
        # ...and the NEXT par 3 is back to worth 1, untouched by the skin.
        self.assertEqual(s['junk_greenie']['next']['worth'], 1)

    def test_junk_has_its_OWN_birdie_basis_not_the_skins_handicap(self):
        """Net skins with gross birdies is a valid setup, which is why
        `junk_net_percent` exists beside `net_percent` rather than reusing
        it. Duck-typing the shared engine onto the game row would have
        collided here."""
        g = self._game(handicap_mode='net', net_percent=100,
                       junk_types=['birdie'], junk_birdie_basis='gross')
        self.assertEqual(g.net_percent, 100)
        self.assertEqual(g.junk_birdie_basis, 'gross')
        self.assertEqual(g.junk_net_percent, 100)
        # Dave is off 20 and strokes on every hole: a 5 on a par 4 is a net
        # birdie and a gross bogey. Gross basis pays him nothing.
        submit_hole(self.fs, 1, [(self.pid['Dave'], 5)])
        self.assertEqual(self._junk(skins_summary(self.fs))['Dave'], 0)

    # ── the rounds that were played before junk had names ───────────────────

    def test_a_LEGACY_count_still_counts_and_is_not_rewritten(self):
        """Sixteen of these exist in four completed rounds from May and July
        2026. They were settled against exactly these numbers."""
        from games.models import SkinsPlayerHoleResult
        game = self._game(junk_types=['sandy'])
        SkinsPlayerHoleResult.objects.create(
            game=game, player_id=self.pid['Carol'], hole_number=5,
            junk_count=2)
        s = skins_summary(self.fs)
        self.assertEqual(self._junk(s)['Carol'], 2)
        # It has no name, and the board is not given one to invent.
        entry = next(e for h in s['holes'] if h['hole'] == 5
                     for e in h['junk'] if e['player_id'] == self.pid['Carol'])
        self.assertEqual(entry['count'], 2)
        self.assertEqual(entry['types'], [])

    def test_TICKING_an_old_hole_converts_it_rather_than_adding(self):
        """The two can never be counted together: writing ticks for a golfer
        and hole clears that row's legacy count."""
        from games.models import SkinsPlayerHoleResult
        game = self._game(junk_types=['sandy'])
        SkinsPlayerHoleResult.objects.create(
            game=game, player_id=self.pid['Carol'], hole_number=5,
            junk_count=2)
        self.tick(5, 'Carol', 'sandy')
        self.assertEqual(self._junk(skins_summary(self.fs))['Carol'], 1)
        self.assertFalse(SkinsPlayerHoleResult.objects.filter(
            game=game, player_id=self.pid['Carol'], hole_number=5,
            junk_type__isnull=True).exists())

    def test_an_untouched_hole_of_an_old_round_keeps_its_history(self):
        from games.models import SkinsPlayerHoleResult
        game = self._game(junk_types=['sandy'])
        for hole in (5, 9):
            SkinsPlayerHoleResult.objects.create(
                game=game, player_id=self.pid['Carol'], hole_number=hole,
                junk_count=2)
        self.tick(5, 'Carol', 'sandy')
        self.assertEqual(self._junk(skins_summary(self.fs))['Carol'], 3)


class SkinValidationTests(TestCase):
    """The two rules through the real engine — gross/par lookup and all.

    `services/skin_rules.py` pins the semantics as pure units; what these
    cover is the WIRING: that the engine finds each golfer's gross and the par
    of his own tee, and that "nobody validated" lands on the same carry / kill
    branches a tie does.

    Indexes 0 and 18 on a 113/72 tee mean the scratch player gets no strokes
    and the other gets exactly one on every hole, so a hole's outcome does not
    depend on which stroke index it carries.
    """

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs    = make_foursome(
            self.round, [('Scratch', 0), ('Hack', 18)], tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _won(self):
        calculate_skins(self.fs)
        s = skins_summary(self.fs)
        return {p['name']: p['skins_won'] for p in s['players']}

    # ── one hole, three settings, three answers ────────────────────────────

    def _both_bogey(self):
        """Hole 1 is par 4.  Both shoot 5; Hack's stroke makes it a net par."""
        submit_hole(self.fs, 1, [(self.pid['Scratch'], 5),
                                 (self.pid['Hack'], 5)])

    def test_with_no_minimum_a_net_par_off_a_stroke_wins(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True)
        self._both_bogey()
        self.assertEqual(self._won(), {'Scratch': 0, 'Hack': 1})

    def test_net_par_minimum_still_lets_it_win(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    skin_minimum='net_par')
        self._both_bogey()
        self.assertEqual(self._won(), {'Scratch': 0, 'Hack': 1})

    def test_gross_par_minimum_refuses_it(self):
        """The rule as the user described it: gross 5 is a bogey, so the skin
        is not won and (carryover on) it carries."""
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    skin_minimum='gross_par')
        self._both_bogey()
        self.assertEqual(self._won(), {'Scratch': 0, 'Hack': 0})
        hole1, = [h for h in skins_summary(self.fs)['holes']
                  if h['hole'] == 1]
        self.assertIsNone(hole1['winner_id'])
        self.assertTrue(hole1['is_carry'])

    def test_an_unvalidated_hole_carries_its_skin_onto_the_next(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    skin_minimum='gross_par')
        self._both_bogey()                       # hole 1 unwon, carries
        submit_hole(self.fs, 2, [(self.pid['Scratch'], 4),   # gross par
                                 (self.pid['Hack'], 6)])
        self.assertEqual(self._won(), {'Scratch': 2, 'Hack': 0})

    def test_without_carryover_an_unvalidated_hole_dies(self):
        setup_skins(self.fs, handicap_mode='net', carryover=False,
                    skin_minimum='gross_par')
        self._both_bogey()
        submit_hole(self.fs, 2, [(self.pid['Scratch'], 4),
                                 (self.pid['Hack'], 6)])
        self.assertEqual(self._won(), {'Scratch': 1, 'Hack': 0})

    # ── the steal ──────────────────────────────────────────────────────────

    def _natural_against_a_net_tie(self):
        """Par 4: Scratch makes a real 3; Hack's 4 nets to 3.  Level on net."""
        submit_hole(self.fs, 1, [(self.pid['Scratch'], 3),
                                 (self.pid['Hack'], 4)])

    def test_without_the_steal_the_natural_only_ties(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True)
        self._natural_against_a_net_tie()
        self.assertEqual(self._won(), {'Scratch': 0, 'Hack': 0})

    def test_the_steal_turns_that_tie_into_an_outright_win(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    birdie_steal=True)
        self._natural_against_a_net_tie()
        self.assertEqual(self._won(), {'Scratch': 1, 'Hack': 0})

    def test_the_steal_beats_a_strictly_lower_net(self):
        """Hack nets 2 off his stroke; Scratch's natural birdie takes it."""
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    birdie_steal=True)
        submit_hole(self.fs, 1, [(self.pid['Scratch'], 3),   # natural birdie
                                 (self.pid['Hack'], 3)])     # net 2
        # Both made a natural 3, so the steal filter keeps both and the NET
        # decides — the game is still a net game.
        self.assertEqual(self._won(), {'Scratch': 0, 'Hack': 1})

    def test_a_hole_with_no_natural_is_unaffected_by_the_steal(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    birdie_steal=True)
        self._both_bogey()
        self.assertEqual(self._won(), {'Scratch': 0, 'Hack': 1})

    # ── both at once ───────────────────────────────────────────────────────

    def test_both_rules_together(self):
        setup_skins(self.fs, handicap_mode='net', carryover=True,
                    skin_minimum='gross_par', birdie_steal=True)
        self._natural_against_a_net_tie()
        # The natural clears the gross-par minimum by definition.
        self.assertEqual(self._won(), {'Scratch': 1, 'Hack': 0})

    def test_the_defaults_are_off(self):
        game = setup_skins(self.fs, handicap_mode='net')
        self.assertEqual(game.skin_minimum, 'none')
        self.assertFalse(game.birdie_steal)

    def test_an_unknown_minimum_is_stored_as_none(self):
        """Fails open — a typo must not quietly start voiding skins."""
        game = setup_skins(self.fs, handicap_mode='net',
                           skin_minimum='eagle_or_better')
        self.assertEqual(game.skin_minimum, 'none')
