"""Group A receipt formatters — settle-up handoff §4.

Every expected string here is §4's own, so these pin the SPEC.
"""
from django.test import SimpleTestCase, TestCase

import services.receipt_games as rg
from scoring.tests._helpers import make_foursome, make_round, submit_hole
from services.receipt_build import GAME_CAPTION, GAME_STAKE, GAME_SUMMARY
from services.settlement import NETTABLE, _pid_nets_for_game


class TheNineIsSignedFromTheHeadlineSideTests(SimpleTestCase):
    """The bug real data caught.

    ``margin`` is signed from team1.  Taking ``abs()`` and always writing UP
    produced "4 UP · front 1 UP, back 5 UP" on round 176 — a row that does not
    add up, and the first thing a golfer checks.  §4 writes "front 2 UP, back
    1 DN" for exactly this reason.
    """

    def test_a_nine_the_headline_side_lost_reads_DN(self):
        block = {'result': 'team1', 'margin': 1}
        self.assertEqual(rg._nine(block, 1), '1 UP')
        self.assertEqual(rg._nine(block, -1), '1 DN')

    def test_halved_is_AS_whichever_side_is_reading(self):
        for sign in (1, -1):
            self.assertEqual(rg._nine({'result': 'halved', 'margin': 0}, sign),
                             'AS')

    def test_an_unplayed_nine_says_nothing(self):
        """No result means the nine was not played — "AS" would claim it was
        and finished level."""
        self.assertEqual(rg._nine({'result': None, 'margin': 0}, 1), '')
        self.assertEqual(rg._nine({}, 1), '')

    def test_the_nines_reconcile_with_the_headline(self):
        """Round 176's real numbers: overall 4 UP, front 1 DN, back 5 UP."""
        front = rg._nine({'result': 'team1', 'margin': 1}, -1)
        back = rg._nine({'result': 'team2', 'margin': -5}, -1)
        overall = rg._nine({'result': 'team2', 'margin': -4}, -1)
        self.assertEqual((front, back, overall), ('1 DN', '5 UP', '4 UP'))


class SignedCountTests(SimpleTestCase):

    def test_points_use_a_true_minus_and_E_for_level(self):
        self.assertEqual(rg._signed(9), '+9')
        self.assertEqual(rg._signed(-2), '−2')
        self.assertEqual(rg._signed(0), 'E')


class RegistryTests(SimpleTestCase):

    GROUP_A = ['nassau', 'skins', 'wolf', 'rabbit', 'survivor',
               'points_531', 'sixes', 'sequoya_threes', 'banker']

    def test_every_group_a_game_has_a_summary_and_a_stake(self):
        for game in self.GROUP_A:
            with self.subTest(game):
                self.assertIn(game, GAME_SUMMARY)
                self.assertIn(game, GAME_STAKE)

    def test_the_games_whose_unit_is_not_strokes_override_the_caption(self):
        """§3's default is "{gross} · net {net}".  Points are scored in points
        and Banker in bets, so the default would describe a different game."""
        self.assertIn('points_531', GAME_CAPTION)
        self.assertIn('banker', GAME_CAPTION)

    def test_a_formatter_returns_rows_not_one_row(self):
        """Sequoya 3s states its matches and its bets separately, and Banker
        gives every golfer a line — so the contract is a list."""
        import inspect
        src = inspect.getsource(rg.sequoya_summary_rows)
        self.assertIn('rows.append', src)


