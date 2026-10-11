"""
api/test_day_bet.py
-------------------
Day-bet setup/board endpoints, and the payout-step guard that sizes the two
pots against each other.

The guard belongs in the reducer, not only in the UI: an API caller must not
be able to post a championship table whose last paying place is worth less
than day-bet 1st, because that placing DISQUALIFIES a golfer from the day bet
and would therefore cost him money. Nobody should be worse off for playing
better. (Rule and helper: services/payout.py; spec §3.)
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Tee
from games.models import DayBetConfig, LowNetChampionshipConfig
from tournament.models import Round, Tournament

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _DayBetBase(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Duddy Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        Tee.objects.create(course=course, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Duddy Cup', start_date=date(2026, 6, 1),
            total_rounds=2, active_games=['low_net'])
        self.r1 = Round.objects.create(account=self.acct, course=course,
                                       tournament=self.tourn, round_number=1,
                                       status='in_progress')
        self.r2 = Round.objects.create(account=self.acct, course=course,
                                       tournament=self.tourn, round_number=2,
                                       status='in_progress')

    def _setup_url(self, round_obj):
        return reverse('api-day-bet-setup', args=[round_obj.id])


class DayBetEndpointTests(_DayBetBase):
    """The endpoint's own behaviour.

    Split from `_DayBetBase` so a subclass can take the fixture without
    inheriting these: a class that installs its own championship table or
    day-bet config re-runs them against a fixture they were not written for,
    and four of them started failing for reasons that had nothing to do with
    the thing under test.
    """

    # -- setup ------------------------------------------------------------

    def test_defaults_when_no_day_bet_is_configured(self):
        r = self.client.get(self._setup_url(self.r2))
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertEqual(d['entry_fee'], 0.00)
        self.assertEqual(d['payouts'], [])
        self.assertFalse(d['configured'])
        # The screen is told whether it may configure here and why not, rather
        # than deriving it — the day bet is the final round of a multi-round
        # event only, and a client counting rounds would be a second copy of
        # that rule.
        self.assertIn('eligible', d)
        self.assertIn('reason', d)
        self.assertIn('championship_payouts', d)

    def test_configure_round_trips(self):
        r = self.client.post(self._setup_url(self.r2), {
            'entry_fee': '20.00',
            'payouts'  : [{'place': 1, 'amount': 100}, {'place': 2, 'amount': 60}],
        }, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['entry_fee'], 20.0)
        self.assertTrue(DayBetConfig.objects.filter(round=self.r2).exists())

    def test_a_one_round_event_has_no_day_bet(self):
        self.tourn.total_rounds = 1
        self.tourn.save(update_fields=['total_rounds'])
        r = self.client.post(self._setup_url(self.r2),
                             {'entry_fee': '20.00', 'payouts': []},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('more than one round', r.json()['detail'])

    # -- the floor guard, from both directions ----------------------------

    def test_posting_a_day_bet_that_out_pays_the_championship_is_blocked(self):
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, entry_fee=Decimal('40.00'),
            payouts=[{'place': 1, 'amount': 400}, {'place': 2, 'amount': 80}])

        r = self.client.post(self._setup_url(self.r2), {
            'entry_fee': '20.00',
            'payouts'  : [{'place': 1, 'amount': 140}],
        }, format='json')
        self.assertEqual(r.status_code, 400)
        detail = r.json()['detail']
        self.assertIn('day bet', detail)
        self.assertIn('$60.00', detail)      # what the DQ would cost him
        self.assertFalse(DayBetConfig.objects.filter(round=self.r2).exists())

    def test_lowering_the_championship_below_the_day_bet_is_blocked(self):
        DayBetConfig.objects.create(
            round=self.r2, entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 140}])

        r = self.client.post(
            reverse('api-tournament-low-net-setup', args=[self.tourn.id]),
            {'entry_fee': '40.00',
             'payouts': [{'place': 1, 'amount': 400}, {'place': 2, 'amount': 80}]},
            format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('day bet', r.json()['detail'])
        self.assertFalse(
            LowNetChampionshipConfig.objects.filter(tournament=self.tourn).exists())

    def test_a_table_that_clears_the_floor_saves(self):
        DayBetConfig.objects.create(
            round=self.r2, entry_fee=Decimal('20.00'),
            payouts=[{'place': 1, 'amount': 100}])

        r = self.client.post(
            reverse('api-tournament-low-net-setup', args=[self.tourn.id]),
            {'entry_fee': '40.00',
             'payouts': [{'place': 1, 'amount': 400}, {'place': 2, 'amount': 200}]},
            format='json')
        self.assertEqual(r.status_code, 200)

    # -- board ------------------------------------------------------------

    def test_board_reports_unconfigured(self):
        r = self.client.get(reverse('api-day-bet', args=[self.r2.id]))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json(), {'configured': False})


class ThePotIsTheEligibleCountTests(DayBetEndpointTests):
    """Eight golfers paying two places is a pot of SIX entries, not eight.

    The money winners do not pay in. `day_bet_summary` has always computed
    the pool that way once the round exists; the SETUP screen was multiplying
    by the whole field, so a TD sizing the payouts was shown a pot a third
    bigger than the one that would exist. Reported 10 Oct 2026.
    """

    def _field(self, n):
        """n real golfers across the tournament's rounds."""
        from core.models import Player, Tee
        from tournament.models import Foursome, FoursomeMembership
        tee = Tee.objects.filter(course=self.r1.course).first()
        fs = Foursome.objects.create(round=self.r1, group_number=1)
        for i in range(n):
            p = Player.objects.create(account=self.acct, name=f'G{i}',
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(foursome=fs, player=p, tee=tee,
                                              course_handicap=0,
                                              playing_handicap=0)

    def test_the_paying_places_come_out_of_the_pot(self):
        self._field(8)
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tourn,
            defaults={'payouts': [{'place': 1, 'amount': 60},
                                  {'place': 2, 'amount': 20}]})
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertEqual(d['field_size'], 8)
        self.assertEqual(d['paying_places'], 2)
        self.assertEqual(d['expected_eligible'], 6,
                         'eight golfers, two in the money, six pay in')

    def test_a_place_paying_nothing_does_not_come_out(self):
        """A zero row is a place nobody collects, so that golfer still pays."""
        self._field(8)
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tourn,
            defaults={'payouts': [{'place': 1, 'amount': 60},
                                  {'place': 2, 'amount': 0}]})
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertEqual(d['expected_eligible'], 7)

    def test_no_championship_means_the_whole_field_pays(self):
        self._field(8)
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertEqual(d['paying_places'], 0)
        self.assertEqual(d['expected_eligible'], 8)


