"""A SPARSE skins pool inside a tournament — the side game the TD's own draw
already has everything for.

Paul, 3 Nov 2026, after a 60-player event: *"all of the grouping info is in
the 60 person tournament and there is no need to make me redo the groupings as
an independent round."* Which is right, and it is also what `MultiSkinsGame`
has always been — a round-level pool with an EXPLICIT roster, whose players
"may belong to any foursome in this round". The watch-link machinery exists
only because a CASUAL pool spans independent rounds; a tournament round
already holds the field.

What these pin is the part that is genuinely different, and it is all about
not touching the TD's draw:

* a tournament pool's roster is this round's own golfers and nobody else;
* `reconcile_pool_seating` does nothing here — on a casual round it prunes the
  scoreless solo seats it made itself, and in a tournament a scoreless group
  of one is a real pairing;
* the boundary REFUSES an outsider by name rather than dropping him silently.
"""
from decimal import Decimal
from datetime import date

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from games.models import MultiSkinsGame
from tournament.models import Foursome, FoursomeMembership, Round, Tournament

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class TournamentSkinsPoolTests(TestCase):
    """Twelve golfers, three groups of four, in one tournament round."""

    def setUp(self):
        self.acct = Account.objects.create(name='TPSGC')
        self.user = User.objects.create_user(
            username='td', account=self.acct, is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Castlewood')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Fall Classic', start_date=date(2026, 11, 1),
            total_rounds=1, active_games=['low_net'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress',
            active_games=['low_net_round'], bet_unit=Decimal('20.00'))

        self.players = []
        for g in range(3):
            fs = Foursome.objects.create(round=self.round, group_number=g + 1)
            for i in range(4):
                p = Player.objects.create(
                    account=self.acct, name=f'G{g + 1}P{i + 1}',
                    handicap_index=Decimal('10'))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=10, playing_handicap=10)
                self.players.append(p)

    def _post(self, ids, **kw):
        body = {'participant_ids': ids, 'handicap_mode': 'gross',
                'bet_unit': '20.00', **kw}
        return self.client.post(
            reverse('api-multi-skins-setup', args=[self.round.id]),
            body, format='json')

    # ── the roster ────────────────────────────────────────────────────────

    def test_a_subset_of_the_field_is_the_whole_point(self):
        picked = [self.players[0].id, self.players[4].id, self.players[8].id]
        r = self._post(picked)
        self.assertEqual(r.status_code, 201, r.content)
        game = MultiSkinsGame.objects.get(round=self.round)
        self.assertEqual(set(game.participants.values_list('id', flat=True)),
                         set(picked))
        # One golfer from each of the three groups — scored on three cards.
        self.assertEqual(len(r.data['players']), 3)
        self.assertEqual(
            {p['group_number'] for p in r.data['players']}, {1, 2, 3})

    def test_the_pool_is_added_to_the_round_s_games(self):
        self._post([self.players[0].id, self.players[1].id])
        self.round.refresh_from_db()
        self.assertIn('multi_skins', self.round.active_games)
        # And the round keeps the game it was already playing.
        self.assertIn('low_net_round', self.round.active_games)

    # ── the draw is not touched ───────────────────────────────────────────

    def test_the_draw_is_untouched(self):
        before = {fs.id: set(fs.memberships.values_list('player_id', flat=True))
                  for fs in self.round.foursomes.all()}
        self._post([self.players[0].id, self.players[4].id])
        after = {fs.id: set(fs.memberships.values_list('player_id', flat=True))
                 for fs in self.round.foursomes.all()}
        self.assertEqual(before, after)

    def test_a_scoreless_group_of_one_survives(self):
        """The failure this guard exists for.

        On a casual round `reconcile_pool_seating` prunes a scoreless solo
        group, because there it made that seat itself for a participant who
        turned out to play in a linked round. In a tournament a group of one
        is a real pairing — an odd field, a late withdrawal — and the golfer
        in it is usually NOT in the pool, which is exactly the condition the
        prune reads as "dropped from the roster".
        """
        odd = Player.objects.create(account=self.acct, name='Thirteenth',
                                    handicap_index=Decimal('14'))
        fs = Foursome.objects.create(round=self.round, group_number=4)
        FoursomeMembership.objects.create(
            foursome=fs, player=odd, tee=self.tee,
            course_handicap=14, playing_handicap=14)

        self._post([self.players[0].id, self.players[4].id])

        self.assertTrue(Foursome.objects.filter(pk=fs.pk).exists())
        self.assertTrue(
            FoursomeMembership.objects.filter(foursome=fs, player=odd).exists())

    def test_nothing_is_seated_and_no_group_is_added(self):
        n_before = self.round.foursomes.count()
        self._post([self.players[0].id, self.players[4].id, self.players[8].id])
        self.assertEqual(self.round.foursomes.count(), n_before)

    # ── the outsider ──────────────────────────────────────────────────────

    def test_an_outsider_is_refused_by_name(self):
        """He is on Halved, so the casual rule would admit him — and he has no
        card in this round, so he could never win a skin and could never stop
        paying. Refused rather than silently dropped: a TD who ticked him
        would otherwise save, find the name gone and have nothing to read.
        """
        outsider = Player.objects.create(
            account=self.acct, name='Not Playing',
            handicap_index=Decimal('8'), phone='+13105550199')
        User.objects.create_user(username='np', account=self.acct,
                                 phone='+13105550199')
        r = self._post([self.players[0].id, outsider.id])
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(r.data['not_in_round_ids'], [outsider.id])
        self.assertIn('golfers in this round', r.data['detail'])
        self.assertFalse(MultiSkinsGame.objects.filter(round=self.round).exists())

    def test_the_service_is_the_backstop(self):
        """The boundary refuses; the service filters. Both, because the two
        rules live in different functions and only one is reached by every
        caller.

        He is ON HALVED on purpose. A golfer with no verified number is
        dropped by the ordinary on-app clause, so he would pass this test
        against a service with no tournament rule at all — which is what the
        first version of it did.
        """
        from services.multi_skins import setup_multi_skins
        outsider = Player.objects.create(
            account=self.acct, name='Not Playing 2',
            handicap_index=Decimal('8'), phone='+13105550198')
        User.objects.create_user(username='np2', account=self.acct,
                                 phone='+13105550198')
        game = setup_multi_skins(
            self.round,
            participant_ids=[self.players[0].id, self.players[4].id,
                             outsider.id],
            handicap_mode='gross', bet_unit=20.00)
        self.assertEqual(set(game.participants.values_list('id', flat=True)),
                         {self.players[0].id, self.players[4].id})

    # ── it scores off the cards the groups are keeping ─────────────────────

    def test_scores_flow_from_the_groups_own_cards(self):
        from scoring.tests._helpers import submit_hole
        picked = [self.players[0].id, self.players[4].id, self.players[8].id]
        self._post(picked)

        groups = list(self.round.foursomes.order_by('group_number'))
        for hn in (1, 2, 3):
            for gi, fs in enumerate(groups):
                members = list(fs.memberships.select_related('player'))
                submit_hole(fs, hn, [
                    # The pool member in group 1 makes a 3 on hole 1 and pars
                    # the rest; everybody else pars.
                    (m.player,
                     3 if (hn == 1 and gi == 0 and m.player_id == picked[0])
                     else 4)
                    for m in members
                ])

        from services.multi_skins import (
            multi_skins_summary, recalc_pools_for_round,
        )
        recalc_pools_for_round(self.round)
        s = multi_skins_summary(self.round)
        won = {p['player_id']: p['skins_won'] for p in s['players']}
        self.assertEqual(won[picked[0]], 1, won)
        self.assertEqual(s['money']['pool'], 60.0)
        # Winner takes the lot; the whole pool is distributed.
        pay = {p['player_id']: p['payout'] for p in s['players']}
        self.assertEqual(pay[picked[0]], 60.0, pay)
        self.assertEqual(sum(pay.values()), 60.0)


