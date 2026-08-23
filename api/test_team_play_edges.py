"""
api/test_team_play_edges.py
---------------------------
Foursome Play on the paths the main suites do not walk.

Everything in `api/test_team_play_scoring.py` plays a FINISHED SCRAMBLE, which
is how three separate arithmetic faults survived it — the whole allowance taken
off a part round, a shamble's par not multiplied by the ball count, and a
shamble allocating strokes off 100%. So this file deliberately plays the other
combinations: shambles, part rounds, three-man teams, and the money that hangs
off them.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import (
    Foursome, FoursomeMembership, Round, TeamPlayConfig, Tournament,
)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    """Two teams: one of four, one of three so the phantom is always in play."""

    FOUR  = [('Mercer', 5), ('Ellis', 12), ('Barrueta', 16), ('Vaughn', 24)]
    THREE = [('Bellini', 9), ('Kwan', 15), ('Ortega', 23)]

    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Saturday', start_date=date(2026, 6, 6),
            total_rounds=1, active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')

        self.players = {}
        self.teams = {}
        for i, (name, roster) in enumerate(
                [('Slate', self.FOUR), ('Dune', self.THREE)], start=1):
            fs = Foursome.objects.create(round=self.round, group_number=i,
                                         name=name)
            self.teams[name] = fs
            for golfer, hcp in roster:
                p = Player.objects.create(account=self.acct, name=golfer,
                                          handicap_index=Decimal(hcp))
                self.players[golfer] = p
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=hcp, playing_handicap=hcp)

    def configure(self, **kw):
        body = {'team_format': 'scramble', 'drive_rule': 'none',
                'entry_fee': '25.00', 'places_paid': 1, 'split_pcts': [100]}
        body.update(kw)
        r = self.client.post(reverse('api-team-play-setup',
                                     args=[self.tourn.id]), body, format='json')
        self.assertEqual(r.status_code, 200, r.content)

    def board(self):
        return self.client.get(
            reverse('api-team-play-leaderboard', args=[self.tourn.id])).json()

    def settlement(self):
        return self.client.get(
            reverse('api-team-play-settlement', args=[self.tourn.id])).json()

    def row(self, name):
        return next(t for t in self.board()['teams'] if t['name'] == name)

    def scramble_round(self, team, gross_per_hole=4, holes=18):
        url = reverse('api-team-play-score', args=[self.teams[team].id])
        for h in range(1, holes + 1):
            self.client.post(url, {'hole_number': h,
                                   'gross_score': gross_per_hole},
                             format='json')

    def shamble_round(self, team, gross=5, holes=18):
        fs = self.teams[team]
        for h in range(1, holes + 1):
            for m in fs.memberships.all():
                HoleScore.objects.update_or_create(
                    foursome=fs, player=m.player, hole_number=h,
                    defaults={'gross_score': gross})


# ---------------------------------------------------------------------------
# The phantom, on a shamble
# ---------------------------------------------------------------------------

class ShamblePhantomTests(_Base):

    def test_the_phantom_gets_a_ball_and_an_allowance(self):
        """A three-man team hits four balls — that is the whole point of the
        phantom — so its ball takes a score and a handicap like any other."""
        self.configure(team_format='shamble')
        card = self.client.get(
            reverse('api-team-play-card', args=[self.teams['Dune'].id]),
            {'hole': 1}).json()

        rows = card['shamble']['rows']
        self.assertEqual(len(rows), 4)
        phantom = next(r for r in rows if r['is_phantom'])
        # Average of 9, 15, 23 is 16; at the two-ball 85% that is 14.
        self.assertEqual(phantom['handicap'], 14)

    def test_the_phantoms_ball_can_count(self):
        self.configure(team_format='shamble')
        fs = self.teams['Dune']
        phantom = fs.memberships.get(player__is_phantom=True).player
        # Everyone makes 6; the phantom makes 3, so it must be one of the two.
        for m in fs.memberships.all():
            HoleScore.objects.create(
                foursome=fs, player=m.player, hole_number=1,
                gross_score=3 if m.player_id == phantom.id else 6)

        hole = self.client.get(
            reverse('api-team-play-card', args=[fs.id]), {'hole': 1},
        ).json()['shamble']
        counted = [r for r in hole['rows'] if r['counts']]
        self.assertIn(True, [r['is_phantom'] for r in counted])


# ---------------------------------------------------------------------------
# Money, on the paths the scramble suite never reaches
# ---------------------------------------------------------------------------

class SettlementEdgeTests(_Base):

    def test_settle_is_blocked_while_a_team_is_still_out(self):
        """Money does not move while a score can."""
        self.configure()
        self.scramble_round('Slate')
        self.scramble_round('Dune', holes=9)

        s = self.settlement()
        self.assertFalse(s['can_settle'])
        self.assertIn('Dune', s['waiting_on'])

    def test_a_shamble_settles_and_balances(self):
        self.configure(team_format='shamble', entry_fee='25.00',
                       places_paid=1, split_pcts=[100])
        self.shamble_round('Slate', gross=5)
        self.shamble_round('Dune', gross=6)

        s = self.settlement()
        self.assertTrue(s['can_settle'])
        # 7 golfers × $25. The phantom is not one of them.
        self.assertEqual(s['golfers'], 7)
        self.assertEqual(s['pool'], 175.0)
        self.assertEqual(s['balance'], 0.0)

    def test_a_three_man_winner_splits_three_ways(self):
        """Dune plays three, so its share divides three ways and pays more
        each — the phantom earned the strokes and cannot be paid."""
        self.configure()
        self.scramble_round('Dune', gross_per_hole=3)     # 54, wins
        self.scramble_round('Slate', gross_per_hole=5)    # 90

        block = self.settlement()['blocks'][0]
        team  = block['teams'][0]
        self.assertEqual(team['name'], 'Dune')
        self.assertEqual(team['ways'], 3)
        self.assertTrue(team['phantom'])
        self.assertEqual(len(team['golfers']), 3)
        self.assertNotIn('Phantom 4th', [g['name'] for g in team['golfers']])
        self.assertAlmostEqual(
            sum(g['amount'] for g in team['golfers']), 175.0, places=2)


# ---------------------------------------------------------------------------
# The drive penalty, on a shamble
# ---------------------------------------------------------------------------

class ShambleDrivePenaltyTests(_Base):

    def test_two_strokes_a_missing_drive_reaches_the_board(self):
        """The requirement applies to BOTH formats — a shamble chooses a tee
        shot exactly as a scramble does — so the penalty has to land on a
        shamble's gross too."""
        self.configure(team_format='shamble', drive_rule='per_eighteen',
                       drives_required=1, drive_penalty='two_strokes')
        self.shamble_round('Slate', gross=5)

        row = self.row('Slate')
        # Four drives owed, none taken → eight strokes on the gross.
        self.assertEqual(row['drive']['shortfall'], 4)
        self.assertEqual(row['drive']['penalty_strokes'], 8)
        # 18 holes, best 2 of four 5s = 180 counted, plus the 8.
        self.assertEqual(row['gross'], 188)

    def test_warn_only_leaves_the_gross_alone(self):
        self.configure(team_format='shamble', drive_rule='per_eighteen',
                       drives_required=1, drive_penalty='warn')
        self.shamble_round('Slate', gross=5)

        row = self.row('Slate')
        self.assertEqual(row['drive']['shortfall'], 4)
        self.assertEqual(row['drive']['penalty_strokes'], 0)
        self.assertEqual(row['gross'], 180)