class TurningItOffTests(DayBetEndpointTests):
    """A TD who set one up and changed his mind had no way back.

    An entry of 0 is a configured bet worth nothing — it still draws a board
    and a tab. Deleting the config is the honest "we are not playing one".
    """

    def test_delete_removes_it(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '5.00',
                          'payouts': [{'place': 1, 'amount': 20}]},
                         format='json')
        self.assertTrue(DayBetConfig.objects.filter(round=self.r2).exists())

        r = self.client.delete(self._setup_url(self.r2))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(r.json()['configured'])
        self.assertFalse(DayBetConfig.objects.filter(round=self.r2).exists())

    def test_delete_is_idempotent(self):
        """Nothing to remove is not an error — the end state is what matters."""
        r = self.client.delete(self._setup_url(self.r2))
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()['deleted'])

    def test_the_setup_reports_it_gone(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '5.00', 'payouts': []}, format='json')
        self.client.delete(self._setup_url(self.r2))
        d = self.client.get(self._setup_url(self.r2)).json()
        self.assertFalse(d['configured'])
        self.assertEqual(d['entry_fee'], 0.00)


class TheHubButtonFollowsTheSwitchTests(DayBetEndpointTests):
    """`has_day_bet` is what takes the hub's button away.

    The hub drew a Configure Day bet button off `is_final_round` alone, so it
    appeared on the last round whether or not a day bet existed — and a TD who
    turned one off on the side games screen was left with a live route into a
    bet nobody was playing. `is_final_round` says one COULD live here;
    `has_day_bet` says one does, and the button needs both.
    """

    def _round_payload(self, round_obj):
        r = self.client.get(reverse('api-round-detail', args=[round_obj.id]))
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def test_false_before_anything_is_set_up(self):
        d = self._round_payload(self.r2)
        self.assertTrue(d['is_final_round'])
        self.assertFalse(d['has_day_bet'])

    def test_true_once_it_is(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '4.00',
                          'payouts': [{'place': 1, 'amount': 20}]},
                         format='json')
        self.assertTrue(self._round_payload(self.r2)['has_day_bet'])

    def test_false_again_once_it_is_turned_off(self):
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '4.00',
                          'payouts': [{'place': 1, 'amount': 20}]},
                         format='json')
        self.client.delete(self._setup_url(self.r2))
        self.assertFalse(self._round_payload(self.r2)['has_day_bet'])

    def test_an_entry_of_zero_still_counts_as_set_up(self):
        """A bet worth nothing is still a bet — it draws a board and a tab.

        Deleting the config is the only honest "we are not playing one", which
        is why the flag asks whether the config exists rather than whether the
        fee is above zero.
        """
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': '0.00', 'payouts': []}, format='json')
        self.assertTrue(self._round_payload(self.r2)['has_day_bet'])

    def test_an_earlier_round_is_never_a_day_bet_round(self):
        d = self._round_payload(self.r1)
        self.assertFalse(d['is_final_round'])
        self.assertFalse(d['has_day_bet'])


