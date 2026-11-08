"""Group A receipt formatters — settle-up handoff §4.

Every expected string here is §4's own, so these pin the SPEC.
"""
from django.test import SimpleTestCase, TestCase

import services.receipt_games as rg
from scoring.tests._helpers import make_foursome, make_round, submit_hole
from services.receipt_build import (
    GAME_CAPTION,
    GAME_DETAIL,
    GAME_STAKE,
    GAME_SUMMARY,
    build_round_receipt,
)
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


class SixesDetailTests(TestCase):
    """§4: "Detail: one row per match: `1 · holes 1–6`, `Kim/Reid 2 UP`."

    The summary row answers a different question on purpose — "Settled 3 of
    3", which is right for a ticket one column wide.  Who won which match,
    and against whom, is the long form, and §1 puts the long form on the web
    receipt alone.

    The fixture ends match 1 EARLY, because that is the case the stored hole
    range gets wrong: a match won 3&2 stores 1–6 and played 1–4, and the next
    match starts on the 5th.
    """

    def setUp(self):
        from services.sixes import setup_sixes
        self.round = make_round(active_games=['sixes'])
        self.round.primary_game = 'sixes'
        self.round.bet_unit = 5
        self.round.save(update_fields=['primary_game', 'bet_unit'])
        self.fs = make_foursome(
            self.round, [('Paul', 0), ('Sam', 0), ('Dave', 0), ('Lee', 0)])
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        pairs = [
            ([self.pid['Paul'], self.pid['Dave']], [self.pid['Sam'], self.pid['Lee']]),
            ([self.pid['Paul'], self.pid['Sam']], [self.pid['Dave'], self.pid['Lee']]),
            ([self.pid['Paul'], self.pid['Lee']], [self.pid['Dave'], self.pid['Sam']]),
        ]
        setup_sixes(self.fs, [
            {'team_select_method': 'long_drive',
             'start_hole': 1 + i * 6, 'end_hole': (i + 1) * 6,
             'team1_player_ids': a, 'team2_player_ids': b}
            for i, (a, b) in enumerate(pairs)], handicap_mode='gross')

    def _hole(self, h, paul, sam, dave, lee):
        submit_hole(self.fs, h, [
            (self.pid['Paul'], paul), (self.pid['Sam'], sam),
            (self.pid['Dave'], dave), (self.pid['Lee'], lee)])

    def _play(self):
        """Match 1 won 3&2 on the 4th; everything after it halved."""
        from services.sixes import calculate_sixes
        self._hole(1, 4, 4, 4, 4)
        for h in (2, 3, 4):
            self._hole(h, 4, 5, 4, 5)        # Paul & Dave
        for h in range(5, 19):
            self._hole(h, 4, 4, 4, 4)
        calculate_sixes(self.fs)

    def _rows(self):
        self._play()
        secs = rg.sixes_detail(self.round, {'game': 'sixes'}, {})
        self.assertEqual(len(secs), 1)
        self.assertEqual(secs[0]['label'], 'Sixes · the matches')
        return secs[0]['rows']

    def test_it_is_registered(self):
        self.assertIn('sixes', GAME_DETAIL)

    def test_one_row_per_match(self):
        rows = self._rows()
        from games.models import SixesSegment
        self.assertEqual(len(rows),
                         SixesSegment.objects.filter(foursome=self.fs).count())

    def test_the_row_names_the_holes_the_match_PLAYED(self):
        # The bug this guards: match 1 stores 1-6 and played 1-4, so the
        # stored range would claim two holes for a match already over — and
        # would overlap match 2, which starts on the 5th.
        rows = self._rows()
        self.assertEqual(rows[0][0], '1 · holes 1–4')
        self.assertTrue(rows[1][0].startswith('2 · holes 5–'), rows[1][0])

    def test_it_says_who_won_and_by_how_much(self):
        rows = self._rows()
        # Partners are joined with `&`, and the names are `short_name` — which
        # auto-fills to initials here.  That is the Sixes convention for a
        # side (match lines are read at arm's length), not this formatter's
        # invention, and it is why the handoff's `Kim/Reid` is not copied
        # literally: every other surface in the app says "Paul & Jim".
        self.assertEqual(rows[0][1], 'P & D won 3&2')

    def test_a_halved_match_says_so(self):
        rows = self._rows()
        self.assertIn('Halved', [r[1] for r in rows[1:]])

    def test_the_extra_match_is_marked(self):
        # Match 1's two unplayed holes become an extra, which is a real match
        # for real money but exists only because an earlier one ended early.
        rows = self._rows()
        self.assertTrue(any(' Ex · ' in r[0] for r in rows),
                        f'no extra match marked: {[r[0] for r in rows]}')

    # ── the wiring: §1 puts it on the web receipt and nowhere else ────────

    def test_the_receipt_carries_it_as_webGames(self):
        self._play()
        r = build_round_receipt(self.round)
        labels = [s['label'] for s in r.payload['webGames']]
        # §3: webGames REPLACES games on the web, so it leads with the short
        # form rather than holding only the extra sections.
        self.assertEqual(labels[0], 'The games')
        self.assertIn('Sixes · the matches', labels)

    def test_the_ticket_and_the_image_keep_the_short_form(self):
        self._play()
        r = build_round_receipt(self.round)
        self.assertEqual([s['label'] for s in r.payload['games']],
                         ['The games'])
        value = r.payload['games'][0]['rows'][0][1]
        self.assertTrue(value.startswith('Settled '), value)

    def test_a_game_with_no_detail_formatter_sets_no_webGames(self):
        """An unregistered game has no useful generic detail, so it gets no
        section — and a `webGames` identical to `games` is noise in a stored
        payload, which the renderer already falls back from.

        It un-registers the formatter rather than naming a game that happens
        to lack one: the first version used Rabbit, Rabbit got one, and the
        test started failing for a reason that was not a regression.  (Its
        own guard said so, which is why it is written that way here too.)
        """
        from services import receipt_build as rb
        self._play()
        saved = rb.GAME_DETAIL.pop('sixes')
        try:
            r = build_round_receipt(self.round)
            self.assertIsNotNone(r)
            self.assertNotIn('webGames', r.payload)
        finally:
            rb.GAME_DETAIL['sixes'] = saved