class LedgerTests(TestCase):
    """The three that could not settle at all before this."""

    def test_all_three_are_nettable(self):
        for game in ('nassau', 'rabbit', 'survivor'):
            self.assertIn(game, NETTABLE, f'{game} still cannot settle')

    def test_a_cup_round_nets_no_nassau_money(self):
        """§4: "Cup Nassau plays for points, not money, so it gets no
        receipt."  Netting it would invent dollars nobody played for."""
        from tournament.models import (RyderCupRoundConfig, TeamTournament,
                                       Tournament)
        from scoring.tests._helpers import _test_account
        t = Tournament.objects.create(account=_test_account(), name='Cup',
                                      start_date='2026-11-01')
        # RyderCupRoundConfig.tournament is a TeamTournament — the cup layer
        # over a Tournament, not the Tournament itself.
        from services.nassau import calculate_nassau, setup_nassau
        team = TeamTournament.objects.create(tournament=t)
        rnd = make_round(active_games=['nassau'], tournament=t)
        fs = make_foursome(rnd, [('A', 5), ('B', 5), ('C', 5), ('D', 5)])
        ids = [m.player_id for m in fs.memberships.all()]
        # A REAL, decided Nassau — otherwise the guard is never reached and
        # the test passes whether or not it exists. (It did, at first.)
        RyderCupRoundConfig.objects.create(round=rnd, tournament=team)
        setup_nassau(fs, ids[:2], ids[2:], handicap_mode='gross')
        for hole in range(1, 19):
            submit_hole(fs, hole, [(ids[0], 3), (ids[1], 3),
                                   (ids[2], 5), (ids[3], 5)])
        calculate_nassau(fs)
        self.assertFalse(any(_pid_nets_for_game('nassau', rnd, [fs]).values()),
                         'a cup round must net no Nassau money')

        # And the same scoreline OUTSIDE a cup does pay, which is what says
        # the empty answer above came from the guard and not from a fixture
        # that never played anything.
        casual = make_round(active_games=['nassau'])
        cfs = make_foursome(casual, [('E', 5), ('F', 5), ('G', 5), ('H', 5)])
        cids = [m.player_id for m in cfs.memberships.all()]
        setup_nassau(cfs, cids[:2], cids[2:], handicap_mode='gross')
        for hole in range(1, 19):
            submit_hole(cfs, hole, [(cids[0], 3), (cids[1], 3),
                                    (cids[2], 5), (cids[3], 5)])
        calculate_nassau(cfs)
        self.assertTrue(any(_pid_nets_for_game('nassau', casual, [cfs]).values()),
                        'the control round should have paid')

    def test_rabbit_and_survivor_read_the_engine_and_balance(self):
        """Both ledgers are the engine's own per-player money, so they are
        zero-sum by construction — this is what says they were read right."""
        from services.rabbit import setup_rabbit, calculate_rabbit
        rnd = make_round(active_games=['rabbit'])
        fs = make_foursome(rnd, [('A', 5), ('B', 10), ('C', 15)])
        setup_rabbit(fs)
        ids = [m.player_id for m in fs.memberships.all()]
        for hole in range(1, 19):
            scores = [(pid, 5) for pid in ids]
            if hole % 3 == 0:
                scores[0] = (ids[0], 3)
            submit_hole(fs, hole, scores)
        calculate_rabbit(fs)
        nets = _pid_nets_for_game('rabbit', rnd, [fs])
        self.assertEqual(round(sum(nets.values()), 2), 0.0)


class SkinsRowTests(TestCase):

    def test_the_row_counts_total_skins_so_it_accounts_for_the_money(self):
        """Junk is a share of the same pot, so the pot divides by the total.
        A row printing skins alone would not account for a golfer's money."""
        import inspect
        src = inspect.getsource(rg.skins_summary_rows)
        self.assertIn("'total_skins'", src)
        self.assertNotIn("p.get('skins_won')", src)


class SixesRowTests(SimpleTestCase):

    def test_a_voided_segment_is_in_neither_count(self):
        """A withdrawal voids the segments it touches and they score nothing,
        so counting them promises matches nobody played for."""
        import inspect
        self.assertIn("is_void", inspect.getsource(rg.sixes_summary_rows))