class ATieIsNotACleanWinTests(_DayBetBase):
    """Only a CLEAN win keeps you out of the day bet.

    Paul's rule, and his arithmetic is the spec: with $50/$30 on offer, two
    golfers tied for 2nd share 2nd AND 3rd, and 3rd pays nothing — so they
    take $15 each instead of $30. Excluding them as money winners on top of
    that punished them twice: half the prize, and locked out of a $24 bet the
    man behind them could still win. Tying for 2nd was worse than losing to
    the tie.

    So a golfer is out only when every place his tie occupies pays. Two tied
    for 1st occupy 1st and 2nd, both pay, both out. Two tied for 2nd spill
    into a place paying nothing, so they are back in — and they pay the entry,
    which takes an 8-man pot from $24 to $28.
    """

    def setUp(self):
        super().setUp()
        from core.models import Player, Tee
        from tournament.models import Foursome, FoursomeMembership
        tee = Tee.objects.filter(course=self.r1.course).first()
        # The same eight play BOTH rounds — the day bet reads the final
        # round's cards, so a field that exists only in round 1 produces an
        # empty board and a pot of nothing.
        self.fs2 = None
        self.golfers = []
        groups = {}
        for rnd in (self.r1, self.r2):
            groups[rnd.id] = Foursome.objects.create(round=rnd,
                                                     group_number=1)
        self.fs2 = groups[self.r2.id]
        for i in range(8):
            p = Player.objects.create(account=self.acct, name=f'G{i}',
                                      handicap_index=Decimal('0'))
            for rnd in (self.r1, self.r2):
                FoursomeMembership.objects.create(
                    foursome=groups[rnd.id], player=p, tee=tee,
                    course_handicap=0, playing_handicap=0)
            self.golfers.append(p)
        LowNetChampionshipConfig.objects.update_or_create(
            tournament=self.tourn,
            defaults={'payouts': [{'place': 1, 'amount': 50},
                                  {'place': 2, 'amount': 30}],
                      'entry_fee': 10})
    def _day_bet(self, payouts=None):
        """Configured per test, not in setUp — this class inherits the
        endpoint tests, and one of them asserts an UNCONFIGURED round."""
        self.client.post(
            self._setup_url(self.r2),
            {'entry_fee': '4.00',
             'payouts': payouts or [{'place': 1, 'amount': 24}]},
            format='json')

    def _standings(self, ranks):
        """Patch the championship standings to the shape under test.

        `ranks` is one (rank, payout) per golfer, in order. Patched rather
        than played out because the subject is the EXCLUSION rule, and a real
        36-hole tie would be a fixture that says nothing about it.
        """
        rows = [{'player_id': g.id, 'rank': rank, 'payout': payout}
                for g, (rank, payout) in zip(self.golfers, ranks)]
        return rows

    def _in_money(self, ranks):
        from unittest.mock import patch
        from services import day_bet
        with patch('services.low_net_championship.'
                   'low_net_championship_standings',
                   return_value=self._standings(ranks)):
            return day_bet._championship_money_ids(self.tourn)

    def test_clean_first_and_second_are_out(self):
        out = self._in_money([(1, 50), (2, 30)] + [(i, 0) for i in range(3, 9)])
        self.assertEqual(set(out), {self.golfers[0].id, self.golfers[1].id})
        self.assertEqual(out[self.golfers[0].id], '1st')
        self.assertEqual(out[self.golfers[1].id], '2nd')

    def test_two_tied_for_FIRST_are_still_out(self):
        """They occupy 1st and 2nd. Both places pay, so nothing is diluted
        into a place paying nothing — that is a clean win between them."""
        out = self._in_money([(1, 40), (1, 40)] + [(i, 0) for i in range(3, 9)])
        self.assertEqual(set(out), {self.golfers[0].id, self.golfers[1].id})
        self.assertEqual(out[self.golfers[0].id], 'T1st')

    def test_two_tied_for_SECOND_come_back_in(self):
        """They occupy 2nd and 3rd; 3rd pays nothing. $15 each, so they play
        the day bet like anybody else."""
        out = self._in_money([(1, 50), (2, 15), (2, 15)]
                             + [(i, 0) for i in range(4, 9)])
        self.assertEqual(set(out), {self.golfers[0].id})

    def test_the_pot_grows_by_the_two_who_came_back(self):
        """Paul's arithmetic, which is the whole point: 8 golfers, only 1st
        out, 7 paying $4 = $28 — up from $24 when 1st and 2nd were both out.
        """
        from unittest.mock import patch
        from services.day_bet import day_bet_summary

        clean = [(1, 50), (2, 30)] + [(i, 0) for i in range(3, 9)]
        tied  = [(1, 50), (2, 15), (2, 15)] + [(i, 0) for i in range(4, 9)]
        self._day_bet()
        from scoring.models import HoleScore
        # Scored in the FINAL round, which is the one the day bet reads.
        for g in self.golfers:
            HoleScore.objects.create(foursome=self.fs2, player=g,
                                     hole_number=1, gross_score=4)
        with patch('services.low_net_championship.'
                   'low_net_championship_standings',
                   return_value=self._standings(clean)):
            self.assertEqual(day_bet_summary(self.r2)['pool'], 24.0)
        with patch('services.low_net_championship.'
                   'low_net_championship_standings',
                   return_value=self._standings(tied)):
            self.assertEqual(day_bet_summary(self.r2)['pool'], 28.0)

    def test_a_three_way_tie_for_second_also_comes_back(self):
        """Three sharing 2nd, 3rd and 4th — two of those pay nothing."""
        out = self._in_money([(1, 50), (2, 10), (2, 10), (2, 10)]
                             + [(i, 0) for i in range(5, 9)])
        self.assertEqual(set(out), {self.golfers[0].id})

    def test_a_three_way_tie_for_first_comes_back_too(self):
        """Not an oversight: with two paying places they occupy 1st, 2nd and
        3rd, and 3rd pays nothing, so they are diluted exactly like a tie for
        last. Nobody won cleanly.
        """
        out = self._in_money([(1, 26.67), (1, 26.67), (1, 26.66)]
                             + [(i, 0) for i in range(4, 9)])
        self.assertEqual(out, {})


