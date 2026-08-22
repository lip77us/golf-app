"""
api/test_team_play_scoring.py
-----------------------------
Team Play scoring, the board and settlement
(docs/design-review/handoff-team-play/SPEC.md §10).

The field, the finishing order and every dollar below are the packet's own
drawn leaderboard and settlement receipt — two ties behaving differently, a
three-man team taking more each, and the odd cents landing on a named man.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import (
    Foursome, FoursomeMembership, Round, TeamPlayConfig, Tournament,
)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]

FIELD = {
    'Pine' : [('Maiolini', 4), ('Gunst', 8),  ('Detomasi', 11), ('Yau', 19)],
    'Clay' : [('Petersen', 6), ('Brown', 9),  ('Labass', 14),   ('Reilly', 21)],
    'Slate': [('Mercer', 5),   ('Ellis', 12), ('Barrueta', 16), ('Vaughn', 24)],
    'Dune' : [('Bellini', 9),  ('Kwan', 15),  ('Ortega', 23)],
    'Fern' : [('Ferraro', 3),  ('Okafor', 13), ('Tran', 17),    ('Nunes', 22)],
    'Rust' : [('Morgan', 7),   ('Mayers', 10), ('Salas', 18),   ('Lipkin', 20)],
}

# Gross totals that reproduce the drawn board once each team's allowance comes
# off: Fern 55, Slate 57, Dune 57, Pine 58, Clay 58, Rust 60.
GROSS = {'Fern': 63, 'Slate': 65, 'Dune': 67, 'Pine': 64, 'Clay': 66, 'Rust': 68}


class TeamPlayScoringTests(TestCase):

    def setUp(self):
        self.acct = Account.objects.create(name='Saturday Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Saturday Scramble',
            start_date=date(2026, 6, 6), total_rounds=1,
            active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')

        self.teams = {}
        for i, (name, members) in enumerate(FIELD.items(), start=1):
            fs = Foursome.objects.create(round=self.round, group_number=i,
                                         name=name)
            self.teams[name] = fs
            for golfer, hcp in members:
                p = Player.objects.create(account=self.acct, name=golfer,
                                          handicap_index=Decimal(hcp))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=hcp, playing_handicap=hcp)

        self.client.post(reverse('api-team-play-setup', args=[self.tourn.id]),
                         {'team_format': 'scramble', 'drive_rule': 'none',
                          'entry_fee': '25.00', 'places_paid': 3,
                          'split_pcts': [50, 30, 20]}, format='json')

    # -- helpers ---------------------------------------------------------

    def _post_round(self, name, total, holes=18):
        """Spread ``total`` over ``holes`` as par-4s with enough birdies."""
        fs  = self.teams[name]
        url = reverse('api-team-play-score', args=[fs.id])
        birdies = holes * 4 - total
        for n in range(1, holes + 1):
            gross = 3 if n <= birdies else 4
            self.client.post(url, {'hole_number': n, 'gross_score': gross},
                             format='json')

    def _play_everyone(self):
        for name, total in GROSS.items():
            self._post_round(name, total)

    def _board(self):
        return self.client.get(
            reverse('api-team-play-leaderboard', args=[self.tourn.id])).json()

    def _settlement(self):
        return self.client.get(
            reverse('api-team-play-settlement', args=[self.tourn.id])).json()

    # -- the card --------------------------------------------------------

    def test_a_scramble_hole_is_one_number(self):
        fs = self.teams['Pine']
        r = self.client.post(reverse('api-team-play-score', args=[fs.id]),
                             {'hole_number': 1, 'gross_score': 4},
                             format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['gross'], 4)
        self.assertEqual(r.json()['thru'], 1)

    def test_the_first_score_locks_the_format(self):
        """A one-number card cannot be re-read as four."""
        fs = self.teams['Pine']
        self.client.post(reverse('api-team-play-score', args=[fs.id]),
                         {'hole_number': 1, 'gross_score': 4}, format='json')
        cfg = TeamPlayConfig.objects.get(tournament=self.tourn)
        self.assertTrue(cfg.is_locked)

        r = self.client.post(reverse('api-team-play-setup', args=[self.tourn.id]),
                             {'team_format': 'shamble'}, format='json')
        self.assertEqual(r.status_code, 409)

    def test_net_is_not_on_the_card_but_the_allowance_is(self):
        """Gross on the card, net on the leaderboard. Showing 6 on the card
        would invite subtracting it per hole."""
        self._post_round('Pine', 64)
        card = self.client.get(
            reverse('api-team-play-card', args=[self.teams['Pine'].id]),
            {'hole': 9}).json()
        self.assertEqual(card['team_score'], 4)
        self.assertEqual(card['round']['allowance'], 6)
        self.assertEqual(card['round']['gross'], 64)

    # -- the board -------------------------------------------------------

    def test_the_packets_leaderboard(self):
        self._play_everyone()
        board = self._board()

        self.assertEqual(
            [(t['name'], t['gross'], t['net'], t['rank'], t['tied'])
             for t in board['teams']],
            [('Fern',  63, 55, 1, False),
             ('Slate', 65, 57, 2, True),
             ('Dune',  67, 57, 2, True),
             ('Pine',  64, 58, 4, True),
             ('Clay',  66, 58, 4, True),
             ('Rust',  68, 60, 6, False)],
        )
        self.assertTrue(board['all_in'])
        self.assertFalse(board['projected'])

    def test_money_is_projected_until_every_team_is_in(self):
        """A team leading through fourteen is not leading, and money on the
        rows would put a dollar figure next to a team with four holes left."""
        self._post_round('Fern', 63)
        self._post_round('Rust', 53, holes=14)
        board = self._board()

        self.assertTrue(board['projected'])
        rust = next(t for t in board['teams'] if t['name'] == 'Rust')
        self.assertEqual(rust['thru'], 14)
        self.assertFalse(rust['complete'])

    def test_a_team_with_no_score_is_not_tied_for_first(self):
        self._post_round('Fern', 63)
        board = self._board()
        pine = next(t for t in board['teams'] if t['name'] == 'Pine')
        self.assertIsNone(pine['rank'])
        self.assertIsNone(pine['net'])

    def test_a_drive_penalty_lands_on_the_gross_at_the_end(self):
        self.client.post(reverse('api-team-play-setup', args=[self.tourn.id]),
                         {'drive_rule': 'per_eighteen', 'drives_required': 2,
                          'drive_penalty': 'two_strokes'}, format='json')
        self._post_round('Pine', 64)
        board = self._board()
        pine = next(t for t in board['teams'] if t['name'] == 'Pine')
        # Eight drives owed, none taken → 16 strokes.
        self.assertEqual(pine['drive']['shortfall'], 8)
        self.assertEqual(pine['gross'], 64 + 16)

    # -- settlement ------------------------------------------------------

    def test_the_packets_settlement(self):
        self._play_everyone()
        s = self._settlement()

        self.assertEqual(s['pool'], 575.0)
        self.assertEqual(s['golfers'], 23)
        self.assertTrue(s['can_settle'])

        first, second = s['blocks'][0], s['blocks'][1]

        # 1st — Fern, four ways, the odd two cents to its highest handicap.
        self.assertEqual(first['rank'], 1)
        self.assertFalse(first['tied'])
        self.assertEqual(first['teams'][0]['amount'], 287.50)
        self.assertEqual(first['teams'][0]['ways'], 4)
        self.assertEqual(
            [(g['name'], g['amount']) for g in first['teams'][0]['golfers']],
            [('Nunes', 71.89), ('Tran', 71.87), ('Okafor', 71.87),
             ('Ferraro', 71.87)],
        )

        # T2 — one prize, both teams inside it: 2nd AND 3rd combined.
        self.assertEqual(second['rank'], 2)
        self.assertTrue(second['tied'])
        self.assertEqual(second['places'], [2, 3])
        self.assertEqual(second['total'], 287.50)
        self.assertEqual({t['name'] for t in second['teams']}, {'Slate', 'Dune'})

        slate = next(t for t in second['teams'] if t['name'] == 'Slate')
        dune  = next(t for t in second['teams'] if t['name'] == 'Dune')
        self.assertEqual(slate['amount'], 143.75)
        self.assertEqual(dune['amount'], 143.75)

        # A three-man team divides three ways and takes more each.
        self.assertEqual(slate['ways'], 4)
        self.assertEqual(dune['ways'], 3)
        self.assertEqual([(g['name'], g['amount']) for g in slate['golfers']],
                         [('Vaughn', 35.96), ('Barrueta', 35.93),
                          ('Ellis', 35.93), ('Mercer', 35.93)])
        self.assertEqual([(g['name'], g['amount']) for g in dune['golfers']],
                         [('Ortega', 47.93), ('Kwan', 47.91),
                          ('Bellini', 47.91)])

    def test_the_phantom_cannot_be_paid(self):
        self._play_everyone()
        dune = next(t for b in self._settlement()['blocks']
                    for t in b['teams'] if t['name'] == 'Dune')
        self.assertTrue(dune['phantom'])
        self.assertEqual(len(dune['golfers']), 3)
        self.assertNotIn('Phantom 4th', [g['name'] for g in dune['golfers']])

    def test_a_tie_for_a_place_that_pays_nothing_costs_nothing(self):
        """Pine and Clay share 4th; 4th and 5th pay nothing, so the tie is left
        unresolved."""
        self._play_everyone()
        s = self._settlement()
        out = {t['name'] for t in s['out_of_money']}
        self.assertEqual(out, {'Pine', 'Clay', 'Rust'})

    def test_the_pool_balances_to_zero(self):
        """A settlement that does not add up is worse than one that is slightly
        arbitrary — which is the whole reason the odd cents are assigned."""
        self._play_everyone()
        self.assertEqual(self._settlement()['balance'], 0.0)

    def test_settle_is_gated_on_every_team_signing(self):
        """Money does not move while a score can."""
        self._post_round('Fern', 63)
        s = self._settlement()
        self.assertFalse(s['can_settle'])
        self.assertIn('Pine', s['waiting_on'])


class ShambleCardTests(TestCase):
    """Four scores a hole, and the card says which counted."""

    def setUp(self):
        self.acct = Account.objects.create(name='Saturday Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Saturday Shamble',
            start_date=date(2026, 6, 6), total_rounds=1,
            active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')

        self.fs = Foursome.objects.create(round=self.round, group_number=1,
                                          name='Clay')
        self.players = {}
        for golfer, hcp in FIELD['Clay']:
            p = Player.objects.create(account=self.acct, name=golfer,
                                      handicap_index=Decimal(hcp))
            self.players[golfer] = p
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=hcp, playing_handicap=0)   # gross, for clarity

        self.client.post(reverse('api-team-play-setup', args=[self.tourn.id]),
                         {'team_format': 'shamble', 'ball_count_mode': 'fixed',
                          'ball_count_fixed': 2, 'drive_rule': 'none',
                          'entry_fee': '25.00', 'places_paid': 1,
                          'split_pcts': [100]}, format='json')

    def test_the_two_lowest_count_and_the_rest_are_greyed(self):
        """The packet's hole 7: 4, 5, 5, 7 — the two lowest count for 8."""
        from scoring.models import HoleScore
        for golfer, gross in (('Petersen', 4), ('Brown', 5),
                              ('Labass', 5), ('Reilly', 7)):
            HoleScore.objects.create(foursome=self.fs,
                                     player=self.players[golfer],
                                     hole_number=7, gross_score=gross)

        card = self.client.get(
            reverse('api-team-play-card', args=[self.fs.id]), {'hole': 7}).json()
        hole = card['shamble']

        self.assertEqual(hole['count'], 2)
        self.assertEqual(hole['team_net'], 9)     # 4 + 5
        counting = {r['name'] for r in hole['rows'] if r['counts']}
        self.assertEqual(counting, {'Petersen', 'Brown'})
        reilly = next(r for r in hole['rows'] if r['name'] == 'Reilly')
        self.assertFalse(reilly['counts'])

    def test_the_count_is_stated_on_every_hole(self):
        """It does not change across the eighteen, and saying so costs one line
        and settles the recurring question at the green."""
        for hole in (1, 9, 18):
            card = self.client.get(
                reverse('api-team-play-card', args=[self.fs.id]),
                {'hole': hole}).json()
            self.assertEqual(card['shamble']['count'], 2)

    def test_a_scramble_score_is_refused_on_a_shamble(self):
        r = self.client.post(reverse('api-team-play-score', args=[self.fs.id]),
                             {'hole_number': 1, 'gross_score': 4},
                             format='json')
        self.assertEqual(r.status_code, 400)


