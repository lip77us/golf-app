"""
api/test_team_play.py
---------------------
Team Play setup / read-model / drive endpoints
(docs/design-review/handoff-team-play/SPEC.md).

The engines are covered by scoring/tests/test_team_handicap.py and
test_team_play_format.py; this is the surface the wizard and the cards talk to,
built on the packet's own field — 23 golfers in six teams, five of four and one
of three.
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

# The packet's six teams, by course handicap. Dune plays three.
FIELD = {
    'Pine' : [('Maiolini', 4), ('Gunst', 8),  ('Detomasi', 11), ('Yau', 19)],
    'Clay' : [('Petersen', 6), ('Brown', 9),  ('Labass', 14),   ('Reilly', 21)],
    'Slate': [('Mercer', 5),   ('Ellis', 12), ('Barrueta', 16), ('Vaughn', 24)],
    'Dune' : [('Bellini', 9),  ('Kwan', 15),  ('Ortega', 23)],
    'Fern' : [('Ferraro', 3),  ('Okafor', 13), ('Tran', 17),    ('Nunes', 22)],
    'Rust' : [('Morgan', 7),   ('Mayers', 10), ('Salas', 18),   ('Lipkin', 20)],
}


class TeamPlayEndpointTests(TestCase):

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

        # One round. Stated, not chosen.
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Saturday Scramble',
            start_date=date(2026, 6, 6), total_rounds=1,
            active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')

        self.teams = {}
        for i, (name, members) in enumerate(FIELD.items(), start=1):
            fs = Foursome.objects.create(round=self.round, group_number=i)
            self.teams[name] = fs
            for golfer, hcp in members:
                p = Player.objects.create(account=self.acct, name=golfer,
                                          handicap_index=Decimal(hcp))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=hcp, playing_handicap=hcp)

    # -- helpers ---------------------------------------------------------

    def _setup_url(self):
        return reverse('api-team-play-setup', args=[self.tourn.id])

    def _board_url(self):
        return reverse('api-team-play', args=[self.tourn.id])

    def _configure(self, **overrides):
        body = {'team_format': 'scramble', 'drive_rule': 'per_nine',
                'drives_required': 1, 'entry_fee': '25.00',
                'places_paid': 3, 'split_pcts': [50, 30, 20]}
        body.update(overrides)
        return self.client.post(self._setup_url(), body, format='json')

    def _team(self, body, name):
        return next(t for t in body['teams'] if t['name'] == name)

    # -- setup -----------------------------------------------------------

    def test_defaults_before_anything_is_configured(self):
        r = self.client.get(self._setup_url())
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertFalse(body['configured'])
        self.assertEqual(body['team_format'], 'scramble')
        self.assertEqual(body['drive_penalty'], 'warn')
        self.assertFalse(body['locked'])

    def test_configure_round_trips(self):
        r = self._configure()
        self.assertEqual(r.status_code, 200)
        body = r.json()
        self.assertTrue(body['configured'])
        self.assertEqual(body['drive_rule'], 'per_nine')
        self.assertEqual(body['split_pcts'], [50, 30, 20])

    def test_the_split_must_reach_100(self):
        """95% leaves money in the TD's pocket with no line explaining it."""
        r = self._configure(split_pcts=[40, 25, 20, 10], places_paid=4)
        self.assertEqual(r.status_code, 400)
        self.assertIn('95%', r.json()['detail'])

    def test_configuring_marks_the_shape_on_the_tournament(self):
        """The marker is what keeps a team event out of is_individual_play."""
        self.tourn.active_games = []
        self.tourn.save(update_fields=['active_games'])
        self._configure()
        self.tourn.refresh_from_db()
        self.assertTrue(self.tourn.is_team_play)
        self.assertFalse(self.tourn.is_individual_play)

    def test_format_cannot_change_after_the_first_score(self):
        from django.utils import timezone
        self._configure()
        cfg = TeamPlayConfig.objects.get(tournament=self.tourn)
        cfg.format_locked_at = timezone.now()
        cfg.save(update_fields=['format_locked_at'])

        r = self._configure(team_format='shamble')
        self.assertEqual(r.status_code, 409)
        self.assertIn('team_format', r.json()['fields'])

    def test_money_stays_editable_after_the_lock(self):
        """Fee and split are argued about after the round as often as before,
        and neither can invalidate a score."""
        from django.utils import timezone
        self._configure()
        cfg = TeamPlayConfig.objects.get(tournament=self.tourn)
        cfg.format_locked_at = timezone.now()
        cfg.save(update_fields=['format_locked_at'])

        r = self._configure(entry_fee='40.00', split_pcts=[60, 40],
                            places_paid=2)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['entry_fee'], 40.0)

    # -- the read model --------------------------------------------------

    def test_the_board_works_the_packets_own_teams(self):
        self._configure()
        body = self.client.get(self._board_url()).json()

        self.assertEqual(body['field'], {'golfers': 23, 'teams': 6,
                                         'pool': 575.0})

        self.assertEqual(self._team(body, 'Pine')['team_handicap'], 6)
        self.assertEqual(self._team(body, 'Pine')['team_handicap_raw'], '6.15')
        self.assertEqual(self._team(body, 'Clay')['team_handicap'], 8)
        self.assertEqual(self._team(body, 'Slate')['team_handicap'], 8)

    def test_a_three_man_team_gets_its_phantom_and_plays_off_ten(self):
        self._configure()
        dune = self._team(self.client.get(self._board_url()).json(), 'Dune')

        self.assertTrue(dune['has_phantom'])
        self.assertEqual(dune['real_player_count'], 3)
        self.assertEqual(dune['team_handicap'], 10)
        self.assertEqual(dune['team_handicap_raw'], '9.95')

        phantom = next(m for m in dune['members'] if m['is_phantom'])
        self.assertEqual(phantom['course_handicap'], 16)
        self.assertEqual(phantom['pct'], 15)     # sorts into third on handicap

    def test_the_worked_card_shows_every_mans_contribution(self):
        """Maiolini 4 → 1.00. Showing only the team total hides why moving one
        man swings a team by two strokes."""
        self._configure()
        pine = self._team(self.client.get(self._board_url()).json(), 'Pine')
        self.assertEqual(
            [(m['name'], m['pct'], m['strokes']) for m in pine['members']],
            [('Maiolini', 25, '1.00'), ('Gunst', 20, '1.60'),
             ('Detomasi', 15, '1.65'), ('Yau', 10, '1.90')],
        )

    def test_every_team_gets_a_colour(self):
        self._configure()
        body = self.client.get(self._board_url()).json()
        colours = [t['colour'] for t in body['teams']]
        self.assertEqual(len(set(colours)), 6)
        self.assertEqual(colours[0], 'Pine')

    def test_a_shamble_takes_85_percent_at_two_balls(self):
        self._configure(team_format='shamble', ball_count_mode='fixed',
                        ball_count_fixed=2)
        body = self.client.get(self._board_url()).json()
        self.assertEqual(body['ball_count']['counted'], 36)
        self.assertEqual(body['ball_count']['played'], 72)

        pine = self._team(body, 'Pine')
        self.assertEqual(pine['allowance']['pct'], 85)
        maiolini = pine['members'][0]
        self.assertEqual(maiolini['shamble_handicap'], 3)     # 85% of 4 = 3.4

    def test_not_a_team_play_tournament(self):
        self.tourn.active_games = ['low_net']
        self.tourn.save(update_fields=['active_games'])
        body = self.client.get(self._board_url()).json()
        self.assertFalse(body['configured'])

    # -- drives ----------------------------------------------------------

    def test_recording_a_drive_returns_the_tracker(self):
        self._configure()
        pine = self.teams['Pine']
        gunst = pine.memberships.get(player__name='Gunst').player

        r = self.client.post(
            reverse('api-team-play-drive', args=[pine.id]),
            {'hole_number': 2, 'player_id': gunst.id}, format='json')
        self.assertEqual(r.status_code, 200)

        body = r.json()
        self.assertEqual(body['required'], 4)
        self.assertEqual(body['free'], 5)
        front = body['windows'][0]
        self.assertEqual(front['owed'], 3)
        owes = {g['player_id']: g['owes'] for g in front['golfers']}
        self.assertEqual(owes[gunst.id], 0)

    def test_the_tracker_warns_two_holes_early(self):
        """Pine thru 7 with two men still owing and two holes left."""
        self._configure()
        pine = self.teams['Pine']
        ids = {m.player.name: m.player_id for m in pine.memberships.all()}
        url = reverse('api-team-play-drive', args=[pine.id])
        self.client.post(url, {'hole_number': 2, 'player_id': ids['Gunst']},
                         format='json')
        self.client.post(url, {'hole_number': 5, 'player_id': ids['Detomasi']},
                         format='json')
        r = self.client.post(url, {'hole_number': 7, 'player_id': ids['Gunst']},
                             format='json')

        front = r.json()['windows'][0]
        self.assertEqual(front['owed'], 2)
        self.assertEqual(front['holes_left'], 2)
        self.assertTrue(front['tight'])
        self.assertFalse(front['impossible'])

    def test_the_phantom_has_no_tee_shot(self):
        self._configure()
        dune = self.teams['Dune']
        phantom = dune.memberships.get(player__is_phantom=True).player
        r = self.client.post(
            reverse('api-team-play-drive', args=[dune.id]),
            {'hole_number': 1, 'player_id': phantom.id}, format='json')
        self.assertEqual(r.status_code, 400)

    def test_a_drive_can_be_cleared(self):
        self._configure()
        pine = self.teams['Pine']
        gunst = pine.memberships.get(player__name='Gunst').player
        url = reverse('api-team-play-drive', args=[pine.id])
        self.client.post(url, {'hole_number': 2, 'player_id': gunst.id},
                         format='json')
        r = self.client.post(url, {'hole_number': 2, 'player_id': None},
                             format='json')
        self.assertEqual(r.json()['windows'][0]['owed'], 4)

    # -- the rota --------------------------------------------------------

    def test_pairs_are_set_once_and_then_fixed(self):
        self._configure(drive_rule='alternating')
        pine = self.teams['Pine']
        ids = {m.player.name: m.player_id for m in pine.memberships.all()}
        url = reverse('api-team-play-pairs', args=[pine.id])

        r = self.client.post(url, {'pairs': [[ids['Maiolini'], ids['Yau']],
                                             [ids['Gunst'], ids['Detomasi']]]},
                             format='json')
        self.assertEqual(r.status_code, 200)
        rota = r.json()['rota']
        self.assertEqual(rota[0]['pair'], [ids['Maiolini'], ids['Yau']])
        self.assertEqual(rota[1]['pair'], [ids['Gunst'], ids['Detomasi']])

        # A rota that can be re-cut mid-round is not a rota.
        again = self.client.post(url, {'pairs': [[ids['Maiolini'], ids['Gunst']],
                                                 [ids['Yau'], ids['Detomasi']]]},
                                 format='json')
        self.assertEqual(again.status_code, 409)

    def test_three_men_run_ab_bc_ac_and_cover_the_phantom(self):
        self._configure(drive_rule='alternating')
        dune = self.teams['Dune']
        ids = {m.player.name: m.player_id
               for m in dune.memberships.filter(player__is_phantom=False)}
        a, b, c = ids['Bellini'], ids['Kwan'], ids['Ortega']

        body = self.client.get(self._board_url()).json()
        rota = self._team(body, 'Dune')['drive']['rota']
        self.assertEqual(rota[0]['pair'], [a, b])
        self.assertEqual(rota[0]['phantom_cover'], c)
        self.assertEqual(rota[1]['pair'], [b, c])
        self.assertEqual(rota[1]['phantom_cover'], a)

    def test_a_driver_must_be_on_the_team(self):
        self._configure(drive_rule='alternating')
        pine, dune = self.teams['Pine'], self.teams['Dune']
        pine_ids = list(pine.memberships.values_list('player_id', flat=True))
        outsider = dune.memberships.first().player_id
        r = self.client.post(
            reverse('api-team-play-pairs', args=[pine.id]),
            {'pairs': [[pine_ids[0], outsider], [pine_ids[1], pine_ids[2]]]},
            format='json')
        self.assertEqual(r.status_code, 400)

    # -- naming ----------------------------------------------------------

    def test_renaming_a_team_keeps_its_colour(self):
        self._configure()
        pine = self.teams['Pine']
        r = self.client.post(reverse('api-team-play-team', args=[pine.id]),
                             {'name': 'The Sandbaggers'}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['name'], 'The Sandbaggers')
        self.assertEqual(r.json()['colour'], 'Pine')

    def test_a_team_name_is_capped_at_sixteen(self):
        self._configure()
        pine = self.teams['Pine']
        r = self.client.post(reverse('api-team-play-team', args=[pine.id]),
                             {'name': 'A' * 40}, format='json')
        self.assertEqual(len(r.json()['name']), 16)