class ThePotIsSharedInTheConfiguredProportionsTests(_DayBetBase):
    """The table is a SHAPE; the pot is the money.

    The eligible count is not knowable when the TD sets the table — a tie for
    the last paying championship place puts two golfers back in and adds
    their entries — so $24 configured can become a $28 pot with $4 belonging
    to nobody. Paul: "we have to proportionally allocate the additional money
    if there is more than 1 place paid."
    """

    def test_one_place_takes_the_whole_pot(self):
        from services.day_bet import scale_to_pool
        self.assertEqual(scale_to_pool({1: 24.0}, 28.0), {1: 28.0})

    def test_two_places_split_the_surplus_in_proportion(self):
        from services.day_bet import scale_to_pool
        # 18/6 is 75/25, so a $28 pot pays 21/7 — not 22/6, which would give
        # the whole surplus to the winner.
        self.assertEqual(scale_to_pool({1: 18.0, 2: 6.0}, 28.0),
                         {1: 21.0, 2: 7.0})

    def test_it_shrinks_as_well_as_grows(self):
        """A short field is the same arithmetic. A table promising more than
        the pot holds would have the TD paying the difference."""
        from services.day_bet import scale_to_pool
        self.assertEqual(scale_to_pool({1: 18.0, 2: 6.0}, 12.0),
                         {1: 9.0, 2: 3.0})

    def test_the_payouts_always_sum_to_the_pot(self):
        """To the cent, including the thirds that do not divide. A pot short
        a penny is a penny somebody makes up at the desk.
        """
        from services.day_bet import scale_to_pool
        for pool in (28.0, 29.0, 31.0, 100.0, 7.0):
            for table in ({1: 10.0, 2: 6.0, 3: 3.0}, {1: 1.0, 2: 1.0, 3: 1.0}):
                got = scale_to_pool(table, pool)
                self.assertAlmostEqual(sum(got.values()), pool, places=2,
                                       msg=f'{table} over {pool} -> {got}')

    def test_the_remainder_goes_to_first(self):
        from services.day_bet import scale_to_pool
        got = scale_to_pool({1: 1.0, 2: 1.0, 3: 1.0}, 10.0)
        self.assertEqual(sum(got.values()), 10.0)
        self.assertGreaterEqual(got[1], got[2])

    def test_an_empty_table_is_left_alone(self):
        """No places configured is "we are not paying anybody", not "give
        somebody the pot"."""
        from services.day_bet import scale_to_pool
        self.assertEqual(scale_to_pool({}, 28.0), {})

    def test_an_empty_pot_leaves_the_table_as_written(self):
        """Nobody eligible yet — showing the configured figures is more
        honest than showing zeroes, and the board is flagged provisional."""
        from services.day_bet import scale_to_pool
        self.assertEqual(scale_to_pool({1: 24.0}, 0.0), {1: 24.0})


