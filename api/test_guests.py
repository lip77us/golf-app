"""api/test_guests.py — one-round guests: not on Halved and no GHIN."""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player
from tournament.models import Round, Foursome, FoursomeMembership
from scoring.tests._helpers import make_tee

User = get_user_model()


class GuestTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='G')
        self.user = User.objects.create_user(
            username='me', account=self.account, is_account_admin=True)
        self.me = Player.objects.create(account=self.account, name='Me',
                                        handicap_index=Decimal('5'), user=self.user)
        self.course = Course.objects.create(account=self.account, name='T')
        self.tee = make_tee(self.course)
        self.c = APIClient()
        self.c.force_authenticate(self.user)

    def _guest(self, name, phone='', ghin=''):
        return Player.objects.create(account=self.account, name=name,
                                     handicap_index=Decimal('10'), phone=phone,
                                     ghin=ghin)

    def _play(self, player, status):
        rnd = Round.objects.create(account=self.account, course=self.course,
                                   status=status, active_games=['skins'])
        fs = Foursome.objects.create(round=rnd, group_number=1)
        FoursomeMembership.objects.create(foursome=fs, player=player, tee=self.tee,
                                          course_handicap=0, playing_handicap=0)

    def _names(self):
        return {p['name'] for p in self.c.get('/api/players/').data}

    def test_a_guest_who_only_played_finished_rounds_is_not_listed(self):
        g = self._guest('Gone Guest')
        self._play(g, 'complete')
        self.assertNotIn('Gone Guest', self._names())

    def test_a_guest_in_a_round_still_going_is_listed(self):
        g = self._guest('Here Guest')
        self._play(g, 'complete')
        self._play(g, 'in_progress')
        self.assertIn('Here Guest', self._names())

    def test_a_guest_never_seated_yet_is_listed(self):
        self._guest('New Guest')
        self.assertIn('New Guest', self._names())

    def test_a_ghin_keeps_a_golfer_listed(self):
        g = self._guest('Genius', ghin='1234567')
        self._play(g, 'complete')
        self.assertIn('Genius', self._names())

    def test_a_halved_member_stays_listed(self):
        other = Account.objects.create(name='Other')
        u = User.objects.create_user(username='bob', account=other)
        u.phone = '+13105550101'
        u.save(update_fields=['phone'])
        g = self._guest('Member', phone='(310) 555-0101')
        self._play(g, 'complete')
        self.assertIn('Member', self._names())

    def test_the_flag_is_on_the_payload(self):
        self._guest('New Guest')
        row = next(p for p in self.c.get('/api/players/').data if p['name'] == 'New Guest')
        self.assertTrue(row['is_guest'])

    def test_adding_a_gone_guest_again_reuses_the_row(self):
        g = self._guest('Jo Guest', phone='+13105559999')
        self._play(g, 'complete')
        r = self.c.post('/api/players/', {
            'name': 'Jo Guest', 'handicap_index': '12.0', 'phone': '(310) 555-9999'},
            format='json')
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data['id'], g.id)
        self.assertEqual(Player.objects.filter(account=self.account,
                                               name='Jo Guest').count(), 1)

    def test_a_listed_number_is_still_refused(self):
        self._guest('Listed', phone='+13105558888')
        r = self.c.post('/api/players/', {
            'name': 'Dup', 'handicap_index': '12.0', 'phone': '(310) 555-8888'},
            format='json')
        self.assertEqual(r.status_code, 400)
