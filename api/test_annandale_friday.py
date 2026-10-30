"""
api/test_annandale_friday.py
----------------------------
Annandale Friday endpoints round-trip through serializer / view / urls, plus
the three places the rest of the app has to find the game: the recalc that
runs on a posted score, the leaderboard block, and the settlement. (The
engine is scoring/tests/test_annandale_friday.py's.)

A score posted through the real endpoint is the test that matters most: the
three matches are not 'nassau' rows, so nothing reaches them unless the
recalc dispatch names the slug — and a game that scores in the engine tests
and never moves on a phone is the shipped-and-unreachable shape.
"""
from decimal import Decimal
from unittest import mock

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from services.settlement import round_settlement
from tournament.models import Round, Foursome, FoursomeMembership

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]
ROSTER = (('Bill', 8), ('Tom', 14), ('Dave', 4),
          ('Ray', 18), ('Jim', 11), ('Sam', 22))


class AnnandaleFridayEndpointTests(TestCase):
    SIZE = 6

    def setUp(self):
        self.acct = Account.objects.create(name='Annandale')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Annandale GC')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['annandale_friday'], primary_game='annandale_friday',
            bet_unit=Decimal('10.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.p = {}
        for name, hcp in ROSTER[:self.SIZE]:
            pl = Player.objects.create(account=self.acct, name=name,
                                       handicap_index=Decimal(hcp))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=pl, tee=self.tee,
                course_handicap=hcp, playing_handicap=hcp)
            self.p[name] = pl.id
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def teams(self):
        return [[self.p['Bill'], self.p['Tom']], [self.p['Dave'], self.p['Ray']],
                [self.p['Jim'], self.p['Sam']]]

    def _setup(self, **over):
        body = {'teams': self.teams(), 'handicap_mode': 'gross',
                'auto_press': False}
        body.update(over)
        return self.client.post(
            reverse('api-annandale-friday-setup', args=[self.fs.id]),
            body, format='json')

    def _post_hole(self, hole, gross):
        r = self.client.post(
            reverse('api-score-submit', args=[self.fs.id]),
            {'hole_number': hole,
             'scores': [{'player_id': self.p[n], 'gross_score': g}
                        for n, g in gross.items()]},
            format='json')
        assert r.status_code in (200, 201), r.content
        return r

    def _sweep(self):
        # Bill & Tom win every hole; Dave & Ray beat Jim & Sam every hole.
        return {'Bill': 3, 'Tom': 5, 'Dave': 4, 'Ray': 6, 'Jim': 5, 'Sam': 7}

    # ── Setup ────────────────────────────────────────────────────────────────

    def test_the_get_before_setup_carries_the_packets_defaults(self):
        r = self.client.get(reverse('api-annandale-friday-setup', args=[self.fs.id]))
        assert r.status_code == 200
        d = r.json()
        assert d['configured'] is False
        assert d['handicap_mode'] == 'strokes_off'
        assert d['second_ball_tiebreak'] is False
        assert d['auto_press'] is True
        assert d['manual_press'] is False

    def test_setup_returns_three_matches_and_the_get_round_trips_it(self):
        r = self._setup(press_unit='5.00', bet_unit='7.50', claremont=True)
        assert r.status_code == 201, r.content
        assert len(r.json()['matches']) == 3
        self.round.refresh_from_db()
        assert self.round.bet_unit == Decimal('7.50')
        d = self.client.get(
            reverse('api-annandale-friday-setup', args=[self.fs.id])).json()
        assert d['configured'] is True
        assert d['claremont'] is True
        assert d['press_unit'] == 5.0
        assert [[p['player_id'] for p in t] for t in d['teams']] == self.teams()

    def test_a_split_that_does_not_fit_says_what_is_wrong(self):
        bad = [[self.p['Bill'], self.p['Tom']],
               [self.p['Dave'], self.p['Ray'], self.p['Jim'], self.p['Sam']]]
        r = self._setup(teams=bad, bet_unit='99.00')
        assert r.status_code == 400
        assert r.json()['detail'] == 'Six golfers play as three pairs.'
        # The stake in the same request did not land on a refused setup.
        self.round.refresh_from_db()
        assert self.round.bet_unit == Decimal('10.00')

    def test_teams_locked_after_three_holes_is_a_400_with_the_reason(self):
        assert self._setup().status_code == 201
        for h in range(1, 5):
            self._post_hole(h, self._sweep())
        swapped = [[self.p['Bill'], self.p['Dave']],
                   [self.p['Tom'], self.p['Ray']],
                   [self.p['Jim'], self.p['Sam']]]
        r = self._setup(teams=swapped)
        assert r.status_code == 400
        assert 'locked after the first 3 holes' in r.json()['detail']

    def test_result_404_when_not_configured(self):
        r = self.client.get(reverse('api-annandale-friday-result', args=[self.fs.id]))
        assert r.status_code == 404

    def test_another_accounts_group_is_a_404(self):
        other = Account.objects.create(name='Elsewhere')
        stranger = User.objects.create_user(username='x', account=other)
        c = APIClient()
        c.force_authenticate(stranger)
        r = c.get(reverse('api-annandale-friday-result', args=[self.fs.id]))
        assert r.status_code == 404

    # ── Reaching the game from the rest of the app ──────────────────────────

    def test_the_save_returns_the_result_for_the_tray(self):
        """The tray draws this, so a second request is not needed."""
        assert self._setup().status_code == 201
        body = self._post_hole(1, self._sweep()).json()
        assert 'scorecard' in body
        matches = body['annandale_friday']['matches']
        assert [len(m['summary']['holes']) for m in matches] == [1, 1, 1]
        assert matches[0]['summary']['front9']['margin'] == 1
        assert 'skins' not in body

    def test_the_save_returns_skins_when_they_run_beside_it(self):
        assert self._setup().status_code == 201
        self.round.active_games = ['annandale_friday', 'skins']
        self.round.save(update_fields=['active_games'])
        from services.skins import setup_skins
        setup_skins(self.fs)
        body = self._post_hole(1, self._sweep()).json()
        assert body['skins']['holes'][0]['hole'] == 1

    def test_the_save_no_longer_builds_a_leaderboard(self):
        """137 queries nothing read: both clients discard this body."""
        assert self._setup().status_code == 201
        assert 'leaderboard' not in self._post_hole(1, self._sweep()).json()

    def test_a_broken_tray_summary_does_not_fail_the_save(self):
        """A 500 here would leave a saved score retrying forever."""
        assert self._setup().status_code == 201
        with mock.patch('services.annandale_friday.annandale_friday_summary',
                        side_effect=RuntimeError('boom')):
            body = self._post_hole(1, self._sweep()).json()
        assert 'annandale_friday' not in body
        assert HoleScore.objects.filter(foursome=self.fs).count() == self.SIZE

    def test_score_events_run_after_the_commit_not_in_the_request(self):
        assert self._setup().status_code == 201
        with mock.patch('services.messaging_events.emit_score_events') as emit:
            with self.captureOnCommitCallbacks(execute=False) as callbacks:
                self._post_hole(1, self._sweep())
            emit.assert_not_called()
            for callback in callbacks:
                callback()
            emit.assert_called_once()
        assert emit.call_args.args[0].id == self.fs.id
        assert emit.call_args.args[1] == 1

    def test_a_posted_score_moves_the_matches(self):
        assert self._setup().status_code == 201
        self._post_hole(1, self._sweep())
        s = self.client.get(
            reverse('api-annandale-friday-result', args=[self.fs.id])).json()
        assert s['status'] == 'in_progress'
        assert [len(m['summary']['holes']) for m in s['matches']] == [1, 1, 1]
        assert s['matches'][0]['summary']['front9']['margin'] == 1

    def test_the_hub_reports_the_game_once_not_as_three_nassaus(self):
        self._setup()
        r = self.client.get(reverse('api-round-detail', args=[self.round.id]))
        fs = next(f for f in r.json()['foursomes'] if f['id'] == self.fs.id)
        assert 'annandale_friday' in fs['configured_games']
        assert not {'af_1', 'af_2', 'af_3'} & set(fs['configured_games'])

    def test_the_leaderboard_has_the_block(self):
        self._setup(auto_press=True, press_unit='10.00')
        self._post_hole(1, self._sweep())
        r = self.client.get(reverse('api-leaderboard', args=[self.round.id]))
        assert r.status_code == 200, r.content
        block = r.json()['games']['annandale_friday']
        assert block['label'] == 'Annandale Friday'
        # The stakes ride in the strip with the other settings.
        assert block['settings'][-2:] == ['$10 a bet', '$10 a press'], \
            block['settings']
        assert len(block['by_group'][0]['summary']['matches']) == 3

    def test_the_settlement_nets_every_golfer_and_sums_to_zero(self):
        self._setup()
        for h in range(1, 19):
            self._post_hole(h, self._sweep())
        st = round_settlement(self.round, min_games=1)
        nets = {p['player_id']: p['net'] for p in st['players']}
        assert nets[self.p['Bill']] == 60
        assert nets[self.p['Jim']] == -60
        assert abs(sum(nets.values())) < 0.005
        assert 'annandale_friday' not in st['uncovered_games']

    # ── Presses ──────────────────────────────────────────────────────────────

    def test_a_manual_press_round_trips(self):
        self._setup(manual_press=True)
        self._post_hole(1, {n: 4 for n in self.p})
        r = self.client.post(
            reverse('api-annandale-friday-press', args=[self.fs.id]),
            {'match': 2, 'start_hole': 2}, format='json')
        assert r.status_code == 200, r.content
        presses = r.json()['matches'][1]['summary']['presses']
        assert [(p['press_type'], p['start_hole']) for p in presses] == [('manual', 2)]

    def test_a_press_the_rules_refuse_is_a_400_with_the_reason(self):
        self._setup(manual_press=False)
        r = self.client.post(
            reverse('api-annandale-friday-press', args=[self.fs.id]),
            {'match': 1, 'start_hole': 2}, format='json')
        assert r.status_code == 400
        assert r.json()['detail'] == 'Manual presses are off for this game.'