def _settled_round(game):
    """The smallest real, settled round of `game` — engines, not stubs."""
    rnd = make_round(active_games=[game])
    rnd.bet_unit = 2
    rnd.save(update_fields=['bet_unit'])
    if game == 'nassau':
        from services.nassau import calculate_nassau, setup_nassau
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        setup_nassau(fs, ids[:2], ids[2:], handicap_mode='gross')
        for h in range(1, 19):
            submit_hole(fs, h, [(ids[0], 3), (ids[1], 3),
                                (ids[2], 5), (ids[3], 5)])
        calculate_nassau(fs)
    elif game == 'skins':
        from services.skins import calculate_skins, setup_skins
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0)])
        setup_skins(fs, handicap_mode='gross', carryover=True)
        ids = [m.player_id for m in fs.memberships.all()]
        for h in range(1, 19):
            sc = [(pid, 5) for pid in ids]
            if h in (3, 7):
                sc[0] = (ids[0], 3)
            submit_hole(fs, h, sc)
        calculate_skins(fs)
    elif game in ('rabbit', 'survivor'):
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        if game == 'rabbit':
            from services.rabbit import calculate_rabbit, setup_rabbit
            setup_rabbit(fs, num_segments=3, extra_rabbits=True)
        else:
            from services.survivor import calculate_survivor, setup_survivor
            setup_survivor(fs, handicap_mode='gross', zombie_option=False)
        for h in range(1, 19):
            sc = [(pid, 5) for pid in ids]
            # A wins the first five outright, which decides the opening
            # stretch EARLY and frees its remaining holes into an extra —
            # the case the `Ex` label exists for.  After that the win
            # rotates, so later stretches run their full length.
            sc[0 if h <= 5 else h % 3] = (ids[0 if h <= 5 else h % 3], 3)
            submit_hole(fs, h, sc)
        calculate_rabbit(fs) if game == 'rabbit' else calculate_survivor(fs)
    elif game == 'wolf':
        # A wolf hole needs a DECISION as well as scores — without one there
        # is no side, so the summary reports no result and the detail has
        # nothing to say.
        from games.models import WolfHoleDecision
        from services.wolf import calculate_wolf, setup_wolf
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        game_row = setup_wolf(fs, handicap_mode='gross', wolf_order=ids)
        for h in range(1, 19):
            WolfHoleDecision.objects.update_or_create(
                game=game_row, hole_number=h,
                defaults={'decision': 'lone' if h % 3 == 0 else 'partner',
                          'partner_id': None if h % 3 == 0
                          else ids[(h % 4 + 1) % 4]})
            submit_hole(fs, h, [(pid, 4 + (i == h % 4))
                                for i, pid in enumerate(ids)])
        calculate_wolf(fs)
    elif game == 'points_531':
        from services.points_531 import (calculate_points_531,
                                         setup_points_531)
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        setup_points_531(fs, handicap_mode='gross')
        for h in range(1, 19):
            submit_hole(fs, h, [(ids[0], 3), (ids[1], 4), (ids[2], 5)])
        calculate_points_531(fs)
    elif game == 'low_net_round':
        # Stroke Play has no `setup_*`; its config IS the row.
        from games.models import LowNetRoundConfig
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        LowNetRoundConfig.objects.create(
            round=rnd, handicap_mode='gross', entry_fee=10,
            payouts=[{'place': 1, 'amount': 30}])
        for h in range(1, 19):
            submit_hole(fs, h, [(ids[0], 3), (ids[1], 4), (ids[2], 5)])
    elif game == 'sequoya_threes':
        from services.sequoya_threes import setup_sequoya_threes
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        setup_sequoya_threes(fs, ids[:2], handicap_mode='gross')
        for h in range(1, 19):
            submit_hole(fs, h, [(ids[0], 3), (ids[1], 4),
                                (ids[2], 4), (ids[3], 5)])
    elif game == 'banker':
        # Setup plus scores is enough for the SHAPE: with no bets placed the
        # banking and betting columns are zero, which is a legitimate round
        # and still exercises every row the formatter writes.
        from services.banker import setup_banker
        fs = make_foursome(rnd, [('A', 0), ('B', 0), ('C', 0), ('D', 0)])
        ids = [m.player_id for m in fs.memberships.all()]
        setup_banker(fs, first_banker_id=ids[0], handicap_mode='gross')
        for h in range(1, 19):
            submit_hole(fs, h, [(ids[0], 3), (ids[1], 4),
                                (ids[2], 4), (ids[3], 5)])
    else:
        raise AssertionError(f'no fixture for {game}')
    return rnd