class PoolQueryCostTests(TestCase):
    """What a posted score costs when the pool is big.

    The pool recomputes on EVERY posted score — `recalc_pools_for_round` runs
    for every pool a round hosts or is linked into — so a sixty-player round
    pays this about a thousand times. Measured rather than reasoned about,
    the way the team-play slowdown was.

    First measurement, 15 groups and 20 participants: **82 queries to
    recalculate and 60 to summarise.** Three causes, none of them in shared
    code:

    * `_pool_gross_and_pars` read the gross with ONE QUERY PER PARTICIPANT —
      invisible in a four-handed casual pool, twenty queries here;
    * `_resolve_participant_memberships` is three round-wide queries and one
      pass asked for it twice;
    * `build_score_index` reads each foursome's round for the
      net-double-bogey flag, which was a query per group until the membership
      map started prefetching `foursome__round`.

    Now 43 and 40, and — the part worth guarding — **flat in the number of
    participants**: 20 in the pool and 60 in the pool cost the same. What is
    still linear is the number of GROUPS holding a participant, about two
    queries each, because `build_score_index` is per foursome by design. A
    batched variant of it would help every game in the app and is its own
    piece of work.
    """

    def _build(self, n_groups, n_participants, label):
        acct = Account.objects.create(name=f'Perf {label}')
        User.objects.create_user(username=f'perf{label}', account=acct)
        course = Course.objects.create(account=acct, name='Perf GC')
        tee = Tee.objects.create(course=course, tee_name='W', slope=113,
                                 course_rating=Decimal('72'), par=72,
                                 holes=HOLES)
        t = Tournament.objects.create(
            account=acct, name=f'Perf {label}', start_date=date(2026, 11, 1),
            total_rounds=1, active_games=['low_net'])
        rnd = Round.objects.create(
            account=acct, course=course, tournament=t, round_number=1,
            status='in_progress', active_games=['low_net_round'],
            bet_unit=Decimal('20'))
        players = []
        for g in range(n_groups):
            fs = Foursome.objects.create(round=rnd, group_number=g + 1)
            for i in range(4):
                p = Player.objects.create(account=acct, name=f'{label}-{g}-{i}',
                                          handicap_index=Decimal('10'))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=tee,
                    course_handicap=10, playing_handicap=10)
                players.append(p)

        from scoring.tests._helpers import submit_hole
        from services.multi_skins import setup_multi_skins
        # Spread them across the groups, which is what a pool is.
        step = max(1, len(players) // n_participants)
        picked = [players[i * step].id for i in range(n_participants)]
        setup_multi_skins(rnd, participant_ids=picked, handicap_mode='net',
                          bet_unit=20.00)
        for fs in rnd.foursomes.all():
            ms = list(fs.memberships.select_related('player'))
            for hn in range(1, 10):
                submit_hole(fs, hn, [(m.player, 4 + (m.player_id % 2))
                                     for m in ms])
        return rnd

    def _cost(self, rnd):
        from services.multi_skins import (
            multi_skins_summary, recalc_pools_for_round,
        )
        with CaptureQueriesContext(connection) as c1:
            recalc_pools_for_round(rnd)
        with CaptureQueriesContext(connection) as c2:
            multi_skins_summary(rnd)
        return len(c1.captured_queries), len(c2.captured_queries)

    def test_a_posted_score_stays_under_fifty_queries(self):
        recalc, summary = self._cost(self._build(15, 20, 'a'))
        self.assertLess(recalc, 50, f'recalc {recalc}')
        self.assertLess(summary, 45, f'summary {summary}')

    def test_the_cost_does_not_grow_with_the_size_of_the_pool(self):
        """The invariant the N+1 fix created, and the one a new one breaks.

        Twenty of sixty in the pool and all sixty in it touch the same
        fifteen groups, so they must cost the same. A per-participant query
        reintroduced anywhere below `recalc_pools_for_round` fails here and
        nowhere else — the ceiling above it has slack, and a four-handed
        casual pool would not notice at all.
        """
        twenty = self._cost(self._build(15, 20, 'b'))
        sixty  = self._cost(self._build(15, 60, 'c'))
        self.assertEqual(twenty, sixty, f'{twenty} vs {sixty}')