class FiveGolferEndpointTests(AnnandaleFridayEndpointTests):
    """The same endpoints with a pair and a three. Inherits every test above
    that does not depend on six; the six-only ones are overridden."""
    SIZE = 5

    def teams(self):
        return [[self.p['Bill'], self.p['Tom']],
                [self.p['Dave'], self.p['Ray'], self.p['Jim']]]

    def _sweep(self):
        return {'Bill': 3, 'Tom': 5, 'Dave': 4, 'Ray': 6, 'Jim': 5}

    def test_a_split_that_does_not_fit_says_what_is_wrong(self):
        bad = [[self.p['Bill'], self.p['Tom']], [self.p['Dave'], self.p['Ray']],
               [self.p['Jim']]]
        r = self._setup(teams=bad)
        assert r.status_code == 400
        assert r.json()['detail'] == 'Five golfers play as a pair and a three.'

    def test_teams_locked_after_three_holes_is_a_400_with_the_reason(self):
        assert self._setup().status_code == 201
        for h in range(1, 5):
            self._post_hole(h, self._sweep())
        swapped = [[self.p['Bill'], self.p['Dave']],
                   [self.p['Tom'], self.p['Ray'], self.p['Jim']]]
        r = self._setup(teams=swapped)
        assert r.status_code == 400
        assert 'locked after the first 3 holes' in r.json()['detail']

    def test_the_settlement_nets_every_golfer_and_sums_to_zero(self):
        self._setup()
        for h in range(1, 19):
            self._post_hole(h, self._sweep())
        st = round_settlement(self.round, min_games=1)
        nets = {p['player_id']: p['net'] for p in st['players']}
        assert nets[self.p['Bill']] == 90       # the pair is in all three
        assert abs(sum(nets.values())) < 0.005