# ---------------------------------------------------------------------------
# Payload shape — the class of bug that keeps reaching the client
# ---------------------------------------------------------------------------

class BoardShapeTests(_Base):
    """Every key on a board row must hold the SAME TYPE for both formats.

    Two crashes have now come from a field changing shape between the scramble
    and shamble paths — `allowance` (block vs int) and `golfers_by_hole` (list
    vs map). The client casts each key once; a key that is a list on one path
    and a map on the other takes the board down.
    """

    TYPES = {
        'allowance'      : dict,
        'drive'          : dict,
        'members'        : list,
        'pars'           : dict,
        'stroke_indexes' : dict,
        'scores_by_hole' : dict,
        'strokes_by_hole': dict,
        'golfers_by_hole': list,
        'by_hole'        : dict,
    }

    def _assert_shapes(self, fmt):
        for key, want in self.TYPES.items():
            for team in self.board()['teams']:
                self.assertIsInstance(
                    team[key], want,
                    f'{fmt}: {key} on {team["name"]} is {type(team[key])}')

    def test_scramble_row_shapes(self):
        self.configure(team_format='scramble')
        self.scramble_round('Slate', holes=3)
        self._assert_shapes('scramble')

    def test_shamble_row_shapes(self):
        self.configure(team_format='shamble')
        self.shamble_round('Slate', holes=3)
        self._assert_shapes('shamble')


# ---------------------------------------------------------------------------
# The ball count → allowance chain, end to end
# ---------------------------------------------------------------------------