class LeaderboardShapeTests(TeamPlayScoringTests):
    """The board's JSON has to survive a strict client.

    `allowance` is a worked BLOCK on a team row and a plain int on a round;
    merging the two dicts blind replaced one with the other and the Dart model
    crashed casting an int to a map. Shape, not arithmetic — so it is asserted
    on the wire.
    """

    def test_allowance_stays_a_block_on_every_row(self):
        self._play_everyone()
        for team in self._board()['teams']:
            self.assertIsInstance(team['allowance'], dict, team['name'])
            self.assertIn('kind', team['allowance'])
            # ...and the plain figure is still there under its own name.
            self.assertIsInstance(team['team_handicap'], int)

    def test_the_board_round_trips_every_nested_block(self):
        self._play_everyone()
        board = self._board()
        self.assertIsInstance(board['pool'], dict)
        for team in board['teams']:
            self.assertIsInstance(team['drive'], dict)
            self.assertIsInstance(team['members'], list)


class ShambleBoardShapeTests(ShambleCardTests):
    """The board is shared by both formats, so the allowance clobber hit a
    shamble exactly as it hit a scramble. Asserted on the shamble fixture too,
    because 'shared code' is the reason a fix gets tested once and regressed on
    the other path."""

    def test_allowance_stays_a_block(self):
        r = self.client.get(
            reverse('api-team-play-leaderboard', args=[self.tourn.id]))
        self.assertEqual(r.status_code, 200)
        for team in r.json()['teams']:
            self.assertIsInstance(team['allowance'], dict)
            self.assertIn('kind', team['allowance'])