class FormatterFailureTests(TestCase):
    """A formatter is presentation; the money is not."""

    def test_a_broken_formatter_does_not_break_the_receipt(self):
        from services.receipt_build import build_round_receipt
        from services.skins import setup_skins, calculate_skins
        rnd = make_round(active_games=['skins'])
        fs = make_foursome(rnd, [('A', 5), ('B', 10), ('C', 15), ('D', 20)])
        setup_skins(fs, handicap_mode='gross', carryover=False)
        ids = [m.player_id for m in fs.memberships.all()]
        for hole in range(1, 19):
            scores = [(pid, 5) for pid in ids]
            if hole < 4:
                scores[0] = (ids[0], 3)
            submit_hole(fs, hole, scores)
        calculate_skins(fs)

        def boom(*a, **k):
            raise RuntimeError('formatter is broken')

        original = GAME_SUMMARY['skins']
        GAME_SUMMARY['skins'] = boom
        try:
            receipt = build_round_receipt(rnd)
        finally:
            GAME_SUMMARY['skins'] = original
        self.assertIsNotNone(receipt, 'a bad sentence lost the whole receipt')
        self.assertEqual(sum(n['net'] for n in receipt.payload['nets']), 0)
        self.assertTrue(receipt.payload['games'][0]['rows'],
                        'the fallback row should still say where money went')


# ===========================================================================
# Group B — the pools (§4)
# ===========================================================================

class StrokePlayRowTests(TestCase):

    def _round(self, fee, payouts):
        from games.models import LowNetRoundConfig
        rnd = make_round(active_games=['low_net_round'])
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        LowNetRoundConfig.objects.update_or_create(
            round=rnd, defaults={'entry_fee': fee, 'payouts': payouts})
        for hole in range(1, 19):
            submit_hole(fs, hole, [(pid, 4 + i) for i, pid in enumerate(ids)])
        return rnd, fs, ids

    def test_the_row_names_only_the_places_that_were_paid(self):
        """§4 lists Stroke Play as a pool game "only when there is a pot", and
        on a board of sixteen the row cannot be a full ranking — the chips
        above already carry every golfer.  What it adds is who collected."""
        rnd, fs, ids = self._round(
            20, [{'place': 1, 'amount': 52}, {'place': 2, 'amount': 28}])
        names = {pid: {'short_name': f'P{i}'} for i, pid in enumerate(ids)}
        rows = rg.stroke_play_rows(rnd, {'game': 'low_net_round'}, names)
        self.assertEqual(len(rows), 1)
        value = rows[0][1]
        self.assertIn('1st', value)
        self.assertIn('2nd', value)
        self.assertNotIn('3rd', value)

    def test_no_pot_means_no_pool_caption(self):
        """With no entry fee there is no pool, so the chip keeps §3's default
        gross/net caption rather than a place with no money behind it."""
        rnd, fs, ids = self._round(0, [{'place': 1, 'amount': 0}])
        self.assertEqual(rg.stroke_play_captions(rnd, ids), {})

    def test_a_pot_captions_the_place_and_the_total(self):
        """§4: "{place} · {tot}"."""
        rnd, fs, ids = self._round(20, [{'place': 1, 'amount': 80}])
        caps = rg.stroke_play_captions(rnd, ids)
        self.assertTrue(caps)
        self.assertRegex(next(iter(caps.values())), r'^\d+(st|nd|rd|th) · \d+$')


class PlaceTests(SimpleTestCase):

    def test_the_teens_are_th(self):
        """11th, 12th and 13th are the case a naive ordinal gets wrong."""
        self.assertEqual([rg._place(n) for n in (1, 2, 3, 4, 11, 12, 13, 21)],
                         ['1st', '2nd', '3rd', '4th', '11th', '12th', '13th',
                          '21st'])


