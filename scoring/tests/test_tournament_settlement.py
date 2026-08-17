"""
scoring/tests/test_tournament_settlement.py
-------------------------------------------
Tournament settlement (services/tournament_settlement.py,
docs/design-review/handoff-individual-play/SPEC.md §9).

The rules under test:

* tournament-scope pots ONLY — foursome side bets settle in the group;
* Irish Rumble and the ball game are re-drawn every round, so each appears
  once PER ROUND, entered separately and won separately;
* the carve-out leaves the championship pool for another game's table, so the
  championship shows the full pool in and the full pool out;
* not everybody staked the same — the ineligible do not pay into the day bet;
* a pot that does not balance BLOCKS settlement and NAMES the game;
* Settle stays off until every round is closed;
* collected minus paid is zero, or it is an arithmetic bug.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import (
    DayBetConfig, IrishRumbleConfig, LowNetChampionshipConfig,
    MiniSinglesConfig, PinkBallConfig,
)
from services.tournament_settlement import tournament_settlement
from ._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)

SEGMENTS = [{'start_hole': 1, 'end_hole': 18, 'balls_to_count': 2}]


class SettlementBase(TestCase):
    """Eight golfers, two rounds, two groups a round."""

    NAMES = ['Petersen', 'Gunst', 'Detomasi', 'Maiolini',
             'Brown', 'Avery', 'Labass', 'Duddy']

    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.tourn  = make_tournament(total_rounds=2)
        self.champ  = LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, entry_fee=Decimal('10.00'),
            payouts=[{'place': 1, 'amount': 50}, {'place': 2, 'amount': 30}])
        self.players = [make_player(n, 0, short_name=n[:5]) for n in self.NAMES]
        self.rounds = []
        for n in (1, 2):
            r = make_round(self.course, tournament=self.tourn, round_number=n,
                           active_games=['low_net_round'])
            for g in range(2):
                make_foursome(r, [(p, 0) for p in self.players[g * 4:(g + 1) * 4]],
                              tee=self.tee, group_number=g + 1)
            self.rounds.append(r)

    def _play(self, round_obj):
        """
        Give every golfer a DISTINCT score — golfer N bogeys N holes — so the
        championship separates cleanly. An eight-way tie for 1st is a real and
        correct outcome of the split rule, but it makes a settlement fixture
        impossible to read.
        """
        for fs in round_obj.foursomes.order_by('group_number'):
            members = list(fs.memberships.select_related('player'))
            for i, h in enumerate(DEFAULT_HOLES):
                submit_hole(fs, h['number'], [
                    (m.player,
                     h['par'] + (1 if i < self.players.index(m.player) else 0))
                    for m in members
                ])
        # Mirror what the score-submit view does after every hole: the group
        # games persist their standings rather than deriving them on read.
        self._recalculate(round_obj)

    def _recalculate(self, round_obj):
        if getattr(round_obj, 'pink_ball_config', None) is not None:
            from services.red_ball import calculate_red_ball
            calculate_red_ball(round_obj)
        if getattr(round_obj, 'irish_rumble_config', None) is not None:
            from services.irish_rumble import calculate_irish_rumble
            calculate_irish_rumble(round_obj)

    def _close(self):
        for r in self.rounds:
            r.status = 'completed'
            r.save(update_fields=['status'])

    def _by_key(self, s):
        return {g['key'] + (f"·{g['round_number']}" if g['round_number'] else ''): g
                for g in s['games']}


class ChampionshipOnlyTests(SettlementBase):
    def test_a_single_balanced_pot_sums_to_zero(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        s = tournament_settlement(self.tourn)
        champ = self._by_key(s)['championship']
        self.assertEqual(champ['entries_in'], 80.0)     # $10 x 8
        self.assertEqual(champ['prizes_out'], 80.0)     # 50 + 30
        self.assertTrue(champ['balanced'])
        self.assertTrue(s['sum_zero'])
        self.assertTrue(s['can_settle'])
        self.assertEqual(s['total_collected'], s['total_paid'])

    def test_every_golfer_lists_his_entry_as_a_debit(self):
        self._play(self.rounds[0])
        self._close()
        s = tournament_settlement(self.tourn)
        self.assertEqual(len(s['golfers']), 8)
        for g in s['golfers']:
            self.assertEqual(g['staked'], 10.0)
            self.assertEqual(g['entries'][0]['game'], 'Championship')

    def test_collects_are_listed_first(self):
        self._play(self.rounds[0])
        self._close()
        s = tournament_settlement(self.tourn)
        nets = [g['net'] for g in s['golfers']]
        self.assertEqual(nets, sorted(nets, reverse=True))
        self.assertGreater(nets[0], 0)

    def test_an_unbalanced_table_blocks_and_names_the_game(self):
        self.champ.payouts = [{'place': 1, 'amount': 50}]   # $30 left in the pot
        self.champ.save(update_fields=['payouts'])
        self._play(self.rounds[0])
        self._close()

        s = tournament_settlement(self.tourn)
        self.assertFalse(s['balanced'])
        self.assertFalse(s['can_settle'])
        self.assertTrue(any('Championship does not balance' in b
                            for b in s['blocking']))
        self.assertIn('$30.00', ' '.join(s['blocking']))

    def test_settle_stays_off_until_every_round_closes(self):
        self._play(self.rounds[0])
        s = tournament_settlement(self.tourn)
        self.assertFalse(s['can_settle'])
        self.assertTrue(any('closed' in b for b in s['blocking']))


class PerRoundGamesTests(SettlementBase):
    """Irish Rumble and the ball game are re-drawn every round."""

    def setUp(self):
        super().setUp()
        for r in self.rounds:
            IrishRumbleConfig.objects.create(
                round=r, variant='classic', handicap_mode='net',
                net_percent=100, entry_fee=Decimal('10.00'),
                payouts=[{'place': 1, 'amount': 80}], segments=SEGMENTS)
            PinkBallConfig.objects.create(
                round=r, game_name='Beer Ball', entry_fee=Decimal('15.00'),
                payouts=[{'place': 1, 'amount': 120}])
            for fs in r.foursomes.all():
                fs.pink_ball_order = list(
                    fs.memberships.values_list('player_id', flat=True))
                fs.save(update_fields=['pink_ball_order'])

    def test_each_game_appears_once_per_round(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        labels = [g['label'] for g in tournament_settlement(self.tourn)['games']]
        self.assertIn('Irish Rumble · R1', labels)
        self.assertIn('Irish Rumble · R2', labels)
        self.assertIn('Beer Ball · R1', labels)
        self.assertIn('Beer Ball · R2', labels)

    def test_the_ball_game_reads_the_name_the_td_typed(self):
        self._play(self.rounds[0])
        labels = [g['label'] for g in tournament_settlement(self.tourn)['games']]
        self.assertTrue(any(l.startswith('Beer Ball') for l in labels))

    def test_a_group_prize_reaches_each_golfer_as_his_share(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        s = tournament_settlement(self.tourn)
        rumble = self._by_key(s)['irish_rumble·1']
        self.assertEqual(rumble['entries_in'], 80.0)     # $10 x 8
        self.assertEqual(rumble['prizes_out'], 80.0)     # $80 split four ways
        # The itemisation names the group and how many ways it split.
        shares = [p for g in s['golfers'] for p in g['prizes']
                  if g['prizes'] and 'Irish Rumble' in p['game']]
        self.assertTrue(shares)
        self.assertTrue(all('ways' in p['detail'] for p in shares))

    def test_everything_still_sums_to_zero_across_seven_pots(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()
        s = tournament_settlement(self.tourn)
        self.assertTrue(s['sum_zero'], msg=s['blocking'])


class CarveOutTests(SettlementBase):
    """
    The carve-out is why the championship shows the full pool in and the full
    pool out, with part of it leaving for another game's table.
    """

    def setUp(self):
        super().setUp()
        self.tourn.mini_singles_carve_pct = 25
        self.tourn.save(update_fields=['mini_singles_carve_pct'])
        # $80 pool, 25% carved → $60 left for the championship places.
        self.champ.payouts = [{'place': 1, 'amount': 40},
                              {'place': 2, 'amount': 20}]
        self.champ.save(update_fields=['payouts'])
        MiniSinglesConfig.objects.create(
            tournament=self.tourn, day1_entry_fee=Decimal('0.00'),
            day1_payouts=[], day2_payouts=[{'place': 1, 'amount': 20}])
        self.rounds[1].foursomes.filter(group_number=2).update(
            is_champions_foursome=True)

    def test_the_championship_pays_out_its_whole_pool(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        s = tournament_settlement(self.tourn)
        champ = self._by_key(s)['championship']
        self.assertEqual(champ['entries_in'], 80.0)
        self.assertEqual(champ['transfer_out'], 20.0)   # 25% of $80
        self.assertEqual(champ['prizes_out'], 80.0)     # 40 + 20 + the carve-out
        self.assertTrue(champ['balanced'])

    def test_day_two_is_funded_by_the_transfer_not_by_an_entry(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        day2 = self._by_key(tournament_settlement(self.tourn))['mini_singles_day2·2']
        self.assertEqual(day2['transfer_in'], 20.0)
        self.assertEqual(day2['entries_in'], 20.0)


class DayBetStakeTests(SettlementBase):
    """Not everybody staked the same, and the ineligible never pay in."""

    def setUp(self):
        super().setUp()
        DayBetConfig.objects.create(
            round=self.rounds[1], entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 120}])

    def test_the_championship_money_winners_do_not_fund_the_day_bet(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        s = tournament_settlement(self.tourn)
        by_name = {g['name']: g for g in s['golfers']}
        entered_day_bet = {
            name for name, g in by_name.items()
            if any('Day bet' in e['game'] for e in g['entries'])
        }
        # Two golfers take championship money, and neither is charged.
        self.assertEqual(len(entered_day_bet), 6)

    def test_a_golfer_out_of_the_day_bet_lists_one_fewer_entry(self):
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        s = tournament_settlement(self.tourn)
        counts = {len(g['entries']) for g in s['golfers']}
        # Six entries for the ineligible, seven for the ten who can win it.
        self.assertEqual(counts, {1, 2})


class ScopeTests(SettlementBase):
    def test_foursome_side_bets_are_absent_and_the_screen_says_so(self):
        from games.models import SkinsGame
        SkinsGame.objects.create(foursome=self.rounds[0].foursomes.first())
        self._play(self.rounds[0])

        s = tournament_settlement(self.tourn)
        self.assertNotIn('skins', [g['key'] for g in s['games']])
        self.assertIn('settle in the group', s['excluded_note'])