class DetailShapeTests(TestCase):
    """The contract every detail section has to meet, swept across the lot.

    **`_detail_sections` swallows a formatter's exception by design** — the
    money is already settled above it and a broken row must not cost the
    receipt.  The cost is that a regression is SILENT: the section simply
    stops appearing.  So these call the formatters DIRECTLY, where a raise is
    a failure rather than a missing row.

    Found exactly that way: Rabbit and Survivor report `holes` as a COUNT and
    both formatters read it as a list, which is a TypeError, which was a
    logged line and an empty section.
    """

    def test_every_registered_formatter_returns_well_formed_sections(self):
        for game in sorted(GAME_DETAIL):
            if game == 'sixes':
                continue            # SixesDetailTests covers it in full
            with self.subTest(game):
                rnd = _settled_round(game)
                # Direct, so a raise fails here rather than being logged away.
                secs = GAME_DETAIL[game](rnd, {'game': game}, {})
                self.assertTrue(secs, f'{game} produced no section')
                for sec in secs:
                    self.assertTrue(sec['label'])
                    self.assertTrue(sec['rows'], f'{game}: empty section')
                    for row in sec['rows']:
                        # The renderers unpack `label, value` — anything else
                        # is a ValueError on a page somebody is reading.
                        self.assertEqual(len(row), 2, f'{game}: {row}')
                        self.assertTrue(all(isinstance(c, str) for c in row),
                                        f'{game}: {row}')
                        self.assertTrue(row[0], f'{game}: unlabelled {row}')

    def test_a_count_is_never_read_as_a_list_of_holes(self):
        """Rabbit and Survivor report `holes` as an int.  Both formatters
        read `start_hole`/`end_hole` instead, and this is what says so."""
        for game in ('rabbit', 'survivor'):
            with self.subTest(game):
                rnd = _settled_round(game)
                rows = GAME_DETAIL[game](rnd, {'game': game}, {})[0]['rows']
                self.assertTrue(any('–' in r[0] for r in rows),
                                f'{game} named no hole window: {rows}')


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