class TheNumbersAddUpTests(_DayBetBase):
    """What the board pays equals what the pot holds. To the cent.

    Paul, 10 Oct 2026: "I am more concerned that the numbers add up." Two
    separate ways they did not.

    `scale_to_pool` fixed the first — a table of $160 paying out of a $120
    pot. This covers the second, which only bites on a TIE: `split_tied_places`
    returns one figure per RANK, so three golfers sharing $100 are each handed
    $33.33 and the board pays $99.99, while $200 three ways pays $200.01 and
    invents a penny. `split_to_cents` is the module's own answer and needs a
    figure per GOLFER.
    """

    def setUp(self):
        super().setUp()
        from core.models import Player, Tee
        from tournament.models import Foursome, FoursomeMembership
        tee = Tee.objects.filter(course=self.r1.course).first()
        self.fs2 = Foursome.objects.create(round=self.r2, group_number=1)
        # FOUR golfers, because three paying the same entry and all tying
        # divides exactly every time — each gets his own entry back. The odd
        # cent needs a pot that does not divide by the size of the tie.
        self.golfers = []
        for i in range(4):
            p = Player.objects.create(account=self.acct, name=f'G{i}',
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(foursome=self.fs2, player=p,
                                              tee=tee, course_handicap=0,
                                              playing_handicap=0)
            self.golfers.append(p)

    def _board(self, entry, payouts, scores):
        """Three golfers, all eligible, scoring `scores` on hole 1."""
        from scoring.models import HoleScore
        from services.day_bet import day_bet_summary
        self.client.post(self._setup_url(self.r2),
                         {'entry_fee': str(entry), 'payouts': payouts},
                         format='json')
        for g, sc in zip(self.golfers, scores):
            HoleScore.objects.create(foursome=self.fs2, player=g,
                                     hole_number=1, gross_score=sc)
        return day_bet_summary(self.r2)

    def test_a_three_way_tie_pays_the_pot_exactly(self):
        """Four golfers at $25 is a $100 pot; three tie for it. $100 three
        ways is $33.333, and three roundings pay $99.99 — a penny left in a
        pot nobody is holding."""
        s = self._board(25, [{'place': 1, 'amount': 100}], [4, 4, 4, 9])
        paid = sum(r['payout'] or 0 for r in s['results'])
        self.assertEqual(s['pool'], 100.0)
        self.assertEqual(round(paid, 2), 100.0)

    def test_it_does_not_invent_a_penny_either(self):
        """The other direction: $200 three ways rounds UP to $66.67 each and
        pays $200.01 — a penny the TD has to find."""
        s = self._board(50, [{'place': 1, 'amount': 200}], [4, 4, 4, 9])
        paid = sum(r['payout'] or 0 for r in s['results'])
        self.assertEqual(s['pool'], 200.0)
        self.assertEqual(round(paid, 2), 200.0)

    def test_the_odd_cent_lands_on_one_golfer_not_spread(self):
        """Stated and deterministic beats evenly wrong: somebody is handed
        the extra cent rather than three golfers each being a third of one
        out."""
        s = self._board(25, [{'place': 1, 'amount': 100}], [4, 4, 4, 9])
        paid = sorted(r['payout'] for r in s['results'] if r['payout'])
        self.assertEqual(len(paid), 3)
        self.assertEqual(len(set(paid)), 2)       # two the same, one a cent up
        self.assertEqual(round(max(paid) - min(paid), 2), 0.01)

    def test_no_tie_is_still_exact(self):
        s = self._board(10, [{'place': 1, 'amount': 20},
                             {'place': 2, 'amount': 10}], [3, 4, 5, 6])
        paid = sum(r['payout'] or 0 for r in s['results'])
        self.assertEqual(round(paid, 2), s['pool'])

    def test_every_shape_balances(self):
        """The invariant itself, over the awkward divisions."""
        from services.day_bet import scale_to_pool, split_to_cents
        for pool in (28.0, 100.0, 200.0, 7.0, 33.0):
            for table in ({1: 24.0}, {1: 18.0, 2: 6.0}, {1: 10.0, 2: 6.0,
                                                         3: 3.0}):
                places = scale_to_pool(table, pool)
                self.assertAlmostEqual(sum(places.values()), pool, places=2)
                for n in (1, 2, 3, 4):
                    pooled = sum(places.get(1 + j, 0.0) for j in range(n))
                    self.assertAlmostEqual(
                        sum(split_to_cents(pooled, n)), pooled, places=2,
                        msg=f'{table} over {pool}, {n}-way tie')