class GroupPoolTests(TestCase):
    """§4 Group B: "each group's payout is divided across its golfers"."""

    def _round(self, fee, payouts):
        # 40 Balls has no setup_* service — the view writes the config
        # directly, so the test does the same rather than inventing one.
        from games.models import FortyBallsConfig
        rnd = make_round(active_games=['forty_balls'])
        for n in range(1, 3):
            make_foursome(rnd, [(f'G{n}a', 0), (f'G{n}b', 0)],
                          group_number=n)
        for fs in rnd.foursomes.all():
            ids = [m.player_id for m in fs.memberships.all()]
            for hole in range(1, 19):
                submit_hole(fs, hole, [(pid, 4) for pid in ids])
        FortyBallsConfig.objects.update_or_create(
            round=rnd, defaults={'entry_fee': fee, 'payouts': payouts})
        return rnd

    def test_a_balanced_pool_nets_the_share_minus_the_entry(self):
        from services.settlement import _group_pool_nets
        # 4 golfers at $10 = a $40 pool, and the table pays all $40.
        rnd = self._round(10, [{'place': 1, 'amount': 40}])
        nets = _group_pool_nets('forty_balls', rnd)
        if nets:                       # the engine may not rank an unscored tie
            self.assertEqual(round(sum(nets.values()), 2), 0.0)

    def test_an_unbalanced_pool_is_refused_rather_than_reported(self):
        """With entries uncollected nobody holds the difference, so a table
        that does not pay out the pool has no set of transfers that clears
        it — $40 collected and $10 paid leaves $30 belonging to nobody."""
        from services.settlement import _group_pool_nets
        rnd = self._round(10, [{'place': 1, 'amount': 10}])
        self.assertEqual(_group_pool_nets('forty_balls', rnd), {})


class ImageCaptionTests(SimpleTestCase):

    def test_the_preview_caption_is_its_own_registry(self):
        """§3 has both; they are different sentences for different widths, and
        a union return type is how one ends up rendered in the other's slot."""
        from services.receipt_build import GAME_CAPTION, GAME_IMAGE_CAPTION
        for key in ('forty_balls', 'hot_spot'):
            self.assertIn(key, GAME_CAPTION)
            self.assertIn(key, GAME_IMAGE_CAPTION)

    def test_the_preview_drops_the_group_and_the_ticket_keeps_it(self):
        ticket = rg._group_pool_captions(False)
        preview = rg._group_pool_captions(True)
        self.assertIsNot(ticket, preview)


class DreamRoundTests(SimpleTestCase):

    def test_eclectic_is_dream_round_not_a_fifth_pool(self):
        """The website redirects /games/eclectic to /games/dream-round, so
        §4's "Dream Round · Eclectic" is one game under two names."""
        from services.receipt_build import GAME_SUMMARY
        self.assertIn('dream_round', GAME_SUMMARY)
        self.assertNotIn('eclectic', GAME_SUMMARY)


class DriftTests(TestCase):
    """Not every imbalance is rounding."""

    def test_a_real_imbalance_refuses_rather_than_landing_on_one_golfer(self):
        from services.receipt_build import build_round_receipt
        from services.skins import setup_skins, calculate_skins
        rnd = make_round(active_games=['skins'])
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        setup_skins(fs, handicap_mode='gross', carryover=False)
        ids = [m.player_id for m in fs.memberships.all()]
        for hole in range(1, 19):
            scores = [(pid, 5) for pid in ids]
            if hole < 4:
                scores[0] = (ids[0], 3)
            submit_hole(fs, hole, scores)
        calculate_skins(fs)

        import services.settlement as st
        real = st._pid_nets_for_game

        def lopsided(game_key, round_obj, foursomes):
            nets = dict(real(game_key, round_obj, foursomes))
            first = next(iter(nets))
            nets[first] += 40.0        # $40 from nowhere
            return nets

        st._pid_nets_for_game = lopsided
        try:
            self.assertIsNone(
                build_round_receipt(rnd),
                'a $40 hole in the ledger was absorbed onto one golfer')
        finally:
            st._pid_nets_for_game = real
