"""
scoring/tests/test_triple_nassau.py
-----------------------------------
Engine tests for services/triple_nassau.py — the round-robin of three 1-v-1
Nassaus.  Covers the two things that differ from a standalone Nassau:

* PAIRWISE handicap allocation — a player gets a different number of strokes
  against each opponent (the pair's low plays to 0, not the field's).
* PER-PLAYER settlement — each player's two matches netted, zero-sum overall.

Gross mode keeps the score math obvious; a strokes-off case proves the
per-pair allocation.
"""
from django.test import TestCase

from services.triple_nassau import (
    setup_triple_nassau, calculate_triple_nassau, triple_nassau_summary,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class TripleNassauTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = 10
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Ann', 0), ('Ben', 5), ('Cal', 15)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.sn = {m.player.name: m.player.short_name
                   for m in self.fs.memberships.select_related('player')}

    def _order(self):
        return [self.pid['Ann'], self.pid['Ben'], self.pid['Cal']]

    def _match(self, s, a, b):
        return next(m for m in s['matches']
                    if {m['player1_id'], m['player2_id']} == {a, b})

    def _gets(self, s, a, b, who):
        m = self._match(s, a, b)
        for t in ('team1', 'team2'):
            for pl in m['match']['teams'][t]:
                if pl['player_id'] == who:
                    return pl['phcp_in_play']
        return None

    # ── Structure ────────────────────────────────────────────────────────────

    def test_setup_creates_three_pairwise_matches(self):
        setup_triple_nassau(self.fs, self._order(),
                            handicap_mode='strokes_off', net_percent=100)
        s = triple_nassau_summary(self.fs)
        assert len(s['matches']) == 3
        A, B, C = self._order()
        pairs = {frozenset((m['player1_id'], m['player2_id'])) for m in s['matches']}
        assert pairs == {frozenset((A, B)), frozenset((A, C)), frozenset((B, C))}
        assert [p['player_id'] for p in s['players']] == [A, B, C]

    # ── Pairwise handicap allocation ─────────────────────────────────────────

    def test_pairwise_strokes_differ_by_opponent(self):
        A, B, C = self._order()
        setup_triple_nassau(self.fs, [A, B, C],
                            handicap_mode='strokes_off', net_percent=100)
        submit_hole(self.fs, 1, [(A, 4), (B, 4), (C, 5)])
        calculate_triple_nassau(self.fs)
        s = triple_nassau_summary(self.fs)
        # Cal (15) gets the pair difference: 15 vs Ann (low 0), 10 vs Ben (low 5).
        assert self._gets(s, A, C, C) == 15, s
        assert self._gets(s, B, C, C) == 10, s
        # Ben (5) gets 5 vs Ann; the lower player in each pair gets 0.
        assert self._gets(s, A, B, B) == 5
        assert self._gets(s, A, B, A) == 0
        assert self._gets(s, B, C, B) == 0

    def test_pairwise_net_index_places_strokes_on_the_pair_low(self):
        # SI 1 hole: Cal nets a stroke against BOTH Ann and Ben (15 & 10 both
        # cover SI 1).  On an SI-15 hole Cal strokes vs Ann (15≥15) but NOT vs
        # Ben (10<15), proving the allocation is per-pair, not field-wide.
        A, B, C = self._order()
        setup_triple_nassau(self.fs, [A, B, C],
                            handicap_mode='strokes_off', net_percent=100)
        # Default tee: hole 5 is SI 1, hole 3 is SI 15.  The summary's per-hole
        # list is built contiguously from hole 1, so score 1–5.
        for h in (1, 2, 3, 4, 5):
            submit_hole(self.fs, h, [(A, 4), (B, 4), (C, 4)])
        calculate_triple_nassau(self.fs)
        s = triple_nassau_summary(self.fs)

        def net(a, b, who, hole):
            m = self._match(s, a, b)
            h = next(x for x in m['match']['holes'] if x['hole'] == hole)
            # 1v1: team1 net = player1, team2 net = player2
            return (h['t1_net'] if m['player1_id'] == who else h['t2_net'])

        # SI 1 (hole 5): Cal strokes in BOTH matches → net 3.
        assert net(A, C, C, 5) == 3, s
        assert net(B, C, C, 5) == 3, s
        # SI 15 (hole 3): Cal strokes vs Ann (gets 15) but not vs Ben (gets 10).
        assert net(A, C, C, 3) == 3, s
        assert net(B, C, C, 3) == 4, s

    # ── Settlement (per-player netting, zero-sum) ────────────────────────────

    def test_gross_round_robin_zero_sum_settlement(self):
        A, B, C = self._order()
        setup_triple_nassau(self.fs, [A, B, C],
                            handicap_mode='gross', net_percent=100,
                            press_mode='none')
        # Ann beats everyone on every hole; Ben beats Cal on every hole.
        for h in range(1, 19):
            submit_hole(self.fs, h, [(A, 3), (B, 4), (C, 5)])
        calculate_triple_nassau(self.fs)
        s = triple_nassau_summary(self.fs)
        nets = {p['short_name']: p['net'] for p in s['players']}
        # Each match sweeps F9+B9+Overall = 3 × $10 = $30.
        # Ann +30 (vs Ben) +30 (vs Cal) = +60; Ben −30 +30 = 0; Cal −30 −30 = −60.
        assert nets[self.sn['Ann']] == 60.0, nets
        assert nets[self.sn['Ben']] == 0.0, nets
        assert nets[self.sn['Cal']] == -60.0, nets
        assert abs(sum(nets.values())) < 1e-9
        assert s['status'] == 'complete'
