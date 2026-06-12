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
        to the player's total_skins (separate from regular skins)."""
        from games.models import SkinsPlayerHoleResult
        game = setup_skins(self.fs, handicap_mode='gross',
                           carryover=False, allow_junk=True)
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