class BallCountAllowanceTests(_Base):

    def test_a_grid_averaging_over_two_takes_95_percent(self):
        """The packet's own case: a per-hole grid averaging 2.3 gets 95%
        suggested rather than 85%, because the mapping is a CEILING — a round
        that ever asks for three balls is a three-ball round for allowance."""
        counts = {str(h): (3 if h <= 6 else 2) for h in range(1, 19)}
        self.configure(team_format='shamble', ball_count_mode='per_hole',
                       ball_counts=counts)

        board = self.board()
        self.assertEqual(board['teams'][0]['allowance']['pct'], 95)

    def test_escalating_averages_two_and_takes_85(self):
        self.configure(team_format='shamble', ball_count_mode='escalating')
        summary = self.client.get(
            reverse('api-team-play', args=[self.tourn.id])).json()
        self.assertEqual(summary['ball_count']['counted'], 36)
        self.assertEqual(summary['teams'][0]['allowance']['pct'], 85)


class GenericBoardTests(_Base):
    """A per-golfer stroke total is not a score anybody played in this shape,
    so the generic round board must not offer one."""

    def _games(self):
        r = self.client.get(
            reverse('api-leaderboard', args=[self.round.id]))
        self.assertEqual(r.status_code, 200, r.content)
        return (r.json().get('games') or {})

    def test_no_stroke_play_tab_on_a_scramble(self):
        self.configure(team_format='scramble')
        self.assertNotIn('low_net_round', self._games())

    def test_no_stroke_play_tab_on_a_shamble(self):
        """A shamble DOES have four individual balls, which is why it needs
        saying: the competition is the team's counted best-N off a format
        allowance, so ranking the four individually invents a contest nobody
        entered."""
        self.configure(team_format='shamble')
        self.assertNotIn('low_net_round', self._games())

    def test_an_ordinary_round_still_gets_one(self):
        """The exclusion is this shape's, not everybody's."""
        other = Round.objects.create(
            account=self.acct, course=self.round.course,
            round_number=2, status='in_progress')
        r = self.client.get(reverse('api-leaderboard', args=[other.id]))
        self.assertIn('low_net_round', (r.json().get('games') or {}))


class DriveSlackTests(_Base):
    """`free_left` is what a captain actually uses: holes left that are not
    already spoken for. "4 required of 9" does not tell him whether the long
    hitter can have the par 5."""

    def test_two_a_nine_leaves_one_free_at_the_start(self):
        self.configure(drive_rule='per_nine', drives_required=2)
        front = self.row('Slate')['drive']['windows'][0]
        # Four golfers at two each is eight of the nine holes.
        self.assertEqual(front['required'], 8)
        self.assertEqual(front['holes_left'], 9)
        self.assertEqual(front['owed'], 8)
        self.assertEqual(front['free_left'], 1)

    def test_the_slack_closes_as_holes_go_by(self):
        self.configure(drive_rule='per_nine', drives_required=2)
        fs  = self.teams['Slate']
        url = reverse('api-team-play-drive', args=[fs.id])
        ids = [m.player_id for m in fs.memberships.all()]
        # Hole 1 to a golfer who owes: eight holes left, seven owed.
        self.client.post(url, {'hole_number': 1, 'player_id': ids[0]},
                         format='json')
        self.scramble_round('Slate', holes=1)

        front = self.row('Slate')['drive']['windows'][0]
        self.assertEqual(front['owed'], 7)
        self.assertEqual(front['holes_left'], 8)
        self.assertEqual(front['free_left'], 1)

    def test_a_wasted_hole_spends_the_slack(self):
        """Giving hole 1 to somebody who has already driven leaves eight holes
        for eight owed drives — no room left at all."""
        self.configure(drive_rule='per_nine', drives_required=1)
        fs  = self.teams['Slate']
        url = reverse('api-team-play-drive', args=[fs.id])
        ids = [m.player_id for m in fs.memberships.all()]
        for hole in (1, 2):
            self.client.post(url, {'hole_number': hole, 'player_id': ids[0]},
                             format='json')
        self.scramble_round('Slate', holes=2)

        front = self.row('Slate')['drive']['windows'][0]
        self.assertEqual(front['owed'], 3)        # three golfers still owe
        self.assertEqual(front['holes_left'], 7)
        self.assertEqual(front['free_left'], 4)


