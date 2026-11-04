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

from core.models import RoundStatus

from games.models import (
    BetterBallConfig, DayBetConfig, HotSpotConfig, IrishRumbleConfig,
    LowNetChampionshipConfig, MiniSinglesConfig, PinkBallConfig,
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
        # The skins pool persists its per-hole winners too, and the score
        # endpoint recomputes every pool a round hosts or is linked into.
        from services.multi_skins import recalc_pools_for_round
        recalc_pools_for_round(round_obj)

    def _close(self):
        for r in self.rounds:
            r.status = RoundStatus.COMPLETE
            r.save(update_fields=['status'])

    def _by_key(self, s):
        return {g['key'] + (f"·{g['round_number']}" if g['round_number'] else ''): g
                for g in s['games']}


class OnePoolFamilyTests(SettlementBase):
    """Every member of the one-pool family reaches the receipt.

    **Hot Seat and Better Ball did not, for months.** Irish Rumble, 40 Balls
    and the ball game had blocks written out by hand and these two never got
    one, so their entry fees were collected and their pots never appeared.
    Reported by a TD after a Hot Seat round, by which point he had worked his
    own money out on paper.
    """

    def test_the_spec_table_covers_the_family_exactly(self):
        """The structural guard, and the point of the whole change.

        The pots are driven off `ONE_POOL_GAMES` now, so a sixth game cannot
        join the family and be silently left out of settlement — it either
        gets a spec or this fails.
        """
        from services.group_field import ONE_POOL_GAMES
        from services.tournament_settlement import _ONE_POOL_SPECS
        self.assertEqual(sorted(_ONE_POOL_SPECS), sorted(ONE_POOL_GAMES))

    def _settle_with(self, config_maker):
        config_maker(self.rounds[0])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()
        return tournament_settlement(self.tourn)

    def test_hot_seat_reaches_the_receipt(self):
        s = self._settle_with(lambda r: HotSpotConfig.objects.create(
            round=r, handicap_mode='net', net_percent=100,
            entry_fee=Decimal('5.00'),
            payouts=[{'place': 1, 'amount': 40}]))

        pot = self._by_key(s).get('hot_spot·1')
        self.assertIsNotNone(pot, f"no Hot Seat pot in {[g['label'] for g in s['games']]}")
        self.assertEqual(pot['label'], 'Hot Seat · R1')
        self.assertEqual(pot['entries_in'], 40.0)        # $5 x 8 golfers
        self.assertEqual(pot['prizes_out'], 40.0)        # the $40 place
        self.assertTrue(s['sum_zero'], msg=s['blocking'])

    def test_better_ball_reaches_the_receipt(self):
        s = self._settle_with(lambda r: BetterBallConfig.objects.create(
            round=r, balls_to_count=2, handicap_mode='net', net_percent=100,
            entry_fee=Decimal('5.00'),
            payouts=[{'place': 1, 'amount': 40}]))

        pot = self._by_key(s).get('better_ball·1')
        self.assertIsNotNone(pot, f"no Better Ball pot in {[g['label'] for g in s['games']]}")
        self.assertEqual(pot['entries_in'], 40.0)
        self.assertEqual(pot['prizes_out'], 40.0)
        self.assertTrue(s['sum_zero'], msg=s['blocking'])

    def test_better_ball_is_labelled_with_the_name_the_td_typed(self):
        """Better Ball is the one whose label comes from the summary rather
        than from the spec table, because the TD names it."""
        s = self._settle_with(lambda r: BetterBallConfig.objects.create(
            round=r, balls_to_count=2, name='Two Best', handicap_mode='net',
            net_percent=100, entry_fee=Decimal('5.00'),
            payouts=[{'place': 1, 'amount': 40}]))
        labels = [g['label'] for g in s['games']]
        self.assertIn('Two Best · R1', labels)

    def test_a_group_prize_splits_among_the_real_golfers(self):
        s = self._settle_with(lambda r: HotSpotConfig.objects.create(
            round=r, handicap_mode='net', net_percent=100,
            entry_fee=Decimal('5.00'),
            payouts=[{'place': 1, 'amount': 40}]))
        shares = [p for g in s['golfers'] for p in g['prizes']
                  if 'Hot Seat' in p['game']]
        self.assertTrue(shares, 'nobody was paid the Hot Seat prize')
        self.assertTrue(all('ways' in p['detail'] for p in shares))


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


class ReceiptPayloadTests(SettlementBase):
    """The golfer's side of settlement (services/settlement_receipt.py).

    The receipt answers a different question from settlement — what do I owe,
    to whom, and what for — off exactly the same numbers. Nothing here may
    recompute money, and the send gate must be the same condition as Settle:
    provisional money does not leave the app.
    """

    def _payload(self, **kw):
        from services.settlement_receipt import receipt_payload
        return receipt_payload(self.tourn, **kw)

    def test_it_reads_settlement_rather_than_recomputing(self):
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        settled = tournament_settlement(self.tourn)
        payload = self._payload()
        self.assertEqual([g['net'] for g in payload['golfers']],
                         [g['net'] for g in settled['golfers']])
        self.assertEqual(payload['totals']['collected'],
                         settled['total_collected'])

    def test_every_golfer_carries_the_text_that_would_go_to_him(self):
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        for g in self._payload()['golfers']:
            self.assertIn(g['name'], g['message'])
            self.assertIn('to collect' if g['net'] >= 0 else 'to pay',
                          g['message'])
            self.assertGreaterEqual(g['segments']['segments'], 1)

    def test_the_field_summary_sorts_collectors_first(self):
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        msg = self._payload()['field_summary']['message']
        self.assertIn('Collecting', msg)
        self.assertIn('Paying', msg)
        self.assertLess(msg.index('Collecting'), msg.index('Paying'))

    def test_the_field_summary_carries_no_itemisation(self):
        """A man's lines in a sixteen-man thread is the wrong default."""
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        msg = self._payload()['field_summary']['message']
        self.assertNotIn('Entries', msg)
        self.assertNotIn('Beer Ball', msg)

    def test_the_note_reaches_both_payloads(self):
        """The note is the actual reason a TD wants to text at all."""
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        p = self._payload(note='Venmo @paul-lipkin by Friday')
        self.assertIn('Venmo @paul-lipkin by Friday',
                      p['field_summary']['message'])
        self.assertIn('Venmo @paul-lipkin by Friday',
                      p['golfers'][0]['message'])

    def test_composition_is_a_pure_function(self):
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        self.assertEqual(self._payload()['field_summary']['message'],
                         self._payload()['field_summary']['message'])

    # -- the gate ------------------------------------------------------------

    def test_nothing_can_be_sent_while_a_round_is_open(self):
        """Provisional money must not leave the app."""
        self._play(self.rounds[0])
        p = self._payload()
        self.assertFalse(p['can_send'])
        self.assertTrue(any('closed' in b for b in p['blocking']))

    def test_the_gate_is_the_same_condition_as_settle(self):
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        p = self._payload()
        self.assertTrue(p['can_send'])
        self.assertEqual(p['blocking'], [])
        self.assertEqual(p['can_send'],
                         tournament_settlement(self.tourn)['can_settle'])

    def test_the_exclusion_note_travels(self):
        """Foursome side bets are absent, and the omission must not read as a
        bug."""
        self._play(self.rounds[0]); self._play(self.rounds[1]); self._close()
        self.assertTrue(self._payload()['excluded_note'])

    # -- the record ----------------------------------------------------------

    def test_no_send_recorded_yet(self):
        self.assertIsNone(self._payload()['last_send'])

    def test_a_recorded_send_comes_back_on_the_payload(self):
        from tournament.models import SettlementSend
        SettlementSend.objects.create(tournament=self.tourn, mode='field',
                                      recipients=8)
        last = self._payload()['last_send']
        self.assertEqual(last['mode'], 'field')
        self.assertEqual(last['recipients'], 8)

    def test_the_most_recent_send_wins(self):
        """A resend is a real event, and the second one is the one people ask
        about."""
        from tournament.models import SettlementSend
        SettlementSend.objects.create(tournament=self.tourn, mode='field',
                                      recipients=8)
        SettlementSend.objects.create(tournament=self.tourn, mode='field',
                                      recipients=7)
        self.assertEqual(self._payload()['last_send']['recipients'], 7)


class ProvisionalChecksTests(TestCase):
    """**The arithmetic is not finished until the rounds are.**

    Reported from testing on a live event: `Dream Round · Net does not balance —
    $20.00 underpaid. The mistake is in its payout table` over a payout table
    the setup screen called correct on the same data, and then the same $20
    again as `Collected and paid do not cancel ... an arithmetic bug`.

    Dream Round pays nobody until a card is WHOLE, so mid-event its entries are
    in and its prizes are zero. That is the game working.
    """

    def setUp(self):
        from datetime import date
        from decimal import Decimal
        from games.models import DreamRoundConfig
        self.course = make_course('North Links')
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tourn = make_tournament(name='Two Day')
        self.tourn.total_rounds = 2
        self.tourn.save()
        self.ann = make_player('Ann', handicap_index=0)
        self.bea = make_player('Bea', handicap_index=0)
        self.rounds = []
        for n in (1, 2):
            r = make_round(course=self.course, tournament=self.tourn,
                           round_number=n)
            r.date = date(2026, 10, 10 + n)
            r.save()
            self.rounds.append(r)
            make_foursome(r, [(self.ann, 0), (self.bea, 0)], tee=self.tee)
        DreamRoundConfig.objects.create(
            tournament=self.tourn, gross_on=False, net_on=True,
            net_entry_fee=Decimal('5.00'),
            net_payouts=[{'place': 1, 'amount': 10.00}])

    def _settle(self):
        from services.tournament_settlement import tournament_settlement
        return tournament_settlement(self.tourn)

    def test_a_live_event_does_not_blame_the_payout_table(self):
        data = self._settle()
        self.assertTrue(data['provisional'])
        joined = ' '.join(data['blocking'])
        self.assertNotIn('payout table', joined)
        self.assertNotIn('arithmetic bug', joined)

    def test_the_one_true_reason_is_the_only_one_and_comes_first(self):
        data = self._settle()
        self.assertEqual(len(data['blocking']), 1)
        self.assertIn('closed before the tournament settles',
                      data['blocking'][0])

    def test_a_closed_event_runs_every_check(self):
        # The table here really is short — $10 of a $10 pool paid to nobody
        # eligible — and once the rounds close that IS worth naming.
        for r in self.rounds:
            r.status = RoundStatus.COMPLETE
            r.save()
        data = self._settle()
        self.assertFalse(data['provisional'])
        joined = ' '.join(data['blocking'])
        self.assertIn('payout table', joined)


class SparseSkinsPoolTests(SettlementBase):
    """A skins pool inside a tournament — the one pot the whole field does
    not enter.

    The TD ticks who is in; their scores come off the cards their groups are
    already keeping, so there is no second round to set up and no re-grouping.
    Three of eight here, deliberately spanning BOTH groups, because a pool
    that sat inside one foursome would be a foursome's own side bet and would
    be settling in the wrong place.
    """

    def _pool(self, round_obj, names, ante=20.00, **kw):
        from services.multi_skins import (
            calculate_multi_skins, setup_multi_skins,
        )
        ids = [self.players[self.NAMES.index(n)].id for n in names]
        setup_multi_skins(round_obj, participant_ids=ids,
                          handicap_mode='net', bet_unit=ante, **kw)
        calculate_multi_skins(round_obj)
        return ids

    def test_only_the_participants_pay_in(self):
        ids = self._pool(self.rounds[0], ['Petersen', 'Gunst', 'Brown'])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        pot = self._by_key(tournament_settlement(self.tourn))['multi_skins·1']
        # Three antes, not eight. The pool is the only sparse pot in here.
        self.assertEqual(pot['entries_in'], 60.0)
        self.assertTrue(pot['balanced'], pot)

        # And nobody else is charged: the five golfers who are not in the
        # pool carry no entry line for it.
        # A golfer's own lines name the game by its LABEL — there is no key
        # per line, because the receipt reads these as sentences.
        charged = set()
        for g in tournament_settlement(self.tourn)['golfers']:
            for line in g.get('entries', []):
                if line['game'] == 'Multi-Group Skins · R1':
                    charged.add(g['player_id'])
        self.assertEqual(charged, set(ids))

    def test_it_spans_the_groups_and_pays_the_skins_won(self):
        self._pool(self.rounds[0], ['Petersen', 'Gunst', 'Brown'])
        self._play(self.rounds[0])

        from services.multi_skins import multi_skins_summary
        summary = multi_skins_summary(self.rounds[0])
        # Petersen pars everything; the other two bogey the early holes, so
        # he takes those outright and the rest die in a three-way tie.
        won = {p['short_name']: p['skins_won'] for p in summary['players']}
        self.assertGreater(won['Peter'], 0, won)
        self.assertEqual(sum(won.values()), summary['money']['total_skins'])
        # Two different groups contributed scores to one pool.
        self.assertEqual(
            len({p['group_number'] for p in summary['players']}), 2)

        self._play(self.rounds[1])
        self._close()
        pot = self._by_key(tournament_settlement(self.tourn))['multi_skins·1']
        self.assertEqual(pot['prizes_out'], 60.0)

    def test_a_pool_appears_once_per_round(self):
        self._pool(self.rounds[0], ['Petersen', 'Gunst', 'Brown'])
        self._pool(self.rounds[1], ['Petersen', 'Gunst', 'Brown'], ante=5.00)
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        keys = self._by_key(tournament_settlement(self.tourn))
        self.assertIn('multi_skins·1', keys)
        self.assertIn('multi_skins·2', keys)
        self.assertEqual(keys['multi_skins·2']['entries_in'], 15.0)

    def test_a_no_money_pool_draws_no_pot(self):
        """$0 is an explicit opt-in on the setup screen, so it is a real
        state — and a pot with nothing in and nothing out is a line that
        invites the question of where the money went."""
        self._pool(self.rounds[0], ['Petersen', 'Gunst', 'Brown'], ante=0)
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        keys = self._by_key(tournament_settlement(self.tourn))
        self.assertNotIn('multi_skins·1', keys)

    def test_everything_still_sums_to_zero(self):
        self._pool(self.rounds[0], ['Petersen', 'Gunst', 'Brown'])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        s = tournament_settlement(self.tourn)
        self.assertTrue(s['sum_zero'],
                        (s['total_collected'], s['total_paid']))
        self.assertTrue(s['can_settle'], s['blocking'])

    def test_a_foursome_skins_game_is_still_out_of_scope(self):
        """The round-level pool is the TD's; a group's own skins is not.
        Both are called skins, so the distinction is worth pinning."""
        from games.models import SkinsGame
        SkinsGame.objects.create(foursome=self.rounds[0].foursomes.first())
        self._pool(self.rounds[0], ['Petersen', 'Gunst', 'Brown'])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        keys = [g['key'] for g in tournament_settlement(self.tourn)['games']]
        self.assertIn('multi_skins', keys)
        self.assertNotIn('skins', keys)


class Sparse40BallsPotTests(SettlementBase):
    """**40 Balls between a subset of the GROUPS.**

    The other sparse pot in here is the skins pool, and the two are sparse in
    different dimensions: skins ranks golfers, so a subset there is a subset of
    the field's golfers; 40 Balls ranks groups, so a subset is a subset of the
    groups. What they share is that the entry follows the board — a group that
    is not playing is not charged.
    """

    def _forty_balls(self, round_obj, group_numbers=None, fee='10.00',
                     first=None):
        """`first` is the 1st prize; left out it is the whole pool, so the pot
        balances and the test is about WHO paid rather than about a table the
        TD set against the wrong field."""
        from games.models import FortyBallsConfig
        from services.group_field import pool_foursomes
        cfg = FortyBallsConfig.objects.create(
            round=round_obj, entry_fee=Decimal(fee), payouts=[])
        if group_numbers is not None:
            cfg.groups.set(round_obj.foursomes.filter(
                group_number__in=group_numbers))
        if first is None:
            golfers = sum(
                fs.memberships.filter(player__is_phantom=False).count()
                for fs in pool_foursomes(round_obj, cfg))
            first = float(Decimal(fee)) * golfers
        cfg.payouts = [{'place': 1, 'amount': first}]
        cfg.save(update_fields=['payouts'])
        round_obj.active_games = (list(round_obj.active_games or [])
                                  + ['forty_balls'])
        round_obj.save(update_fields=['active_games'])
        return cfg

    def _spend_the_budget(self, round_obj):
        """A legal 40-ball plan for every playing group, written straight to
        the table: `set_count` is the group picking as it plays, and this
        fixture has already played the round.

        **It has to spend the budget EXACTLY.** Two a hole is 36 of 40, which
        leaves four balls owed with no holes to put them on — the DQ state —
        and a DQ'd group takes no prize, so the pot would collect and pay
        nothing. 2 × 16 + 4 × 2 = 40.
        """
        from games.models import FortyBallsHoleCount
        from services.group_field import pool_foursomes
        for fs in pool_foursomes(round_obj, round_obj.forty_balls_config):
            for h in (hh['number'] for hh in DEFAULT_HOLES):
                FortyBallsHoleCount.objects.create(
                    foursome=fs, hole_number=h, count=4 if h > 16 else 2)

    def test_only_the_playing_groups_pay_in(self):
        self._forty_balls(self.rounds[0], group_numbers=[1])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        pot = self._by_key(tournament_settlement(self.tourn))['forty_balls·1']
        # Four antes, not eight.
        self.assertEqual(pot['entries_in'], 40.0)

    def test_the_golfers_charged_are_the_ones_in_the_groups(self):
        self._forty_balls(self.rounds[0], group_numbers=[1])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        playing = {
            m.player_id for m in
            self.rounds[0].foursomes.get(group_number=1).memberships.all()}
        charged = set()
        for g in tournament_settlement(self.tourn)['golfers']:
            for line in g.get('entries', []):
                if line['game'] == '40 Balls · R1':
                    charged.add(g['player_id'])
        self.assertEqual(charged, playing)

    def test_a_full_field_is_unchanged(self):
        """The whole point of empty-means-all: the shipped behaviour is the
        degenerate case, so it cannot drift."""
        self._forty_balls(self.rounds[0])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        pot = self._by_key(tournament_settlement(self.tourn))['forty_balls·1']
        self.assertEqual(pot['entries_in'], 80.0)

    def test_the_prize_pays_the_groups_and_the_pot_balances(self):
        self._forty_balls(self.rounds[0], group_numbers=[1, 2])
        self._play(self.rounds[0])
        self._spend_the_budget(self.rounds[0])
        self._play(self.rounds[1])
        self._close()

        pot = self._by_key(tournament_settlement(self.tourn))['forty_balls·1']
        self.assertEqual(pot['entries_in'], 80.0)
        self.assertEqual(pot['prizes_out'], 80.0)
        self.assertTrue(pot['balanced'], pot)

    def test_a_group_that_has_not_teed_off_still_paid_its_entry(self):
        """Which is why the entrants are read off the BOARD's rows rather than
        off the ranking: an unranked row is a group that entered."""
        from services.forty_balls import forty_balls_summary
        self._forty_balls(self.rounds[0], group_numbers=[1, 2])
        # Only group 1 plays.
        fs1 = self.rounds[0].foursomes.get(group_number=1)
        members = list(fs1.memberships.select_related('player'))
        for h in DEFAULT_HOLES:
            submit_hole(fs1, h['number'],
                        [(m.player, h['par']) for m in members])
        # Both groups are on the board — the one that has not teed off
        # included, which is the row the entry is read off.
        rows = forty_balls_summary(self.rounds[0])['results']
        self.assertEqual(len(rows), 2)

        self._play(self.rounds[1])
        self._close()
        pot = self._by_key(tournament_settlement(self.tourn))['forty_balls·1']
        self.assertEqual(pot['entries_in'], 80.0)

    def test_the_board_s_own_pool_matches_what_settlement_collects(self):
        """Two readings of one number is how they come to disagree."""
        from services.forty_balls import forty_balls_summary
        self._forty_balls(self.rounds[0], group_numbers=[2])
        self._play(self.rounds[0])
        self._play(self.rounds[1])
        self._close()
        board = forty_balls_summary(self.rounds[0])['pool']
        pot = self._by_key(tournament_settlement(self.tourn))['forty_balls·1']
        self.assertEqual(board, pot['entries_in'])
