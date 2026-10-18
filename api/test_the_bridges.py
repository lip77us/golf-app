"""
api/test_the_bridges.py
-----------------------
Reported from San Ramon, 18 Oct 2026: **The Bridges Golf Club did not come
up in the app.**

**The cause was one thing, not three.** GolfCourseAPI files it as
`Bridges (The)`, so searching its own name returns eleven other Bridges and
not the one he played. That is fixed by `search_terms`, and the course then
imports cleanly -- the quality gate passes it with no warnings.

The other two tests here cover a latent bug found while chasing that and
**not** demonstrated by it: `_adapt_tee` invented a course rating of 72.0,
a slope of 113 and a par of 72 when upstream omitted them. I reported The
Bridges as having no ratings, which was wrong -- I probed `tee['rating']`
where the adapter emits `course_rating`, so all eight tees read as None.
Paul caught it from a screenshot of the White tee showing 70.5 and 129.

The fabrication is still worth removing, because a rating guessed as 72.0
against a real par of 72 makes `(CR - par)` zero and moves every handicap at
a course silently. It is simply not what happened here.

That misread is the SAME failure `live_activity_registry.gross_to_par`
documents -- a helper guessing at the key a payload uses and returning
nothing, which reads exactly like absent data.
"""
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import CatalogCourse, Course, Tee
from services.course_quality import CourseQualityError, assert_course_quality
from services.golf_api_client import search_terms

User = get_user_model()


def _holes():
    return [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
            for n in range(1, 19)]


class TheArticleComesOffTheQuery(TestCase):
    """`search_terms` — strictly better recall, nothing lost."""

    def test_a_leading_the_is_stripped(self):
        self.assertEqual(search_terms('The Bridges'), 'Bridges')
        self.assertEqual(search_terms('the bridges golf club'),
                         'bridges golf club')

    def test_other_articles_too(self):
        self.assertEqual(search_terms('A Rock Creek'), 'Rock Creek')
        self.assertEqual(search_terms('An Old Course'), 'Old Course')

    def test_an_article_INSIDE_the_name_is_untouched(self):
        self.assertEqual(search_terms('Bridges (The)'), 'Bridges (The)')
        self.assertEqual(search_terms('Lakes at The Pines'),
                         'Lakes at The Pines')

    def test_the_word_alone_is_somebody_still_typing(self):
        self.assertEqual(search_terms('The'), 'The')
        self.assertEqual(search_terms('The '), 'The')

    def test_it_survives_empty_and_padding(self):
        self.assertEqual(search_terms(''), '')
        self.assertEqual(search_terms('   The Bridges  '), 'Bridges')


class TheLocalHalvesSearchTheSameWay(TestCase):
    """A course already owned must be findable by its own name too."""

    def setUp(self):
        self.account = Account.objects.create(name='Bridges Acct')
        self.user = User.objects.create_user(username='p', account=self.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)
        Course.objects.create(account=self.account, name='Bridges (The)',
                              city='San Ramon', state='CA', golf_api_id='8zbrh5pt')
        CatalogCourse.objects.create(golf_api_id='zzz', name='Bridges (The) II',
                                     city='San Ramon', state='CA')

    @patch('services.golf_api_client.search_courses', return_value=[])
    def test_searching_the_bridges_finds_the_owned_course(self, _m):
        r = self.client.get(reverse('api-course-find'), {'q': 'The Bridges'})
        names = [c['name'] for c in r.data['courses']]
        self.assertIn('Bridges (The)', names)
        self.assertIn('Bridges (The) II', names)


class ARatingIsNeverInvented(TestCase):
    """No course yet found needs this; a guessed rating is wrong anyway."""

    def _course(self, **tee_over):
        tee = {'name': 'Black', 'sex': 'M', 'slope': 141,
               'course_rating': 73.6, 'par': 72, 'holes': _holes()}
        tee.update(tee_over)
        return {'id': '8zbrh5pt', 'club_name': 'Bridges (The)',
                'city': 'San Ramon', 'state': 'CA', 'tees': [tee]}

    def test_a_good_course_still_passes(self):
        self.assertEqual(assert_course_quality(self._course()), [])

    def test_no_course_rating_is_refused(self):
        with self.assertRaises(CourseQualityError) as cm:
            assert_course_quality(self._course(course_rating=None))
        joined = ' '.join(cm.exception.problems)
        self.assertIn('no course rating', joined)
        # It says WHY, because "rejected" without a reason is a dead end.
        self.assertIn('every handicap', joined)

    def test_no_slope_is_refused(self):
        with self.assertRaises(CourseQualityError):
            assert_course_quality(self._course(slope=None))

    def test_no_par_is_refused(self):
        with self.assertRaises(CourseQualityError):
            assert_course_quality(self._course(par=0))

    def test_a_rating_only_tee_is_still_a_soft_warning(self):
        """Slope/rating-only tees stay usable for gross games -- that rule
        predates this and must not be tightened by accident."""
        warnings = assert_course_quality(self._course(holes=[]))
        self.assertTrue(any('gross games only' in w for w in warnings))


class TheAdapterReportsWhatIsMissing(TestCase):
    def test_a_missing_rating_comes_through_as_none(self):
        from services.golf_api_client import _adapt_tee
        t = _adapt_tee({'tee_name': 'Black', 'slope_rating': 141,
                        'course_rating': None, 'par_total': 72,
                        'holes': []}, sex='M')
        self.assertIsNone(t['course_rating'],
                          'a fabricated 72.0 here moves every handicap')
        self.assertEqual(t['slope'], 141)

    def test_a_real_rating_is_kept(self):
        from services.golf_api_client import _adapt_tee
        t = _adapt_tee({'tee_name': 'Black', 'slope_rating': 141,
                        'course_rating': 73.6, 'par_total': 72,
                        'holes': []}, sex='M')
        self.assertEqual(t['course_rating'], 73.6)