class NetLineTests(_Base):
    """The board and the card both carry a net-to-par line, and the dots have
    to survive the allowance being popped off the merged dict."""

    def test_a_scramble_row_has_dots_and_a_net_line(self):
        self.configure()
        self.scramble_round('Slate', gross_per_hole=4, holes=9)
        row = self.row('Slate')

        # Slate plays off 8; stroke index equals hole number, so holes 1-8
        # carry a stroke and the dots must be there.
        self.assertTrue(row['strokes_by_hole'],
                        'the dots vanished when allowance was popped')
        self.assertEqual(row['strokes_by_hole']['1'], 1)
        # Level par gross on hole 1, one stroke → one under net.
        self.assertEqual(row['to_par_by_hole']['1'], 0)
        self.assertEqual(row['net_to_par_by_hole']['1'], -1)

    def test_a_shamble_net_line_reads_against_the_ball_count(self):
        self.configure(team_format='shamble')
        self.shamble_round('Slate', gross=5, holes=1)
        row = self.row('Slate')
        # Best two 5s is 10 against a par of 8 → +2 gross.
        self.assertEqual(row['to_par_by_hole']['1'], 2)
        # Slate is 5/12/16/24, so at 85% it plays off 4/10/14/20. On stroke
        # index 1 that is one stroke each except Vaughn, who is over 18 and
        # takes two. Nets are 4/4/4/3, the best two are 3 and 4, and 7 against
        # a par of 8 is one under.
        self.assertEqual(row['net_to_par_by_hole']['1'], -1)


class BoardSortTests(_Base):
    """The board prints to par, so it has to rank on to par.

    Ranking on the raw net total contradicts the column the moment teams are
    at different points in the round: nine holes of net 30 is not better than
    eighteen of net 70.
    """

    def test_the_bigger_allowance_wins_off_the_same_gross(self):
        """Slate plays off 8 (5/12/16/24 → 1.25+2.40+2.40+2.40 = 8.45) and Dune
        off 10 (9/15/23 plus a phantom 16 → 2.25+3.00+2.40+2.30 = 9.95). Level
        gross for both, so Dune is two further under and leads."""
        self.configure()
        self.scramble_round('Slate', gross_per_hole=4)   # 72, level
        self.scramble_round('Dune',  gross_per_hole=4)   # 72, level

        board = self.board()['teams']
        self.assertEqual(board[0]['name'], 'Dune')
        self.assertEqual(board[0]['net_to_par'], -10)
        self.assertEqual(board[1]['net_to_par'], -8)

    def test_a_part_round_does_not_jump_the_field_on_raw_total(self):
        """Slate finishes; Dune has played five holes and has a much smaller
        net TOTAL. Ranked on totals Dune leads, which is nonsense."""
        self.configure()
        self.scramble_round('Slate', gross_per_hole=4)
        self.scramble_round('Dune', gross_per_hole=4, holes=5)

        board = self.board()['teams']
        dune  = next(t for t in board if t['name'] == 'Dune')
        slate = next(t for t in board if t['name'] == 'Slate')

        self.assertLess(dune['net'], slate['net'])            # smaller total…
        self.assertLess(slate['net_to_par'], dune['net_to_par'])  # …worse round
        self.assertEqual(board[0]['name'], 'Slate')

    def test_equal_to_par_is_a_tie(self):
        """Dune's two extra strokes of allowance make 74 gross worth exactly
        what Slate's 72 is."""
        self.configure()
        self.scramble_round('Slate', gross_per_hole=4)        # 72 → net 64
        self.scramble_round('Dune',  gross_per_hole=4)
        url = reverse('api-team-play-score', args=[self.teams['Dune'].id])
        for hole in (1, 2):                                   # 74 → net 64
            self.client.post(url, {'hole_number': hole, 'gross_score': 5},
                             format='json')

        board = self.board()['teams']
        self.assertEqual(board[0]['net_to_par'], board[1]['net_to_par'])
        self.assertTrue(board[0]['tied'])
        self.assertTrue(board[1]['tied'])
        self.assertEqual(board[0]['rank'], board[1]['rank'])


class ShambleCardSummaryTests(_Base):
    """The card's summary reads the SERVER's to-par figure.

    Recomputing it client-side from `pars` means summing one par a hole, and a
    shamble's team score is two balls — which is how the line came to read
    "+57" through ten holes.
    """

    def test_the_card_carries_a_net_to_par_for_a_shamble(self):
        self.configure(team_format='shamble')
        self.shamble_round('Slate', gross=5, holes=10)

        card = self.client.get(
            reverse('api-team-play-card', args=[self.teams['Slate'].id]),
            {'hole': 1}).json()
        rnd = card['round']

        self.assertEqual(rnd['thru'], 10)
        # Ten par-4s at best-2 is a par of 80, not 40.
        self.assertEqual(rnd['par_played'], 80)
        # Whatever the golfers shot, the figure has to be in a sane range —
        # a client summing single pars would land near +40 here.
        self.assertIsNotNone(rnd['net_to_par'])
        self.assertLess(abs(rnd['net_to_par']), 20)
        self.assertEqual(rnd['net_to_par'], rnd['net'] - rnd['par_played'])
