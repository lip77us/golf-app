"""
api/test_team_play_perf.py
--------------------------
What a Team Play request COSTS, at the size one is actually played at.

Reported from the course on 29 Oct 2026: *"The app was very slow today. First
time playing 2 person scramble."* — TPSGC Fall Scramble 2026, fourteen groups
of four paired into twenty-eight two-man teams, scored live.

These are not correctness tests. They pin the query COUNT of the three calls
that screen makes, because this codebase's recurring performance shape is a
builder that is cheap for one row and is then called once per row: the memory
note on round 420 records `board_recipients` walking the whole round with no
`select_related` for ~45 queries a score, and `triple_cup_summary` recomputed
three times in one recalculation.

**These are ceilings over TODAY's measured cost, not a target.** Measured
29 Oct 2026 at the real size, and both of the reads are linear in the FIELD:

    groups  teams   card   board
         1      2     55      41
         2      4     66      78
         4      8     88     152
        14     28    198     522

The board is ~18.6 queries per team. The card is worse than it looks: it is
a GROUP-scoped screen, fetched on every hole change and after every score,
and it pays ~11 queries for every OTHER group in the field — because it calls
`field_standing` for the team's place, which ranks everybody through the same
unprefetched per-team builders the board uses.

Neither scales with holes played; 198 and 522 are flat from hole 1 to 18.

Beat these and tighten the numbers.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import (
    Foursome, FoursomeMembership, Round, Tournament,
)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]

# The real event: 14 groups × 4 golfers = 56, paired into 28 teams.
GROUPS = 14


class TeamPlayPairsCostTests(TestCase):

    def setUp(self):
        self.acct = Account.objects.create(name='TPSGC')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park GC')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Fall Scramble',
            start_date=date(2026, 10, 27), total_rounds=1,
            active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')

        self.groups = []
        for g in range(1, GROUPS + 1):
            fs = Foursome.objects.create(round=self.round, group_number=g)
            self.groups.append(fs)
            for i in range(4):
                p = Player.objects.create(
                    account=self.acct, name=f'G{g} Golfer {i}',
                    handicap_index=Decimal(6 + i * 4))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=6 + i * 4, playing_handicap=6 + i * 4)

        r = self.client.post(
            reverse('api-team-play-setup', args=[self.tourn.id]),
            {'team_format': 'scramble', 'team_size': 2,
             'drive_rule': 'per_18', 'entry_fee': '20.00',
             'places_paid': 3, 'split_pcts': [50, 30, 20]}, format='json')
        assert r.status_code in (200, 201), r.content

        # Two teams in every group, which is what makes this event 28 rows.
        for fs in self.groups:
            self.client.post(reverse('api-team-play-split', args=[fs.id]),
                             {}, format='json')

    def _play(self, holes):
        """Every group through `holes`, as the field would be mid-round."""
        for fs in self.groups:
            for slot in (1, 2):
                for n in range(1, holes + 1):
                    self.client.post(
                        reverse('api-team-play-score', args=[fs.id]),
                        {'hole_number': n, 'gross_score': 4, 'slot': slot},
                        format='json')

    # -- the three calls the screen makes --------------------------------

    def test_the_board_does_not_cost_a_query_per_team(self):
        """28 teams must not mean 28 × N queries."""
        self._play(9)
        url = reverse('api-team-play-leaderboard', args=[self.tourn.id])
        with CaptureQueriesContext(connection) as q:
            r = self.client.get(url)
        self.assertEqual(r.status_code, 200)
        self.assertLessEqual(len(q), 530, f'{len(q)} queries for 28 teams')

    def test_posting_one_score_is_scoped_to_the_group(self):
        """A score in group 3 must not cost anything per OTHER group."""
        self._play(5)
        fs = self.groups[2]
        url = reverse('api-team-play-score', args=[fs.id])
        with CaptureQueriesContext(connection) as q:
            r = self.client.post(url, {'hole_number': 6, 'gross_score': 4,
                                       'slot': 1}, format='json')
        self.assertEqual(r.status_code, 200)
        # The cheap one, and the proof the cost is in the READS: a score in
        # group 3 costs the same whether the field is one group or fourteen.
        self.assertLessEqual(len(q), 25, f'{len(q)} queries to post a score')

    def test_the_card_is_scoped_to_the_group(self):
        """It is NOT, today — 198 of these are the rest of the field."""
        self._play(5)
        fs = self.groups[2]
        url = reverse('api-team-play-card', args=[fs.id])
        with CaptureQueriesContext(connection) as q:
            r = self.client.get(url, {'hole': 6})
        self.assertEqual(r.status_code, 200)
        self.assertLessEqual(len(q), 210, f'{len(q)} queries for ONE group')
