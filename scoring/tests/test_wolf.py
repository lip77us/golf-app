"""
scoring/tests/test_wolf.py
--------------------------
Regression tests for services/wolf.py.

Covers the zero-based scoring (lone / blind / partner, with the
non-wolf bonus and wolf-loses-ties options), 3-player Lone splits, the
holes-17/18 last-place-Wolf catch-up rule, and the zero-sum invariant.

Decisions are written directly as WolfHoleDecision rows (mirroring what
the decision endpoint does) and we assert on wolf_summary, which is what
the mobile client consumes.  Gross mode keeps the score math obvious.
"""
from django.test import TestCase

from games.models import WolfGame, WolfHoleDecision
from services.wolf import calculate_wolf, setup_wolf, wolf_summary

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class WolfTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('Alice', 0), ('Bob', 0), ('Carol', 0), ('Dave', 0)],
            tee=self.tee,
        )
        self.pid = {
            m.player.name: m.player_id
            for m in self.fs.memberships.select_related('player')
        }

    # ── helpers ──────────────────────────────────────────────────────────────

    def _order(self, *names):
        return [self.pid[n] for n in names]

    def _setup(self, **kw):
        kw.setdefault('handicap_mode', 'gross')
        kw.setdefault('wolf_order', self._order('Alice', 'Bob', 'Carol', 'Dave'))
        self.game = setup_wolf(self.fs, **kw)
        return self.game

    def _decide(self, hole, decision, partner=None):
        WolfHoleDecision.objects.update_or_create(
            game=self.game, hole_number=hole,
            defaults={'decision': decision, 'partner_id': partner},
        )

    def _points(self, summary):
        return {p['name']: p['points'] for p in summary['players']}

    # ── Lone Wolf ────────────────────────────────────────────────────────────

    def test_lone_wolf_win(self):
        self._setup()
        self._decide(1, 'lone')          # hole 1 Wolf = Alice (order[0])
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3),   # best ball
                                  (self.pid['Bob'],   5),
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        assert pts == {'Alice': 3.0, 'Bob': -1.0, 'Carol': -1.0, 'Dave': -1.0}, pts

    def test_lone_wolf_loss(self):
        self._setup()
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 6),   # Wolf worst
                                  (self.pid['Bob'],   4),
                                  (self.pid['Carol'], 4),
                                  (self.pid['Dave'],  4)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        assert pts == {'Alice': -3.0, 'Bob': 1.0, 'Carol': 1.0, 'Dave': 1.0}, pts

    # ── Partner (2v2) ────────────────────────────────────────────────────────

    def test_partner_side_wins(self):
        self._setup()
        self._decide(1, 'partner', partner=self.pid['Bob'])
        submit_hole(self.fs, 1, [(self.pid['Alice'], 4),   # Wolf side best 4
                                  (self.pid['Bob'],   5),
                                  (self.pid['Carol'], 5),   # opp best 5
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        assert pts == {'Alice': 1.0, 'Bob': 1.0, 'Carol': -1.0, 'Dave': -1.0}, pts

    def test_non_wolf_bonus_doubles_clean_win(self):
        self._setup(non_wolf_bonus=True)
        self._decide(1, 'partner', partner=self.pid['Bob'])
        submit_hole(self.fs, 1, [(self.pid['Alice'], 5),
                                  (self.pid['Bob'],   5),   # Wolf side best 5
                                  (self.pid['Carol'], 3),   # opp best 3 → clean win
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        assert pts == {'Alice': -2.0, 'Bob': -2.0, 'Carol': 2.0, 'Dave': 2.0}, pts

    # ── Blind Wolf ───────────────────────────────────────────────────────────

    def test_blind_wolf_win_uses_bigger_pot(self):
        self._setup()
        self._decide(1, 'blind')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3),
                                  (self.pid['Bob'],   5),
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        assert pts == {'Alice': 6.0, 'Bob': -2.0, 'Carol': -2.0, 'Dave': -2.0}, pts

    # ── Ties ─────────────────────────────────────────────────────────────────

    def test_tie_is_a_push(self):
        self._setup()
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 4),   # Wolf 4
                                  (self.pid['Bob'],   4),   # opp best 4 → tie
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        assert pts == {'Alice': 0.0, 'Bob': 0.0, 'Carol': 0.0, 'Dave': 0.0}, pts

    def test_wolf_loses_ties_option(self):
        self._setup(wolf_loses_ties=True)
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 4),   # Wolf 4
                                  (self.pid['Bob'],   4),   # opp best 4 → tie
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        pts = self._points(wolf_summary(self.fs))
        # Tie awarded to the non-Wolf side: 3 opponents split +3, Wolf −3.
        assert pts == {'Alice': -3.0, 'Bob': 1.0, 'Carol': 1.0, 'Dave': 1.0}, pts

    # ── 3-player Lone (uneven split) ─────────────────────────────────────────

    def test_three_player_lone_split(self):
        fs = make_foursome(
            self.round,
            [('Xan', 0), ('Yi', 0), ('Zed', 0)],
            tee=self.tee, group_number=2,
        )
        pid = {m.player.name: m.player_id
               for m in fs.memberships.select_related('player')}
        setup_wolf(fs, handicap_mode='gross',
                   wolf_order=[pid['Xan'], pid['Yi'], pid['Zed']])
        WolfHoleDecision.objects.create(
            game=fs.wolf_game, hole_number=1, decision='lone')
        submit_hole(fs, 1, [(pid['Xan'], 3), (pid['Yi'], 5), (pid['Zed'], 5)])
        calculate_wolf(fs)
        pts = {p['name']: p['points'] for p in wolf_summary(fs)['players']}
        # Wolf +3; the two opponents split −3 → −1.5 each.
        assert pts == {'Xan': 3.0, 'Yi': -1.5, 'Zed': -1.5}, pts

    # ── Holes 17–18 last-place catch-up ──────────────────────────────────────

    def test_last_place_is_wolf_on_17(self):
        self._setup(last_place_wolf_1718=True)
        # Hole 1: Alice (Wolf) wins lone → Alice +3, others −1.
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3),
                                  (self.pid['Bob'],   5),
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        # Hole 2: Bob (Wolf) loses lone → Bob −3, others +1.  Bob is now last.
        self._decide(2, 'lone')
        submit_hole(self.fs, 2, [(self.pid['Alice'], 4),
                                  (self.pid['Bob'],   6),
                                  (self.pid['Carol'], 4),
                                  (self.pid['Dave'],  4)])
        calculate_wolf(self.fs)
        summary = wolf_summary(self.fs)
        h17 = next(h for h in summary['holes'] if h['hole'] == 17)
        # Plain rotation would give order[16 % 4] = Alice; the catch-up rule
        # overrides it to the last-place player (Bob).
        assert h17['wolf_id'] == self.pid['Bob'], h17

    def test_rotation_unchanged_when_catch_up_disabled(self):
        self._setup(last_place_wolf_1718=False)
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3),
                                  (self.pid['Bob'],   5),
                                  (self.pid['Carol'], 5),
                                  (self.pid['Dave'],  5)])
        calculate_wolf(self.fs)
        summary = wolf_summary(self.fs)
        h17 = next(h for h in summary['holes'] if h['hole'] == 17)
        assert h17['wolf_id'] == self.pid['Alice'], h17  # order[16 % 4]

    # ── Require a Lone/Blind by hole 16 ──────────────────────────────────────

    def test_partner_locks_on_fourth_wolf_turn(self):
        from services.wolf import partner_locked_for_hole, wolf_summary
        self._setup(require_lone_or_blind=True)   # Alice is Wolf on 1,5,9,13
        # First three Wolf turns all partner → never solo.
        for h in (1, 5, 9):
            self._decide(h, 'partner', partner=self.pid['Bob'])
        calculate_wolf(self.fs)
        # Hole 13 (Alice's 4th turn) is now locked to Lone/Blind.
        assert partner_locked_for_hole(self.fs, 13) is True
        # And the summary advertises it so the UI can hide the partner option.
        h13 = next(h for h in wolf_summary(self.fs)['holes'] if h['hole'] == 13)
        assert h13['partner_locked'] is True
        # Earlier turns were never locked.
        assert partner_locked_for_hole(self.fs, 9) is False

    def test_going_solo_satisfies_requirement(self):
        from services.wolf import partner_locked_for_hole
        self._setup(require_lone_or_blind=True)
        self._decide(1, 'lone')                       # satisfied immediately
        self._decide(5, 'partner', partner=self.pid['Bob'])
        self._decide(9, 'partner', partner=self.pid['Bob'])
        calculate_wolf(self.fs)
        assert partner_locked_for_hole(self.fs, 13) is False

    def test_requirement_off_never_locks(self):
        from services.wolf import partner_locked_for_hole
        self._setup(require_lone_or_blind=False)
        for h in (1, 5, 9):
            self._decide(h, 'partner', partner=self.pid['Bob'])
        calculate_wolf(self.fs)
        assert partner_locked_for_hole(self.fs, 13) is False

    # ── Zero-sum invariant ───────────────────────────────────────────────────

    def test_points_and_money_sum_to_zero(self):
        self.round.bet_unit = 2
        self.round.save(update_fields=['bet_unit'])
        self._setup()
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 3), (self.pid['Bob'], 5),
                                  (self.pid['Carol'], 5), (self.pid['Dave'], 5)])
        self._decide(2, 'partner', partner=self.pid['Carol'])  # Wolf = Bob
        submit_hole(self.fs, 2, [(self.pid['Alice'], 4), (self.pid['Bob'], 4),
                                  (self.pid['Carol'], 5), (self.pid['Dave'], 4)])
        calculate_wolf(self.fs)
        summary = wolf_summary(self.fs)
        assert abs(sum(p['points'] for p in summary['players'])) < 1e-9
        assert abs(sum(p['money']  for p in summary['players'])) < 1e-9

    # ── Loss cap ─────────────────────────────────────────────────────────────

    def test_loss_cap_clips_loser_and_stays_zero_sum(self):
        # Lone Wolf loss: Alice −3 pts, the other three +1 each. At $1/pt and a
        # $2 cap, Alice's loss clips to $2 and the winners rescale pro-rata so
        # the table still nets to zero.
        from decimal import Decimal
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['bet_unit'])
        self._setup(loss_cap=Decimal('2'))
        self._decide(1, 'lone')
        submit_hole(self.fs, 1, [(self.pid['Alice'], 6), (self.pid['Bob'], 4),
                                  (self.pid['Carol'], 4), (self.pid['Dave'], 4)])
        calculate_wolf(self.fs)
        summary = wolf_summary(self.fs)
        money = {p['name']: p['money'] for p in summary['players']}
        assert money['Alice'] == -2.0, money            # clipped at the cap
        assert abs(sum(money.values())) < 1e-9          # winners rescaled
        assert summary['money']['loss_cap'] == 2.0

    def test_negative_cap_is_uncapped(self):
        from decimal import Decimal
        game = self._setup(loss_cap=Decimal('-5'))
        assert game.loss_cap is None
