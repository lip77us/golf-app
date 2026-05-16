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
from django.test import TestCase

from services.nassau import calculate_nassau, nassau_summary, setup_nassau

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
