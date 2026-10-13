"""POST /api/foursomes/{id}/sixes/segment-teams/ — the group's match-2 pick.

The engine is covered in `scoring/tests/test_sixes.py`; these cover the wire:
that the rule stays in the service (a locked match answers 400 rather than
500), that the summary carries the two options the picker draws, and that a
stranger cannot redraw somebody else's teams.
"""
from decimal import Decimal

from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(course=course, tee_name='White',
                                      slope=113, course_rating=Decimal('72.0'),
                                      par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, round_number=1,
            status='in_progress', active_games=['sixes'],
            bet_unit=Decimal('5.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.pid = {}
        for name in ('Ann', 'Ben', 'Cal', 'Dee'):
            p = Player.objects.create(account=self.acct, name=name,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.pid[name] = p.id

        from services.sixes import setup_sixes
        base = {'team_select_method': 'long_drive'}
        setup_sixes(self.fs, [
            {**base, 'start_hole': 1, 'end_hole': 6,
             'team1_player_ids': [self.pid['Ann'], self.pid['Ben']],
             'team2_player_ids': [self.pid['Cal'], self.pid['Dee']]},
            {**base, 'start_hole': 7, 'end_hole': 12},
            {**base, 'start_hole': 13, 'end_hole': 18},
        ], handicap_mode='gross')

    def _url(self):
        return reverse('api-sixes-segment-teams', args=[self.fs.id])

    def _options(self):
        return self.client.get(
            reverse('api-sixes-result', args=[self.fs.id])
        ).data['remaining_pairings']

    def _score(self, hole, winner_ids):
        for name, pid in self.pid.items():
            HoleScore.objects.update_or_create(
                foursome=self.fs, player_id=pid, hole_number=hole,
                defaults={'gross_score': 4 if pid in winner_ids else 5,
                          'handicap_strokes': 0})


class SegmentTeamsTests(_Base):
    def test_the_summary_carries_the_two_options(self):
        opts = self._options()
        self.assertEqual(len(opts), 2)
        self.assertEqual(len(opts[0]['team1_player_ids']), 2)
        self.assertTrue(opts[0]['team1_names'][0])

    def test_the_pick_round_trips_and_forces_match_three(self):
        opts = self._options()
        r = self.client.post(self._url(), {
            'segment_number': 2,
            'team1_player_ids': opts[0]['team1_player_ids'],
            'team2_player_ids': opts[0]['team2_player_ids'],
            'team_select_method': 'random',
        }, format='json')
        self.assertEqual(r.status_code, 200, r.content)
        segs = [s for s in r.data['segments'] if not s['is_extra']]
        self.assertEqual(len(segs[1]['team1']['player_ids']), 2)
        self.assertEqual(len(segs[2]['team1']['player_ids']), 2)
        # Still offered: the group may swap before teeing off.
        self.assertEqual(len(r.data['remaining_pairings']), 2)

    def test_a_played_match_answers_400_not_500(self):
        opts = self._options()
        pick = opts[0]
        self.client.post(self._url(), {
            'segment_number': 2,
            'team1_player_ids': pick['team1_player_ids'],
            'team2_player_ids': pick['team2_player_ids'],
        }, format='json')
        self._score(7, set(pick['team1_player_ids']))
        r = self.client.post(self._url(), {
            'segment_number': 2,
            'team1_player_ids': opts[1]['team1_player_ids'],
            'team2_player_ids': opts[1]['team2_player_ids'],
        }, format='json')
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn('already been played', r.data['error'])

    def test_a_missing_segment_number_is_a_400(self):
        r = self.client.post(self._url(), {
            'team1_player_ids': [self.pid['Ann'], self.pid['Cal']],
            'team2_player_ids': [self.pid['Ben'], self.pid['Dee']],
        }, format='json')
        self.assertEqual(r.status_code, 400)

    def test_a_bad_select_method_falls_back_rather_than_failing(self):
        """The method is a note about HOW a pair was chosen, not something a
        hole is scored against, so a junk value is not worth a refusal."""
        opts = self._options()
        r = self.client.post(self._url(), {
            'segment_number': 2,
            'team1_player_ids': opts[0]['team1_player_ids'],
            'team2_player_ids': opts[0]['team2_player_ids'],
            'team_select_method': 'telepathy',
        }, format='json')
        self.assertEqual(r.status_code, 200, r.content)

    def test_a_stranger_cannot_redraw_the_teams(self):
        other = Account.objects.create(name='Someone Else')
        nosy = User.objects.create_user(username='nosy', account=other)
        c = APIClient()
        c.force_authenticate(nosy)
        opts = self._options()
        r = c.post(self._url(), {
            'segment_number': 2,
            'team1_player_ids': opts[0]['team1_player_ids'],
            'team2_player_ids': opts[0]['team2_player_ids'],
        }, format='json')
        self.assertEqual(r.status_code, 404)
