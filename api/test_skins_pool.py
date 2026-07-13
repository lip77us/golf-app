"""
api/test_skins_pool.py
----------------------
Cross-round Multi-Group Skins pool endpoints (docs/multi-skins-cross-round.md):
a pool hosted on one account's round, joined by another account's round via the
host round's /watch/<token>/ link.  Covers resolve, same-course guard, ≥1
overlap, cross-account join + scoring, and unlink.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from games.models import MultiSkinsLinkedRound
from tournament.models import Round, Foursome, FoursomeMembership

from scoring.tests._helpers import DEFAULT_HOLES

User = get_user_model()


def _tee(course):
    return Tee.objects.create(
        course=course, tee_name='White', slope=113,
        course_rating=Decimal('72.0'), par=72, holes=DEFAULT_HOLES,
    )


def _member(fs, player, tee, hcp=0):
    return FoursomeMembership.objects.create(
        foursome=fs, player=player, tee=tee,
        course_handicap=hcp, playing_handicap=hcp,
    )


class SkinsPoolTests(TestCase):
    def setUp(self):
        # ── Host account A ──────────────────────────────────────────────────
        self.acct_a = Account.objects.create(name='Host Club')
        self.user_a = User.objects.create_user(username='host', account=self.acct_a)
        self.user_a.phone = '+13105550100'; self.user_a.save(update_fields=['phone'])
        self.course_a = Course.objects.create(
            account=self.acct_a, name='Pebble', golf_api_id='api-pebble')
        self.tee_a = _tee(self.course_a)

        # Roster: organizer O (plays in host round) + M2/M4 (play in guest round).
        # M2/M4 must be on-app → give them linked Users carrying their phones.
        self.o  = Player.objects.create(account=self.acct_a, name='O',
                                        handicap_index=0, phone='+13105550100')
        self.m2 = Player.objects.create(account=self.acct_a, name='M2',
                                        handicap_index=8, phone='+13105550102')
        self.m4 = Player.objects.create(account=self.acct_a, name='M4',
                                        handicap_index=18, phone='+13105550104')
        User.objects.create(username='u_m2', account=self.acct_a, phone='+13105550102')
        User.objects.create(username='u_m4', account=self.acct_a, phone='+13105550104')

        self.round_h = Round.objects.create(
            account=self.acct_a, course=self.course_a, status='in_progress',
            handicap_mode='gross', net_percent=100, net_max_double_bogey=False,
        )
        self.hg = Foursome.objects.create(round=self.round_h, group_number=1)
        _member(self.hg, self.o, self.tee_a, 0)

        # ── Guest account B ─────────────────────────────────────────────────
        # Its own clone of the SAME real course (shared golf_api_id).
        self.acct_b = Account.objects.create(name='Crew')
        self.user_b = User.objects.create_user(username='crew', account=self.acct_b)
        self.user_b.phone = '+13105550199'; self.user_b.save(update_fields=['phone'])
        self.course_b = Course.objects.create(
            account=self.acct_b, name='Pebble', golf_api_id='api-pebble')
        self.tee_b = _tee(self.course_b)
        # g2/g4 carry M2/M4's phones; g1/g3 are not in the pool.
        self.g2 = Player.objects.create(account=self.acct_b, name='g2',
                                        handicap_index=8, phone='+13105550102')
        self.g4 = Player.objects.create(account=self.acct_b, name='g4',
                                        handicap_index=18, phone='+13105550104')
        self.g1 = Player.objects.create(account=self.acct_b, name='g1',
                                        handicap_index=0, phone='+13105550111')
        self.round_g = Round.objects.create(
            account=self.acct_b, course=self.course_b, status='in_progress',
            handicap_mode='gross', net_percent=100, net_max_double_bogey=False,
            active_games=['sixes'],
        )
        self.gg = Foursome.objects.create(round=self.round_g, group_number=1)
        _member(self.gg, self.g2, self.tee_b, 8)
        _member(self.gg, self.g4, self.tee_b, 18)
        _member(self.gg, self.g1, self.tee_b, 0)

        # Configure the pool via the host's own setup endpoint.
        self.a = APIClient(); self.a.force_authenticate(self.user_a)
        self.b = APIClient(); self.b.force_authenticate(self.user_b)
        resp = self.a.post(
            reverse('api-multi-skins-setup', args=[self.round_h.id]),
            {'handicap_mode': 'gross', 'bet_unit': '10.00',
             'participant_ids': [self.o.id, self.m2.id, self.m4.id]},
            format='json',
        )
        self.assertEqual(resp.status_code, 201, resp.content)
        self.token = self.round_h.watch_token

    # ── Resolve ─────────────────────────────────────────────────────────────

    def test_resolve_by_token_returns_roster_and_overlap(self):
        url = reverse('api-skins-pool-resolve', args=[self.token])
        resp = self.b.get(url, {'round_id': self.round_g.id})
        self.assertEqual(resp.status_code, 200, resp.content)
        d = resp.json()
        self.assertEqual(d['host_round_id'], self.round_h.id)
        self.assertEqual({r['player_id'] for r in d['roster']},
                         {self.o.id, self.m2.id, self.m4.id})
        # The guest round overlaps the pool on M2 + M4 (matched by phone).
        self.assertEqual(set(d['overlap_ids']), {self.m2.id, self.m4.id})

    def test_resolve_unknown_token_404(self):
        resp = self.b.get(reverse('api-skins-pool-resolve', args=['NOPE0000']))
        self.assertEqual(resp.status_code, 404)

    # ── Join ────────────────────────────────────────────────────────────────

    def test_cross_account_join_then_scores_flow(self):
        join = reverse('api-skins-pool-join', args=[self.token])
        resp = self.b.post(join, {'round_id': self.round_g.id}, format='json')
        self.assertEqual(resp.status_code, 201, resp.content)
        self.assertEqual(set(resp.json()['overlap_ids']), {self.m2.id, self.m4.id})
        self.assertTrue(
            MultiSkinsLinkedRound.objects.filter(
                round=self.round_g, game__round=self.round_h).exists())

        # Score hole 1 in both rounds: O birdies, M2/M4 par → O takes the skin.
        self._score(self.a, self.hg, 1, [(self.o.id, 3)])
        self._score(self.b, self.gg, 1,
                    [(self.g2.id, 4), (self.g4.id, 4), (self.g1.id, 4)])

        result = self.a.get(
            reverse('api-multi-skins-result', args=[self.round_h.id]))
        totals = {p['name']: p['skins_won'] for p in result.json()['players']}
        self.assertEqual(totals, {'O': 1, 'M2': 0, 'M4': 0})
        self.assertEqual(result.json()['money']['pool'], 30.0)

    def test_join_rejected_when_no_overlap(self):
        # A round whose players share nothing with the roster.
        lone = Player.objects.create(account=self.acct_b, name='Lone',
                                     handicap_index=5, phone='+13105550777')
        r = Round.objects.create(
            account=self.acct_b, course=self.course_b, status='in_progress',
            handicap_mode='gross', net_percent=100)
        fs = Foursome.objects.create(round=r, group_number=1)
        _member(fs, lone, self.tee_b, 5)
        resp = self.b.post(reverse('api-skins-pool-join', args=[self.token]),
                           {'round_id': r.id}, format='json')
        self.assertEqual(resp.status_code, 400, resp.content)
        self.assertIn('in the pool', resp.json()['detail'])

    def test_join_rejected_on_different_course(self):
        other = Course.objects.create(
            account=self.acct_b, name='Augusta', golf_api_id='api-augusta')
        tee = _tee(other)
        r = Round.objects.create(
            account=self.acct_b, course=other, status='in_progress',
            handicap_mode='gross', net_percent=100)
        fs = Foursome.objects.create(round=r, group_number=1)
        _member(fs, self.g2, tee, 8)   # g2 IS a roster overlap, but wrong course
        resp = self.b.post(reverse('api-skins-pool-join', args=[self.token]),
                           {'round_id': r.id}, format='json')
        self.assertEqual(resp.status_code, 400, resp.content)
        self.assertIn('same course', resp.json()['detail'])

    def test_join_foreign_round_is_404(self):
        """You can only link a round in YOUR account."""
        resp = self.b.post(reverse('api-skins-pool-join', args=[self.token]),
                           {'round_id': self.round_h.id}, format='json')
        self.assertEqual(resp.status_code, 404)

    # ── Unlink ──────────────────────────────────────────────────────────────

    def test_unlink_removes_contribution(self):
        MultiSkinsLinkedRound.objects.create(
            game=self.round_h.multi_skins_game, round=self.round_g)
        resp = self.b.post(reverse('api-skins-pool-unlink', args=[self.token]),
                           {'round_id': self.round_g.id}, format='json')
        self.assertEqual(resp.status_code, 200, resp.content)
        self.assertFalse(
            MultiSkinsLinkedRound.objects.filter(round=self.round_g).exists())

    # ── Mine ────────────────────────────────────────────────────────────────

    def test_mine_lists_hosted_and_linked_pools(self):
        MultiSkinsLinkedRound.objects.create(
            game=self.round_h.multi_skins_game, round=self.round_g)
        # Host sees the pool it hosts.
        host = self.a.get(reverse('api-skins-pool-mine')).json()['pools']
        self.assertEqual([p['host_round_id'] for p in host], [self.round_h.id])
        # Guest sees the pool it's linked into.
        guest = self.b.get(reverse('api-skins-pool-mine')).json()['pools']
        self.assertEqual([p['host_round_id'] for p in guest], [self.round_h.id])

    # ── helper ──────────────────────────────────────────────────────────────

    def _score(self, client, fs, hole, scores):
        url = reverse('api-score-submit', args=[fs.id])
        payload = {'hole_number': hole,
                   'scores': [{'player_id': pid, 'gross_score': g}
                              for pid, g in scores]}
        resp = client.post(url, payload, format='json')
        self.assertIn(resp.status_code, (200, 201), resp.content)
