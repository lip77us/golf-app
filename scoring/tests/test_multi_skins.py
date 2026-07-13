"""
scoring/tests/test_multi_skins.py
---------------------------------
Regression tests for services/multi_skins.py — round-level skins pool
that crosses foursomes.

Two-foursome setup so the cross-group score comparison is actually
exercised.  Participant roster is explicit (not the union of every
foursome's roster) — a key difference from single-foursome Skins.
"""
from django.test import TestCase

from accounts.models import User
from games.models import MultiSkinsLinkedRound
from services.multi_skins import (
    calculate_multi_skins,
    multi_skins_summary,
    pool_overlap,
    recalc_pools_for_round,
    setup_multi_skins,
)

from ._helpers import (
    _test_account,
    make_foursome,
    make_player,
    make_round,
    make_tee,
    submit_hole,
)


class MultiSkinsTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross',
                                 net_max_double_bogey=False)
        # Two groups of 4 players each.  Distinct hcps so SO would differ
        # from gross if anyone bothered to compute it.
        self.g1 = make_foursome(
            self.round,
            [('A1', 0), ('A2', 8), ('A3', 12), ('A4', 18)],
            tee=self.tee, group_number=1,
        )
        self.g2 = make_foursome(
            self.round,
            [('B1', 0), ('B2', 6), ('B3', 14), ('B4', 20)],
            tee=self.tee, group_number=2,
        )
        self.pid = {}
        for fs in (self.g1, self.g2):
            for m in fs.memberships.select_related('player'):
                self.pid[m.player.name] = m.player_id

    # ── Cross-foursome winner ──────────────────────────────────────────────

    def test_lowest_score_across_groups_wins_the_skin(self):
        """Group 1 A1 makes birdie; everyone else makes par or worse.
        A1 should take the skin even though B1 is in a different group."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['A2'],
                             self.pid['B1'], self.pid['B2']],
            handicap_mode='gross',
        )
        # Hole 1 (par 4): A1 birdie, all others par.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 3),
            (self.pid['A2'], 4),
            (self.pid['A3'], 4),
            (self.pid['A4'], 4),
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 4),
            (self.pid['B2'], 4),
            (self.pid['B3'], 4),
            (self.pid['B4'], 4),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals == {'A1': 1, 'A2': 0, 'B1': 0, 'B2': 0}, totals

    # ── Tie kills the skin ─────────────────────────────────────────────────

    def test_tied_best_score_dies_no_carryover(self):
        """Two participants tie for low → skin dies.  No carryover by
        design — pure design choice baked into the calculator."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['B1']],
            handicap_mode='gross',
        )
        # Hole 1: both par.  Tied for low → no winner.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 4), (self.pid['A2'], 4),
            (self.pid['A3'], 4), (self.pid['A4'], 4),
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 4), (self.pid['B2'], 4),
            (self.pid['B3'], 4), (self.pid['B4'], 4),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals == {'A1': 0, 'B1': 0}, totals
        # Hole appears in the summary as a "dead" entry.
        hole_1 = next(h for h in s['holes'] if h['hole'] == 1)
        assert hole_1['winner_id'] is None
        assert hole_1['is_dead']    is True

    # ── Roster opt-in ──────────────────────────────────────────────────────

    def test_non_participants_dont_affect_winners(self):
        """A3 makes the round's lowest score on a hole but isn't in the
        pool.  The skin goes to the lowest *participant* — even if a
        non-participant beat them."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A2'], self.pid['B2']],
            handicap_mode='gross',
        )
        # Hole 1: A3 (NOT in pool) makes eagle; participants make par.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 4),
            (self.pid['A2'], 4),
            (self.pid['A3'], 2),   # eagle, not a participant
            (self.pid['A4'], 4),
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 4),
            (self.pid['B2'], 4),
            (self.pid['B3'], 4),
            (self.pid['B4'], 4),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        # A2 and B2 both par → tie → dead skin.  Neither gets a skin.
        assert totals == {'A2': 0, 'B2': 0}, totals

    # ── Net handicap mode ──────────────────────────────────────────────────

    def test_net_mode_uses_each_players_strokes(self):
        """Net mode: A4 (18 hcp) gets a stroke on SI 7 (= hole 1).
        With A4 + A1 + B1 in the pool, all three shooting bogey gross
        on hole 1, A4 nets 4 while A1/B1 net 5 → A4 wins."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['A4'],
                             self.pid['B1']],
            handicap_mode='net',
        )
        # Hole 1 (par 4, SI 7).  A4 has 18 strokes → 1 per hole.
        submit_hole(self.g1, 1, [
            (self.pid['A1'], 5),  # bogey, 0 strokes
            (self.pid['A2'], 5),
            (self.pid['A3'], 5),
            (self.pid['A4'], 5),  # bogey, 1 stroke → net 4
        ])
        submit_hole(self.g2, 1, [
            (self.pid['B1'], 5),  # bogey, 0 strokes
            (self.pid['B2'], 5),
            (self.pid['B3'], 5),
            (self.pid['B4'], 5),
        ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals['A4'] == 1, totals
        assert totals['A1'] == 0, totals
        assert totals['B1'] == 0, totals

    # ── Payouts ────────────────────────────────────────────────────────────

    def test_payout_proportional_to_skins_won(self):
        """Pool = bet_unit × participants.  A1 wins 2 of 3 holes,
        B1 wins 1.  Payouts: A1 = 2/3 × pool, B1 = 1/3 × pool."""
        setup_multi_skins(
            self.round,
            participant_ids=[self.pid['A1'], self.pid['B1']],
            handicap_mode='gross',
            bet_unit=10.00,
        )
        # Hole 1 (par 4): A1 birdie, B1 par.   A1 wins.
        # Hole 2 (par 4): A1 par,    B1 birdie. B1 wins.
        # Hole 3 (par 3): A1 par,    B1 bogey. A1 wins.
        for hn, a1, b1 in [(1, 3, 4), (2, 4, 3), (3, 3, 4)]:
            submit_hole(self.g1, hn, [
                (self.pid['A1'], a1), (self.pid['A2'], 4),
                (self.pid['A3'], 4),  (self.pid['A4'], 4),
            ])
            submit_hole(self.g2, hn, [
                (self.pid['B1'], b1), (self.pid['B2'], 4),
                (self.pid['B3'], 4),  (self.pid['B4'], 4),
            ])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        assert s['money']['pool']        == 20.0,  s['money']
        assert s['money']['total_skins'] == 3,     s['money']
        payouts = {p['name']: p['payout'] for p in s['players']}
        # A1: 2/3 × 20 = 13.33;  B1: 1/3 × 20 = 6.67
        assert abs(payouts['A1'] - 13.33) < 0.01, payouts
        assert abs(payouts['B1'] -  6.67) < 0.01, payouts


class MultiSkinsCrossRoundTests(TestCase):
    """A pool hosted on one round, fed by a SEPARATE linked round whose
    players are phone-matched copies of the roster (docs/multi-skins-cross-round.md).
    """
    def setUp(self):
        self.tee    = make_tee()
        self.course = self.tee.course

        # Roster members not in the host round must be on-app (a User carries
        # their phone) for setup to accept them.
        acct = _test_account()
        User.objects.create(username='u_m2', phone='+13105550102', account=acct)
        User.objects.create(username='u_m4', phone='+13105550104', account=acct)

        # Canonical roster.  O plays in the host round; M2/M4 play in a linked
        # round (as phone-matched copies g2/g4 below).
        self.o  = make_player('O',  0);  self.o.phone  = '+13105550100'; self.o.save()
        self.m2 = make_player('M2', 8);  self.m2.phone = '+13105550102'; self.m2.save()
        self.m4 = make_player('M4', 18); self.m4.phone = '+13105550104'; self.m4.save()

        # Host round H: organizer O + a filler not in the pool.
        self.h = make_round(self.course, handicap_mode='gross',
                            net_max_double_bogey=False)
        self.hg = make_foursome(self.h, [(self.o, 0), ('HFill', 5)],
                                tee=self.tee, group_number=1)

        # Guest round G (its own foursome, different Player rows). g2/g4 carry
        # the same phones as M2/M4 → they resolve to those roster members.
        self.g2 = make_player('g2', 8);  self.g2.phone = '+13105550102'; self.g2.save()
        self.g4 = make_player('g4', 18); self.g4.phone = '+13105550104'; self.g4.save()
        self.g = make_round(self.course, handicap_mode='gross',
                            net_max_double_bogey=False)
        self.gg = make_foursome(
            self.g,
            [(self.g2, 8), (self.g4, 18), ('g1', 0), ('g3', 12)],
            tee=self.tee, group_number=1,
        )

        setup_multi_skins(
            self.h,
            participant_ids=[self.o.id, self.m2.id, self.m4.id],
            handicap_mode='gross',
            bet_unit=10.00,
        )
        self.game = self.h.multi_skins_game

    def _link_guest(self):
        MultiSkinsLinkedRound.objects.create(game=self.game, round=self.g)

    def test_overlap_matches_roster_members_by_phone(self):
        """The guest round contributes exactly M2 and M4 (canonical ids),
        matched from g2/g4 by phone — not g1/g3."""
        overlap = pool_overlap(self.game, self.g)
        assert overlap == sorted([self.m2.id, self.m4.id]), overlap

    def test_scores_flow_from_linked_round_into_the_pool(self):
        """O (host round) birdies hole 1; M2/M4 (via g2/g4 in the linked
        round) make par → O takes the skin across rounds."""
        self._link_guest()
        submit_hole(self.hg, 1, [(self.o, 3), (self.pid_h('HFill'), 4)])
        submit_hole(self.gg, 1, [
            (self.g2, 4), (self.g4, 4),
            (self.pid_g('g1'), 4), (self.pid_g('g3'), 4),
        ])
        recalc_pools_for_round(self.g)   # a linked-round score submit path
        s = multi_skins_summary(self.h)
        totals = {p['name']: p['skins_won'] for p in s['players']}
        assert totals == {'O': 1, 'M2': 0, 'M4': 0}, totals
        # Pool spans the 3 roster members regardless of which round they play.
        assert s['money']['pool'] == 30.0, s['money']
        assert set(s['linked_rounds']) == {self.g.id}, s['linked_rounds']

    def test_unlinked_guest_round_contributes_nothing(self):
        """Before the guest round is linked, only the host round's members
        exist for the pool, so no hole can complete (M2/M4 have no source)."""
        submit_hole(self.hg, 1, [(self.o, 3), (self.pid_h('HFill'), 4)])
        submit_hole(self.gg, 1, [
            (self.g2, 4), (self.g4, 4),
            (self.pid_g('g1'), 4), (self.pid_g('g3'), 4),
        ])
        calculate_multi_skins(self.h)
        s = multi_skins_summary(self.h)
        # No hole fully scored (M2/M4 unresolved) → no skins awarded.
        assert all(p['skins_won'] == 0 for p in s['players']), s['players']
        assert s['status'] == 'pending', s['status']

    # small helpers to fetch a member player id by name in each foursome
    def pid_h(self, name):
        return next(m.player_id for m in self.hg.memberships.select_related('player')
                    if m.player.name == name)

    def pid_g(self, name):
        return next(m.player_id for m in self.gg.memberships.select_related('player')
                    if m.player.name == name)


class MultiSkinsParticipantInBothRoundsTests(TestCase):
    """Repro for the reported bug: a pool participant who is a login-less golfer
    placed in the HOST round's foursome (the only way to add a non-Halved player)
    AND also plays in a linked round. Scores entered in the LINKED round must
    still reach the pool."""
    def setUp(self):
        self.tee    = make_tee()
        self.course = self.tee.course

        # Two login-less golfers X, Y (same Player rows used in both rounds).
        self.x = make_player('X', 0)
        self.y = make_player('Y', 0)

        # Host pool round H: the roster (X, Y) sits in H's foursome, because a
        # login-less golfer can only be added to the roster as a host-round member.
        self.h  = make_round(self.course, handicap_mode='gross',
                             net_max_double_bogey=False)
        self.hg = make_foursome(self.h, [(self.x, 0), (self.y, 0)],
                                tee=self.tee, group_number=1)

        # Sixes round G where X and Y actually PLAY (same rows) + two others.
        self.g  = make_round(self.course, handicap_mode='gross',
                             net_max_double_bogey=False, active_games=['sixes'])
        self.gg = make_foursome(
            self.g,
            [(self.x, 0), (self.y, 0), ('G3', 6), ('G4', 12)],
            tee=self.tee, group_number=1,
        )

        setup_multi_skins(self.h, participant_ids=[self.x.id, self.y.id],
                          handicap_mode='gross', bet_unit=10.00)
        self.game = self.h.multi_skins_game
        MultiSkinsLinkedRound.objects.create(game=self.game, round=self.g)

    def test_scores_entered_in_linked_round_reach_the_pool(self):
        # Score hole 1 ONLY in the Sixes round G: X birdie, Y par.
        submit_hole(self.gg, 1, [
            (self.x, 3), (self.y, 4),
            (self.pid_g('G3'), 4), (self.pid_g('G4'), 4),
        ])
        recalc_pools_for_round(self.g)
        s = multi_skins_summary(self.h)
        thru = {p['name']: p['thru'] for p in s['players']}
        skins = {p['name']: p['skins_won'] for p in s['players']}
        # X and Y both played hole 1 in the linked round → thru should be 1,
        # and X (birdie) should take the skin over Y (par).
        assert thru == {'X': 1, 'Y': 1}, thru
        assert skins == {'X': 1, 'Y': 0}, skins

    def pid_g(self, name):
        return next(m.player_id for m in self.gg.memberships.select_related('player')
                    if m.player.name == name)
