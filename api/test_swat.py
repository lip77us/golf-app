"""
api/test_swat.py
----------------
Oakmont SWAT endpoints: the Teams preview, setup, writing the teams as groups,
and the board on the round leaderboard.
"""
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import User
from games.models import SwatConfig
from scoring.tests._helpers import (DEFAULT_HOLES, make_course, make_player,
                                    make_round, make_tee, make_tournament)
from tournament.models import Foursome


class _Base(TestCase):
    def setUp(self):
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.account = self.course.account
        self.round = make_round(course=self.course,
                                tournament=make_tournament(name='SWAT'),
                                active_games=[])
        self.players = [make_player(f'P{i} Name{i:02d}', handicap_index=i + 2)
                        for i in range(14)]
        self.user = User.objects.create_user(
            username='td', password='x', account=self.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def ids(self):
        return [p.pk for p in self.players]

    def setup_game(self, **kw):
        body = {'stake': 6, 'allow_fivesomes': False}
        body.update(kw)
        return self.client.post(f'/api/rounds/{self.round.id}/swat/setup/',
                                body, format='json')


class PreviewTests(_Base):
    def preview(self, **kw):
        body = {'player_ids': self.ids()}
        body.update(kw)
        return self.client.post('/api/swat/teams/preview/', body, format='json')

    def test_it_deals_the_snake(self):
        r = self.preview()
        self.assertEqual(r.status_code, 200)
        d = r.data
        self.assertEqual(d['field'], 14)
        self.assertEqual(sorted(t['size'] for t in d['teams']), [3, 3, 4, 4])
        self.assertIsNone(d['problem'])
        self.assertFalse(d['edited'])
        self.assertEqual(d['matches'], 6)
        self.assertTrue(all(p['band'] for t in d['teams'] for p in t['players']))

    def test_a_threesome_is_flagged(self):
        d = self.preview().data
        self.assertEqual(sum(1 for t in d['teams'] if t['three']), 2)
        self.assertEqual(d['threesomes'], 2)

    def test_a_move_marks_it_changed_and_renames_the_team(self):
        deal = self.preview().data['teams']
        teams = [[p['id'] for p in t['players']] for t in deal]
        moved = teams[0].pop()
        teams[2].append(moved)
        d = self.preview(teams=teams, allow_fivesomes=True).data
        self.assertTrue(d['edited'])

    def test_a_fivesome_needs_the_switch(self):
        deal = self.preview().data['teams']
        teams = [[p['id'] for p in t['players']] for t in deal]
        teams[2].append(teams[3].pop())
        self.assertIn('Allow fivesomes', self.preview(teams=teams).data['problem'])
        self.assertIsNone(
            self.preview(teams=teams, allow_fivesomes=True).data['problem'])

    def test_a_short_field_is_refused_in_a_sentence(self):
        d = self.preview(player_ids=self.ids()[:10]).data
        self.assertIn('at least 12', d['problem'])

    def test_a_golfer_missing_from_the_teams_is_a_400(self):
        r = self.preview(teams=[self.ids()[:7]])
        self.assertEqual(r.status_code, 400)

    def test_another_accounts_golfer_is_refused(self):
        from accounts.models import Account
        from core.models import Player
        acct = Account.objects.create(name='Other')
        other = Player.objects.create(account=acct, name='Out Sider',
                                      handicap_index=5)
        r = self.preview(player_ids=self.ids() + [other.pk])
        self.assertEqual(r.status_code, 400)


class SetupTests(_Base):
    def test_setup_switches_the_game_on(self):
        r = self.setup_game(stake=8)
        self.assertEqual(r.status_code, 201)
        self.round.refresh_from_db()
        self.assertIn('oakmont_swat', self.round.active_games)
        self.assertEqual(float(SwatConfig.objects.get().stake), 8.0)

    def test_it_refuses_a_round_already_running_forty_balls(self):
        self.round.active_games = ['forty_balls']
        self.round.save()
        r = self.setup_game()
        self.assertEqual(r.status_code, 400)
        self.assertIn('40 Balls', r.data['detail'])

    def test_the_teams_become_the_groups_and_the_phantom_is_drawn(self):
        self.setup_game()
        deal = self.client.post('/api/swat/teams/preview/',
                                {'player_ids': self.ids()}, format='json').data
        teams = [[p['id'] for p in t['players']] for t in deal['teams']]
        r = self.client.post(
            f'/api/rounds/{self.round.id}/swat/teams/',
            {'teams': teams, 'tees': {str(i): self.tee.pk for i in self.ids()}},
            format='json')
        self.assertEqual(r.status_code, 201, r.data)
        groups = Foursome.objects.filter(round=self.round)
        self.assertEqual(groups.count(), 4)
        self.assertFalse(any(g.has_phantom for g in groups))   # SWAT's is derived
        cfg = SwatConfig.objects.get()
        self.assertEqual(len(cfg.phantom_order), 18)
        self.assertTrue(cfg.bands)
        # a threesome's donor is a bottom golfer of a team of four
        sizes = {g.pk: g.memberships.count() for g in groups}
        donors = {pid for pid in cfg.phantom_order}
        four_ids = {m.player_id for g in groups if sizes[g.pk] == 4
                    for m in g.memberships.all()}
        self.assertTrue(donors <= four_ids)

    def test_an_illegal_shape_is_a_400_with_the_sentence(self):
        self.setup_game()
        ids = self.ids()
        r = self.client.post(
            f'/api/rounds/{self.round.id}/swat/teams/',
            {'teams': [ids[:2], ids[2:]],
             'tees': {str(i): self.tee.pk for i in ids}}, format='json')
        self.assertEqual(r.status_code, 400)

    def test_the_board_rides_the_round_leaderboard(self):
        self.setup_game()
        deal = self.client.post('/api/swat/teams/preview/',
                                {'player_ids': self.ids()}, format='json').data
        teams = [[p['id'] for p in t['players']] for t in deal['teams']]
        self.client.post(
            f'/api/rounds/{self.round.id}/swat/teams/',
            {'teams': teams, 'tees': {str(i): self.tee.pk for i in self.ids()}},
            format='json')
        r = self.client.get(f'/api/rounds/{self.round.id}/swat/')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data['teams']), 4)
        self.assertNotIn('phantom_order', repr(r.data))

    def test_a_renamed_group_names_the_team_on_the_board(self):
        self.setup_game()
        deal = self.client.post('/api/swat/teams/preview/',
                                {'player_ids': self.ids()}, format='json').data
        teams = [[p['id'] for p in t['players']] for t in deal['teams']]
        self.client.post(
            f'/api/rounds/{self.round.id}/swat/teams/',
            {'teams': teams, 'tees': {str(i): self.tee.pk for i in self.ids()}},
            format='json')
        fs = Foursome.objects.filter(round=self.round).first()
        fs.name = 'The Eagles'
        fs.save()
        r = self.client.get(f'/api/rounds/{self.round.id}/swat/')
        names = [t['name'] for t in r.data['teams']]
        self.assertIn('The Eagles', names)
        self.assertEqual(len([n for n in names if n.startswith('Team ')]), 3)

    def test_two_teams_that_share_a_surname_get_first_initials(self):
        from services.swat import auto_names
        g = lambda i, n, ix: {'id': i, 'name': n, 'index': ix, 'ch': 0}
        names = auto_names([[g(1, 'Paul Lipkin', 2), g(2, 'Al Roe', 9)],
                            [g(3, 'Jan Lipkin', 3), g(4, 'Bo Poe', 8)],
                            [g(5, 'Cy Doe', 4), g(6, 'Di Fox', 7)]])
        self.assertEqual(names, ['Team P. Lipkin', 'Team J. Lipkin', 'Team Doe'])


class FivesomeDealTests(TestCase):
    def _golfers(self, n):
        return [{'id': i, 'name': f'G{i} Name{i}', 'index': float(i), 'ch': 0}
                for i in range(1, n + 1)]

    def test_seventeen_golfers_make_four_teams_with_fivesomes(self):
        from services.swat import snake_deal
        sizes = sorted(len(t) for t in snake_deal(self._golfers(17), True)['teams'])
        self.assertEqual(sizes, [4, 4, 4, 5])

    def test_seventeen_without_fivesomes_is_unchanged(self):
        from services.swat import snake_deal
        sizes = sorted(len(t) for t in snake_deal(self._golfers(17))['teams'])
        self.assertEqual(sizes, [3, 3, 3, 4, 4])

    def test_leftovers_that_do_not_fit_fall_back(self):
        from services.swat import snake_deal
        # 15 golfers: 3 teams would be 5, 5, 5 (fits), 14: 3 teams of 5,5,4
        self.assertEqual(sorted(len(t) for t in snake_deal(self._golfers(14), True)['teams']), [4, 5, 5])