class DetailContentTests(TestCase):
    """What each row SAYS.  The sweep above only proves a formatter returns
    well-formed rows; these say the rows are right.

    A separate class rather than a subclass — one that inherited the sweep
    would re-run it against a fixture it was not written for, which is the
    `_DayBetBase` lesson.
    """

    def _rows(self, game):
        rnd = _settled_round(game)
        return GAME_DETAIL[game](rnd, {'game': game}, {})[0]['rows']

    def test_nassau_names_the_side_and_uses_the_close_out_notation(self):
        """§4: N UP / N&M / AS, one row each for Front, Back and Overall.

        A & B win every hole, so all three close out early and none of them
        can read `N UP` — which is what says the `&M` branch is live.
        """
        rows = dict(self._rows('nassau'))
        self.assertEqual(sorted(rows), ['Back', 'Front', 'Overall'])
        for label, text in rows.items():
            self.assertTrue(text.startswith('A & B '), f'{label}: {text}')
            self.assertIn('&', text.split(' ', 2)[2], f'{label}: {text}')

    def test_skins_names_the_holes_that_carried_into_a_win(self):
        """§4: `["Hole 7", "Kim ×3 · carried 5, 6"]` — the multiplier says
        how big the pot was and the holes say where it came from."""
        rows = dict(self._rows('skins'))
        self.assertEqual(rows['Hole 3'], 'A ×3 · carried 1, 2')

    def test_skins_says_when_the_round_ended_on_a_carry(self):
        rows = dict(self._rows('skins'))
        self.assertIn('Carried over', rows)
        self.assertIn('no winner', rows['Carried over'])

    def test_a_long_carry_run_is_counted_rather_than_listed(self):
        """Eleven hole numbers in a row is a paragraph, not a breakdown."""
        rows = dict(self._rows('skins'))
        self.assertEqual(rows['Carried over'], 'no winner · 11 holes from 8')

    def test_rabbit_marks_the_extra_and_names_the_window(self):
        """§4: "The extra rabbit is labelled `Ex`"."""
        labels = [r[0] for r in self._rows('rabbit')]
        self.assertTrue(any(' Ex · ' in l for l in labels), labels)
        self.assertTrue(all('–' in l for l in labels), labels)

    def test_survivor_names_each_one_and_what_it_paid(self):
        rows = self._rows('survivor')
        self.assertTrue(rows[0][0].startswith('Survivor 1 · '), rows[0])
        self.assertIn('$', rows[0][1], rows[0])

    def test_points_splits_out_and_in_at_the_turn(self):
        """Every golfer scores the same on all eighteen holes here, so Out
        and In must be equal — which is what says the split is at hole 9 and
        not somewhere else."""
        rows = dict(self._rows('points_531'))
        self.assertEqual(rows['A'], 'Out 45 · In 45 · 90')
        self.assertEqual(rows['Settles'], 'Against the average')

    def test_stroke_play_shows_where_the_money_came_from(self):
        """§4's "the pool (in, places paid)" — the only thing on the receipt
        that says what was put in to produce the chips."""
        rows = dict(self._rows('low_net_round'))
        self.assertEqual(rows['In'], '3 × $10 = $30')
        self.assertEqual(rows['1st'], '$30')

    def test_wolf_says_who_played_with_whom_and_how_it_went(self):
        """§4: the wolf, partner, Lone or Blind, and the result."""
        rows = dict(self._rows('wolf'))
        self.assertIn(' · ', rows['Hole 1'])
        self.assertTrue(any('lone' in v for v in rows.values()), rows)
        self.assertTrue(all(v.split(' · ')[-1] in ('wolf', 'field', 'halved')
                            for v in rows.values()), rows)
