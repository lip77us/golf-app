"""
api/test_auto_home_course.py
---------------------------
A course played twice becomes the golfer's home course (if he has none), and
the course finder's Recents carry the tees and the date.
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
from services.home_course import (maybe_set_home_course, promote_home_courses,
                                  rounds_played_at)
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()
HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Club')
        self.user = User.objects.create_user(username='me', account=self.acct)
        self.me = Player.objects.create(
            account=self.acct, name='Me', handicap_index=Decimal('10'),
            user=self.user)
        self.pebble = self._course('Pebble')
        self.links = self._course('Links')

    def _course(self, name):
        c = Course.objects.create(account=self.acct, name=name)
        Tee.objects.create(course=c, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=HOLES)
        return c

    def play(self, course, *, when=None, scored=True, who=None,
             tee_name=None, complete=False):
        who = who or self.me
        rnd = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            date=when or date(2026, 11, 1))
        fs = Foursome.objects.create(round=rnd, group_number=1)
        tee = course.tees.first()
        if tee_name:
            tee.tee_name = tee_name
            tee.save(update_fields=['tee_name'])
        FoursomeMembership.objects.create(
            foursome=fs, player=who, tee=tee, course_handicap=0,
            playing_handicap=0)
        HoleScore.objects.create(
            foursome=fs, player=who, hole_number=1,
            gross_score=4 if scored else None, handicap_strokes=0)
        return rnd


class TheRuleTests(_Base):
    def test_two_scored_rounds_make_it_home(self):
        self.play(self.pebble)
        self.assertIsNone(maybe_set_home_course(self.me, self.pebble))
        self.play(self.pebble)
        self.assertEqual(maybe_set_home_course(self.me, self.pebble),
                         self.pebble)
        self.me.refresh_from_db()
        self.assertEqual(self.me.home_course_id, self.pebble.id)

    def test_a_round_with_no_score_is_not_played(self):
        self.play(self.pebble)
        self.play(self.pebble, scored=False)
        self.assertEqual(rounds_played_at(self.me, self.pebble), 1)
        self.assertIsNone(maybe_set_home_course(self.me, self.pebble))

    def test_two_scores_in_one_round_are_one_round(self):
        rnd = self.play(self.pebble)
        fs = rnd.foursomes.first()
        HoleScore.objects.create(foursome=fs, player=self.me, hole_number=2,
                                 gross_score=5, handicap_strokes=0)
        self.assertEqual(rounds_played_at(self.me, self.pebble), 1)

    def test_a_chosen_home_course_is_never_replaced(self):
        self.me.home_course = self.links
        self.me.save()
        self.play(self.pebble)
        self.play(self.pebble)
        self.assertIsNone(maybe_set_home_course(self.me, self.pebble))
        self.me.refresh_from_db()
        self.assertEqual(self.me.home_course_id, self.links.id)

    def test_a_guest_with_no_login_never_gets_one(self):
        guest = Player.objects.create(
            account=self.acct, name='Guest', handicap_index=Decimal('5'))
        self.play(self.pebble, who=guest)
        self.play(self.pebble, who=guest)
        self.assertIsNone(maybe_set_home_course(guest, self.pebble))

    def test_two_different_courses_once_each_is_not_enough(self):
        self.play(self.pebble)
        self.play(self.links)
        self.assertIsNone(maybe_set_home_course(self.me, self.pebble))
        self.assertIsNone(maybe_set_home_course(self.me, self.links))

    def test_completing_a_round_promotes_for_each_linked_golfer(self):
        self.play(self.pebble)
        rnd = self.play(self.pebble)
        done = promote_home_courses(rnd)
        self.assertEqual([(p.id, c.id) for p, c in done],
                         [(self.me.id, self.pebble.id)])


class CompletingARoundTests(_Base):
    def test_the_complete_endpoint_does_it(self):
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.play(self.pebble)
        rnd = self.play(self.pebble)
        c = APIClient()
        c.force_authenticate(self.user)
        r = c.post(reverse('api-round-complete', args=[rnd.id]),
                   {'force': True}, format='json')
        self.assertEqual(r.status_code, 200, r.content)
        self.me.refresh_from_db()
        self.assertEqual(self.me.home_course_id, self.pebble.id)


class RecentPlaysTests(_Base):
    def get(self):
        c = APIClient()
        c.force_authenticate(self.user)
        r = c.get(reverse('api-recent-plays'))
        self.assertEqual(r.status_code, 200, r.content)
        return r.data

    def test_newest_first_with_date_and_tees(self):
        self.play(self.pebble, when=date(2026, 10, 1), tee_name='Blue')
        self.play(self.links, when=date(2026, 11, 5), tee_name='White')
        rows = self.get()
        self.assertEqual([r['course']['name'] for r in rows],
                         ['Links', 'Pebble'])
        self.assertEqual(rows[0]['last_played'], '2026-11-05')
        self.assertEqual(rows[0]['tee_name'], 'White')
        self.assertEqual(rows[1]['tee_name'], 'Blue')

    def test_a_course_played_twice_is_one_row_at_the_latest_date(self):
        self.play(self.pebble, when=date(2026, 10, 1))
        self.play(self.pebble, when=date(2026, 11, 9))
        rows = self.get()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['last_played'], '2026-11-09')

    def test_the_home_course_is_included_and_flagged(self):
        self.me.home_course = self.pebble
        self.me.save()
        self.play(self.pebble)
        rows = self.get()
        self.assertTrue(rows[0]['is_home'])

    def test_five_at_most(self):
        for i in range(7):
            self.play(self._course(f'C{i}'), when=date(2026, 11, 1 + i))
        self.assertEqual(len(self.get()), 5)

    def test_a_round_nobody_scored_is_not_a_recent(self):
        self.play(self.pebble, scored=False)
        self.assertEqual(self.get(), [])

    def test_someone_elses_round_in_my_account_is_not_mine(self):
        other = Player.objects.create(
            account=self.acct, name='Other', handicap_index=Decimal('3'))
        self.play(self.pebble, who=other)
        self.assertEqual(self.get(), [])