class WizardEndToEndTests(TestCase):
    """
    The exact call sequence the wizard makes, in order, ending at the one flag
    the round hub dispatches on.

    `is_team_play_round` is what decides whether tapping "Enter scores" reaches
    the Foursome Play card or falls through to the universal one, so it is
    worth a test that walks the whole path rather than asserting it in
    isolation.
    """

    def setUp(self):
        self.acct = Account.objects.create(name='Saturday Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        self.course = Course.objects.create(account=self.acct, name='Tilden')
        self.tee = Tee.objects.create(
            course=self.course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.players = [
            Player.objects.create(account=self.acct, name=f'Golfer {i}',
                                  handicap_index=Decimal('10'))
            for i in range(11)          # 11 golfers → three teams, one of three
        ]

    def test_the_wizard_produces_a_round_the_hub_can_score(self):
        # 1. createTournament — the shape marker rides in active_games.
        t = self.client.post(reverse('api-tournament-list'), {
            'name': 'Saturday Scramble', 'start_date': '2026-06-06',
            'total_rounds': 1, 'active_games': ['team_play'],
        }, format='json')
        self.assertEqual(t.status_code, 201)
        tid = t.json()['id']

        # 2. createRound
        r = self.client.post(reverse('api-round-create'), {
            'tournament_id': tid, 'course_id': self.course.id,
            'date': '2026-06-06', 'round_number': 1, 'active_games': [],
        }, format='json')
        self.assertEqual(r.status_code, 201)
        rid = r.json()['id']

        # 3. setupRound — explicit group numbers, straight off Groups & Tees.
        sizes = [4, 4, 3]
        entries, cursor = [], 0
        for gi, size in enumerate(sizes, start=1):
            for p in self.players[cursor:cursor + size]:
                entries.append({'player_id': p.id, 'tee_id': self.tee.id,
                                'group_number': gi})
            cursor += size
        setup = self.client.post(reverse('api-round-setup', args=[rid]),
                                 {'players': entries}, format='json')
        self.assertIn(setup.status_code, (200, 201))

        # 4. postTeamPlaySetup — last, because sync_teams needs the foursomes.
        cfg = self.client.post(reverse('api-team-play-setup', args=[tid]), {
            'team_format': 'scramble', 'drive_rule': 'none',
            'entry_fee': '25.00', 'places_paid': 3, 'split_pcts': [50, 30, 20],
        }, format='json')
        self.assertEqual(cfg.status_code, 200)

        # The flag the hub reads.
        detail = self.client.get(reverse('api-round-detail', args=[rid])).json()
        self.assertTrue(detail['is_team_play_round'],
                        'the hub would fall through to the universal card')

        # And the card itself answers for a real foursome.
        fs_id = detail['foursomes'][0]['id']
        card = self.client.get(reverse('api-team-play-card', args=[fs_id]),
                               {'hole': 1})
        self.assertEqual(card.status_code, 200)
        self.assertEqual(card.json()['format'], 'scramble')

        # The short team got its phantom without anybody asking.
        board = self.client.get(reverse('api-team-play', args=[tid])).json()
        short = [t for t in board['teams'] if t['real_player_count'] == 3]
        self.assertEqual(len(short), 1)
        self.assertTrue(short[0]['has_phantom'])

    def test_the_flag_is_false_until_the_config_lands(self):
        """Setup posts last, so a round that never got a config must not claim
        a card it cannot draw."""
        t = self.client.post(reverse('api-tournament-list'), {
            'name': 'Half-built', 'start_date': '2026-06-06',
            'total_rounds': 1, 'active_games': ['team_play'],
        }, format='json').json()
        r = self.client.post(reverse('api-round-create'), {
            'tournament_id': t['id'], 'course_id': self.course.id,
            'date': '2026-06-06', 'round_number': 1, 'active_games': [],
        }, format='json').json()
        detail = self.client.get(
            reverse('api-round-detail', args=[r['id']])).json()
        self.assertFalse(detail['is_team_play_round'])
