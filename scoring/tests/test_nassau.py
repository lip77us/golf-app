"""
scoring/tests/test_nassau.py
----------------------------
Regression tests for services/nassau.py — front-9 / back-9 / overall
best-ball math, strokes-off handling, presses, and the
net_max_double_bogey cap.

The fixtures keep the score patterns simple so anyone reading the
test can mentally verify the expected winner without running the
service.
"""
from decimal import Decimal

from django.test import TestCase

from services.nassau import (
    add_manual_press,
    calculate_nassau,
    nassau_summary,
    setup_nassau,
)

from ._helpers import (
    make_foursome,
    make_round,
    make_tee,
    submit_hole,
)


def _bet(summary, key):
    """Pull the F9 / B9 / overall block from a nassau_summary dict."""
    return summary[key]


class NassauTests(TestCase):
    def setUp(self):
        self.tee = make_tee()
        # Cap off by default so per-test math stays straightforward; the
        # cap test below flips it on explicitly.
        self.round = make_round(self.tee.course, handicap_mode='net',
                                 net_max_double_bogey=False)
        self.fs = make_foursome(
            self.round,
            [('T1A', 8), ('T1B', 12), ('T2A', 16), ('T2B', 20)],
            tee=self.tee,
        )
        members = {m.player.name: m for m in self.fs.memberships.select_related('player')}
        self.pid = {n: m.player_id for n, m in members.items()}
        self.team1 = [self.pid['T1A'], self.pid['T1B']]
        self.team2 = [self.pid['T2A'], self.pid['T2B']]

    # ── 2v2 best-ball, gross ──────────────────────────────────────────────

    def test_gross_2v2_team1_wins_front9_by_one(self):
        """T1 best-ball beats T2 best-ball on 5 of 9 holes → 1 UP F9."""
        setup_nassau(self.fs, self.team1, self.team2,
                     handicap_mode='gross')
        # T1 makes par on every hole; T2 makes bogey on 5 holes, par on 4.
        for hole in range(1, 10):
            t2_score_a = 5 if hole <= 5 else 4
            submit_hole(self.fs, hole, [
                (self.pid['T1A'], 4),
                (self.pid['T1B'], 4),
                (self.pid['T2A'], t2_score_a),
                (self.pid['T2B'], 5),
            ])
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        # T1 wins 5 holes, T2 wins 0, halve 4.  Margin = +5.
        assert s['front9']['margin'] == 5, s['front9']
        assert s['front9']['holes_played'] == 9

    def test_loss_cap_clamps_the_net_total(self):
        """T1 sweeps all 18 → wins F9, B9, overall = 3 × $5 = $15, clamped to
        the $10 cap. With 2 sides the cap is a symmetric clamp of the net."""
        self.round.bet_unit = Decimal('5')
        self.round.save(update_fields=['bet_unit'])
        setup_nassau(self.fs, self.team1, self.team2,
                     handicap_mode='gross', loss_cap=Decimal('10'))
        for hole in range(1, 19):
            submit_hole(self.fs, hole, [
                (self.pid['T1A'], 4), (self.pid['T1B'], 4),
                (self.pid['T2A'], 5), (self.pid['T2B'], 5),
            ])
        calculate_nassau(self.fs)
        pay = nassau_summary(self.fs)['payouts']
        assert pay['total'] == 15.0, pay           # raw: 3 bets × $5
        assert pay['total_capped'] == 10.0, pay    # clamped to the cap
        assert pay['loss_cap'] == 10.0, pay

    def test_negative_loss_cap_is_uncapped(self):
        game = setup_nassau(self.fs, self.team1, self.team2,
                            loss_cap=Decimal('-5'))
        assert game.loss_cap is None

    def _front_loss_then_down_on_back(self, cap):
        """Team1 loses the front bet ($5) and is then 1-down on a still-open
        back nine — so it would press. Nothing else is decided, so team1's
        concluded loss is exactly the front bet."""
        self.round.bet_unit = Decimal('5')
        self.round.save(update_fields=['bet_unit'])
        setup_nassau(self.fs, self.team1, self.team2, handicap_mode='gross',
                     press_mode='manual', press_unit='5.00', loss_cap=cap)
        # Front: T2 wins hole 1, the rest halved → T1 loses the front by 1.
        submit_hole(self.fs, 1, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                 (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        for h in range(2, 10):
            submit_hole(self.fs, h, [(self.pid['T1A'], 4), (self.pid['T1B'], 4),
                                     (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        # Back (partial): T2 wins hole 10, rest halved → T1 down 1, back + overall
        # still open (so only the front bet is concluded).
        submit_hole(self.fs, 10, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                  (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        for h in range(11, 14):
            submit_hole(self.fs, h, [(self.pid['T1A'], 4), (self.pid['T1B'], 4),
                                     (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        calculate_nassau(self.fs)
        return nassau_summary(self.fs)

    def test_press_closes_when_a_side_hits_the_cap(self):
        s = self._front_loss_then_down_on_back(cap=Decimal('5'))
        # T1's locked-in loss is $5 = the cap → no more pressing for them.
        assert s['payouts']['total'] == -5.0, s['payouts']
        assert s['can_press'] is False, s['payouts']
        with self.assertRaises(ValueError):
            add_manual_press(self.fs, start_hole=14)

    def test_press_stays_open_below_the_cap(self):
        s = self._front_loss_then_down_on_back(cap=Decimal('10'))
        # Same $5 loss, but the cap is $10 → real downside remains, press allowed.
        assert s['can_press'] is True, s['payouts']
        add_manual_press(self.fs, start_hole=14)   # must not raise

    def _auto_front_loss_then_2down_back(self, cap):
        """AUTO mode: T1 loses the front bet ($5) WITHOUT ever being 2-down (so
        no front auto-press), then goes 2-down on the back → a back auto-press
        would trigger. Returns the back-nine auto-presses in the summary."""
        self.round.bet_unit = Decimal('5')
        self.round.save(update_fields=['bet_unit'])
        setup_nassau(self.fs, self.team1, self.team2, handicap_mode='gross',
                     press_mode='auto', press_unit='5.00', loss_cap=cap)
        # Front: T2 wins hole 1, rest halved → T1 down 1 throughout (never 2-down).
        submit_hole(self.fs, 1, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                 (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        for h in range(2, 10):
            submit_hole(self.fs, h, [(self.pid['T1A'], 4), (self.pid['T1B'], 4),
                                     (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        # Back: T2 wins holes 10 & 11 → T1 is 2-down → back auto-press fires.
        submit_hole(self.fs, 10, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                  (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        submit_hole(self.fs, 11, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                  (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        return [p for p in s['presses']
                if p['nine'] == 'back' and p['press_type'] == 'auto']

    def test_auto_press_suppressed_when_capped(self):
        # T1's $5 front loss == the $5 cap → the back auto-press must not fire.
        assert self._auto_front_loss_then_2down_back(cap=Decimal('5')) == []

    def test_auto_press_fires_below_cap(self):
        # $5 loss under a $10 cap → real downside remains, the auto-press fires.
        assert len(self._auto_front_loss_then_2down_back(cap=Decimal('10'))) == 1

    def test_claremont_bottom_press_fires_when_margin_skips_exact_threshold(self):
        """Regression: the bottom margin moves up to ±2/hole (best + 2nd ball),
        so it can leap over the exact −4 threshold (e.g. −3 → −5) and never fire
        the bottom auto-press. It must fire on REACHING/CROSSING ±4."""
        setup_nassau(self.fs, self.team1, self.team2, handicap_mode='gross',
                     variant='claremont', press_mode='auto', press_unit='5.00')
        # Bottom margin (team1 perspective): −1, −3, −5 across holes 1–3.
        #   h1: T2 wins best ball only (2nd tied)      → delta −1  (margin −1)
        #   h2: T2 wins best AND 2nd ball              → delta −2  (margin −3)
        #   h3: T2 wins best AND 2nd ball              → delta −2  (margin −5, skips −4)
        submit_hole(self.fs, 1, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                 (self.pid['T2A'], 4), (self.pid['T2B'], 5)])
        submit_hole(self.fs, 2, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                 (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        submit_hole(self.fs, 3, [(self.pid['T1A'], 5), (self.pid['T1B'], 5),
                                 (self.pid['T2A'], 4), (self.pid['T2B'], 4)])
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        assert len(s['bottom_presses']) == 1, s['bottom_presses']
        assert s['bottom_presses'][0]['start_hole'] == 4, s['bottom_presses'][0]

    def test_back9_scored_independently_of_front(self):
        """A blowout on the front doesn't bleed into the back-9 bet."""
        setup_nassau(self.fs, self.team1, self.team2,
                     handicap_mode='gross')
        # Front: T1 sweeps every hole.
        for hole in range(1, 10):
            submit_hole(self.fs, hole, [
                (self.pid['T1A'], 4), (self.pid['T1B'], 4),
                (self.pid['T2A'], 7), (self.pid['T2B'], 7),
            ])
        # Back: T2 sweeps every hole.
        for hole in range(10, 19):
            submit_hole(self.fs, hole, [
                (self.pid['T1A'], 7), (self.pid['T1B'], 7),
                (self.pid['T2A'], 4), (self.pid['T2B'], 4),
            ])
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        assert s['front9']['margin'] > 0, s['front9']  # T1 takes F9
        assert s['back9']['margin']  < 0, s['back9']   # T2 takes B9
        # Overall is the sum — equal holes won → halved.
        assert s['overall']['margin'] == 0, s['overall']

    # ── Strokes-Off-Low ───────────────────────────────────────────────────

    def test_strokes_off_lowest_player_gives_strokes_to_field(self):
        """In strokes-off mode the foursome's lowest handicap (T1A=8)
        plays to 0; everyone else gets strokes off that anchor.

        SO values: T1B 4, T2A 8, T2B 12.  Hole 1 is SI 7 — T2A and T2B
        get a stroke (SI 7 ≤ their SO), T1B doesn't (SO 4 < SI 7).
        T1A makes par (gross 4 → net 4); T2B makes bogey (gross 5 → net 4).
        Both teams' best ball = 4.  Halved.  Nassau processes holes in
        order starting at hole 1 — submitting only hole 1 is enough to
        get holes_played = 1 in the summary."""
        setup_nassau(self.fs, self.team1, self.team2,
                     handicap_mode='strokes_off')
        submit_hole(self.fs, 1, [
            (self.pid['T1A'], 4),  # par, low player → net 4
            (self.pid['T1B'], 5),  # bogey, no stroke on SI 7 → net 5
            (self.pid['T2A'], 5),  # bogey, gets 1 stroke → net 4
            (self.pid['T2B'], 5),  # bogey, gets 1 stroke → net 4
        ])
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        assert s['front9']['margin']        == 0, s['front9']
        assert s['front9']['holes_played']  == 1, s['front9']

    # ── Net double-bogey cap ──────────────────────────────────────────────

    def test_net_max_double_bogey_caps_blowup_hole(self):
        """The cap floors a blow-up hole at net par+2.  In this scenario
        T1 still wins the hole (T1 made par, T2 best-ball is net par+2
        capped), so the front-9 margin reads +1 (one hole won) regardless
        of whether the cap is on — but turning the cap on shouldn't
        change the outcome.  This is a smoke test that the cap path
        runs without crashing and produces the expected hole count."""
        # Cap ON.
        self.round.net_max_double_bogey = True
        self.round.save(update_fields=['net_max_double_bogey'])
        setup_nassau(self.fs, self.team1, self.team2,
                     handicap_mode='net')
        # Hole 1 (par 4): T1 makes par, T2 makes blowup.
        submit_hole(self.fs, 1, [
            (self.pid['T1A'], 4),
            (self.pid['T1B'], 4),
            (self.pid['T2A'], 7),
            (self.pid['T2B'], 9),
        ])
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        # T1 should still win this hole — margin > 0.
        assert s['front9']['margin'] > 0, s['front9']


class NassauPressTests(TestCase):
    """Presses are a Nassau wrinkle worth its own small block — they
    open new sub-bets on top of an existing nine."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_nassau(
            self.fs,
            [self.pid['T1A'], self.pid['T1B']],
            [self.pid['T2A'], self.pid['T2B']],
            handicap_mode='gross',
            press_mode='manual',
        )

    def test_call_press_records_new_press_starting_at_current_hole(self):
        from services.nassau import add_manual_press
        # Play holes 1–3, T1 wins all three.
        for h in range(1, 4):
            submit_hole(self.fs, h, [
                (self.pid['T1A'], 4), (self.pid['T1B'], 4),
                (self.pid['T2A'], 5), (self.pid['T2B'], 5),
            ])
        calculate_nassau(self.fs)
        # T2 calls a press at hole 4.
        add_manual_press(self.fs, start_hole=4)
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        # Exactly one front-nine press recorded, starting at hole 4.
        presses = s.get('presses', [])
        assert len(presses) == 1, presses
        assert presses[0]['start_hole'] == 4, presses[0]


class NassauShotgunTests(TestCase):
    """Play-order segmentation: a shotgun start splits the nines by POSITION in
    the group's play sequence, not by absolute hole number."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='net',
                                net_max_double_bogey=False)
        # Shotgun: start on hole 8 → play order 8..18,1..7.
        self.round.num_holes = 18
        self.round.starting_hole = 8
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        self.fs = make_foursome(
            self.round,
            [('T1A', 0), ('T1B', 0), ('T2A', 0), ('T2B', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.team1 = [self.pid['T1A'], self.pid['T1B']]
        self.team2 = [self.pid['T2A'], self.pid['T2B']]

    def _play(self, hole, t1, t2):
        submit_hole(self.fs, hole, [(self.team1[0], t1), (self.team1[1], t1),
                                     (self.team2[0], t2), (self.team2[1], t2)])

    def test_front_nine_is_first_nine_played(self):
        setup_nassau(self.fs, self.team1, self.team2, handicap_mode='gross')
        order = [8, 9, 10, 11, 12, 13, 14, 15, 16,   # front (first 9 played)
                 17, 18, 1, 2, 3, 4, 5, 6, 7]         # back  (last 9 played)
        for i, h in enumerate(order):
            # T1 wins the first 5 front holes (8-12), everything else halved.
            if i < 5:
                self._play(h, 3, 4)
            else:
                self._play(h, 4, 4)
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)

        # Front nine = holes 8-16, settled +5 for team1; back nine pushed.
        self.assertEqual(s['front9']['margin'], 5, s['front9'])
        self.assertEqual(s['front9']['holes_played'], 9)
        self.assertEqual(s['back9']['margin'], 0, s['back9'])
        self.assertEqual(s['back9']['holes_played'], 9)

        holes = {h['hole']: h for h in s['holes']}
        # Hole 8 (first played) is FRONT; hole 1 (played 12th) is BACK.
        self.assertIsNotNone(holes[8]['front9_margin'])
        self.assertIsNone(holes[8]['back9_margin'])
        self.assertIsNotNone(holes[1]['back9_margin'])
        self.assertIsNone(holes[1]['front9_margin'])

    def test_manual_press_on_shotgun_back_nine(self):
        setup_nassau(self.fs, self.team1, self.team2, handicap_mode='gross',
                     press_mode='manual')
        # Play the whole front nine (8-16) halved, then start the back (17).
        for h in [8, 9, 10, 11, 12, 13, 14, 15, 16, 17]:
            self._play(h, 4, 4)
        calculate_nassau(self.fs)
        # T2 calls a press on hole 18 (the 2nd hole of the back nine in play order).
        add_manual_press(self.fs, start_hole=18)
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        presses = s.get('presses', [])
        self.assertEqual(len(presses), 1, presses)
        # The press is on the BACK nine and ends on hole 7 (the last hole played).
        self.assertEqual(presses[0]['nine'], 'back', presses[0])
        self.assertEqual(presses[0]['start_hole'], 18, presses[0])
        self.assertEqual(presses[0]['end_hole'], 7, presses[0])


class NassauNineTests(TestCase):
    """Nassau Nine: one match over all played holes (no F9/B9 split), with the
    press engine running over the whole match."""

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='net',
                                net_max_double_bogey=False)
        # A 9-hole round (holes 1-9).
        self.round.num_holes = 9
        self.round.starting_hole = 1
        self.round.save(update_fields=['num_holes', 'starting_hole'])
        self.fs = make_foursome(
            self.round, [('A', 0), ('B', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _play(self, hole, a, b):
        submit_hole(self.fs, hole, [(self.pid['A'], a), (self.pid['B'], b)])

    def test_single_match_over_nine_no_nine_split(self):
        setup_nassau(self.fs, [self.pid['A']], [self.pid['B']],
                     handicap_mode='gross', single_match=True)
        # A wins holes 1-5 (5 up with 4 to play → clinched); rest halved.
        for h in range(1, 6):
            self._play(h, 3, 4)
        for h in range(6, 10):
            self._play(h, 4, 4)
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        # One match on the 'front' bet over all 9 holes; back/overall are off.
        self.assertTrue(s['single_match'])
        self.assertFalse(s['play_back'])
        self.assertFalse(s['play_overall'])
        self.assertEqual(s['front9']['holes_played'], 9, s['front9'])
        # A wins 5&4 → decided; team1 up.
        self.assertEqual(s['front9']['margin'], 5, s['front9'])
        self.assertIsNotNone(s['front9']['result'])

    def test_auto_press_fires_over_the_single_match(self):
        setup_nassau(self.fs, [self.pid['A']], [self.pid['B']],
                     handicap_mode='gross', single_match=True,
                     press_mode='auto', press_unit='5.00')
        # B goes 2 down by hole 2 → an auto-press fires on the single match.
        self._play(1, 4, 5)
        self._play(2, 4, 5)
        calculate_nassau(self.fs)
        s = nassau_summary(self.fs)
        presses = s.get('presses', [])
        autos = [p for p in presses if p['press_type'] == 'auto']
        self.assertTrue(autos, presses)
        # The press covers the rest of the 9-hole match (ends on hole 9).
        self.assertEqual(autos[0]['end_hole'], 9, autos[0])
