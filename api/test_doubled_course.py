"""
api/test_doubled_course.py
--------------------------
Playing a nine-hole course twice: a derived 18-hole course (see
services/doubled_course.py), so nothing downstream needs to know.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from services.doubled_course import double_holes, is_nine_hole

User = get_user_model()

# The Ridge 9, White tee (hole, par, SI, yards).
RIDGE = [(1, 4, 5, 264), (2, 3, 9, 84), (3, 4, 2, 281), (4, 3, 6, 130),
         (5, 4, 3, 268), (6, 4, 4, 391), (7, 4, 7, 217), (8, 4, 8, 211),
         (9, 4, 1, 402)]


def _nine():
    return [{'number': n, 'par': p, 'stroke_index': si, 'yards': y}
            for n, p, si, y in RIDGE]


class DoublingTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Nine')
        self.user = User.objects.create_user(username='u', account=self.acct)
        self.user.is_account_admin = True
        self.user.save()
        self.course = Course.objects.create(account=self.acct, name='The Ridge 9')
        self.white = Tee.objects.create(
            course=self.course, tee_name='White', slope=105,
            course_rating=Decimal('31.2'), par=34, holes=_nine(), sex='M')
        self.client_ = APIClient()
        self.client_.force_authenticate(self.user)

    def _double(self):
        return self.client_.post(f'/api/courses/{self.course.id}/doubled/')

    def test_the_holes_repeat_and_the_stroke_indexes_interleave(self):
        h = double_holes(_nine())
        self.assertEqual([x['number'] for x in h], list(range(1, 19)))
        self.assertEqual([x['par'] for x in h], [p for _, p, _, _ in RIDGE] * 2)
        # First loop odd, second loop even, and a permutation of 1..18.
        self.assertEqual([x['stroke_index'] for x in h[:9]],
                         [2 * si - 1 for _, _, si, _ in RIDGE])
        self.assertEqual([x['stroke_index'] for x in h[9:]],
                         [2 * si for _, _, si, _ in RIDGE])
        self.assertEqual(sorted(x['stroke_index'] for x in h), list(range(1, 19)))
        self.assertEqual([x['yards'] for x in h[9:]], [y for *_, y in RIDGE])

    def test_the_tee_doubles_par_and_rating_and_keeps_slope(self):
        r = self._double()
        self.assertEqual(r.status_code, 201, r.content)
        doubled = Course.objects.get(pk=r.data['id'])
        self.assertEqual(doubled.doubled_of_id, self.course.id)
        self.assertEqual(r.data['doubled_of'], self.course.id)
        t = doubled.tees.get(tee_name='White')
        self.assertEqual((t.par, t.slope, t.course_rating, len(t.holes), t.sex),
                         (68, 105, Decimal('62.4'), 18, 'M'))
        self.assertFalse(is_nine_hole(doubled))

    def test_the_handicap_matches_playing_the_nine_twice(self):
        doubled = Course.objects.get(pk=self._double().data['id'])
        p = Player.objects.create(account=self.acct, name='P',
                                  handicap_index=Decimal('10.0'))
        # One nine is 2; two of them are 4 — not the 6 + 6 it used to be.
        self.assertEqual(p.course_handicap(self.white), 2)
        self.assertEqual(p.course_handicap(doubled.tees.get()), 4)

    def test_asking_twice_returns_the_same_course(self):
        a = self._double().data['id']
        b = self._double().data['id']
        self.assertEqual(a, b)
        self.assertEqual(Course.objects.filter(doubled_of=self.course).count(), 1)

    def test_an_eighteen_hole_course_cannot_be_doubled(self):
        big = Course.objects.create(account=self.acct, name='Big')
        Tee.objects.create(course=big, tee_name='W', slope=120,
                           course_rating=Decimal('70.0'), par=72,
                           holes=[{'number': i, 'par': 4, 'stroke_index': i,
                                   'yards': 300} for i in range(1, 19)])
        r = self.client_.post(f'/api/courses/{big.id}/doubled/')
        self.assertEqual(r.status_code, 400)

    def test_a_doubled_course_cannot_be_doubled_again(self):
        d = self._double().data['id']
        self.assertEqual(
            self.client_.post(f'/api/courses/{d}/doubled/').status_code, 400)

    def test_another_account_gets_a_404(self):
        other = User.objects.create_user(
            username='o', account=Account.objects.create(name='Other'))
        c = APIClient(); c.force_authenticate(other)
        self.assertEqual(c.post(f'/api/courses/{self.course.id}/doubled/')
                         .status_code, 404)

    def test_search_does_not_list_it_as_a_second_venue(self):
        self._double()
        r = self.client_.get('/api/courses/find/', {'q': 'Ridge'})
        names = [c['name'] for c in r.data['courses']
                 if c.get('source') == 'account']
        self.assertEqual(names, ['The Ridge 9'])
