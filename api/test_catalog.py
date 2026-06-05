"""
api/test_catalog.py
-------------------
Tests for the shared course catalog + copy-on-add (local tee priority preserved).
"""

from decimal import Decimal
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import CatalogCourse, Course, Tee


User = get_user_model()


def _holes():
    return [
        {'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
        for n in range(1, 19)
    ]


def _fake_api_course(course_id=99):
    """An adapted GolfCourseAPI course dict (shape of fetch_course's return)."""
    return {
        'id'         : course_id,
        'club_name'  : 'Pebble Beach',
        'course_name': 'Pebble Beach',
        'city'       : 'Pebble Beach',
        'state'      : 'CA',
        'country'    : 'United States',
        'latitude'   : Decimal('36.5681'),
        'longitude'  : Decimal('-121.9486'),
        'tees': [
            {'name': 'Blue',  'slope': 130, 'course_rating': Decimal('72.1'),
             'par': 72, 'sex': 'M', 'holes': _holes()},
            {'name': 'White', 'slope': 122, 'course_rating': Decimal('70.4'),
             'par': 72, 'sex': 'M', 'holes': _holes()},
        ],
    }


def _admin(account_name, username):
    account = Account.objects.create(name=account_name)
    user = User.objects.create_user(username=username, account=account)
    user.is_account_admin = True
    user.save(update_fields=['is_account_admin'])
    return account, user


class CatalogImportTests(TestCase):
    def setUp(self):
        self.account, self.user = _admin('Acct A', 'a')
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    @patch('services.golf_api_client.fetch_course')
    def test_import_populates_catalog_and_account_copy(self, mock_fetch):
        mock_fetch.return_value = _fake_api_course(99)
        resp = self.client.post(
            reverse('api-course-import'), {'course_id': 99}, format='json',
        )
        self.assertEqual(resp.status_code, 201, resp.data)

        cc = CatalogCourse.objects.get(golf_api_id='99')
        self.assertEqual(cc.state, 'CA')
        self.assertEqual(cc.tees.count(), 2)

        course = Course.objects.get(account=self.account, golf_api_id='99')
        self.assertEqual(course.city, 'Pebble Beach')
        self.assertEqual(course.tees.count(), 2)
        # default_sort_priority seeded the account copy's sort_priority.
        self.assertEqual(
            sorted(course.tees.values_list('sort_priority', flat=True)),
            sorted(cc.tees.values_list('default_sort_priority', flat=True)),
        )

    @patch('services.golf_api_client.fetch_course')
    def test_second_account_adds_from_catalog_without_api_call(self, mock_fetch):
        # Account A imports (populates the catalog).
        mock_fetch.return_value = _fake_api_course(99)
        self.client.post(reverse('api-course-import'), {'course_id': 99},
                         format='json')
        cc = CatalogCourse.objects.get(golf_api_id='99')

        # Account B adds from the catalog — should NOT hit the GolfCourseAPI.
        _account_b, user_b = _admin('Acct B', 'b')
        client_b = APIClient()
        client_b.force_authenticate(user_b)
        mock_fetch.reset_mock()

        resp = client_b.post(
            reverse('api-catalog-course-add', args=[cc.pk]), {}, format='json',
        )
        self.assertEqual(resp.status_code, 201, resp.data)
        mock_fetch.assert_not_called()
        self.assertTrue(
            Course.objects.filter(account=_account_b, golf_api_id='99').exists()
        )

        # Idempotent re-add.
        resp2 = client_b.post(
            reverse('api-catalog-course-add', args=[cc.pk]), {}, format='json',
        )
        self.assertEqual(resp2.status_code, 200)
        self.assertEqual(
            Course.objects.filter(account=_account_b, golf_api_id='99').count(), 1
        )

    @patch('services.golf_api_client.fetch_course')
    def test_local_tee_priority_is_isolated(self, mock_fetch):
        mock_fetch.return_value = _fake_api_course(99)
        self.client.post(reverse('api-course-import'), {'course_id': 99},
                         format='json')
        cc = CatalogCourse.objects.get(golf_api_id='99')

        _account_b, user_b = _admin('Acct B', 'b')
        client_b = APIClient(); client_b.force_authenticate(user_b)
        client_b.post(reverse('api-catalog-course-add', args=[cc.pk]), {},
                      format='json')

        # Account A bumps a tee's local priority.
        a_tee = Tee.objects.filter(course__account=self.account).first()
        a_tee.sort_priority = 1
        a_tee.save(update_fields=['sort_priority'])

        # Catalog default and Account B's copy are untouched.
        self.assertNotIn(
            1, cc.tees.values_list('default_sort_priority', flat=True),
        )
        self.assertNotIn(
            1,
            Tee.objects.filter(course__account=_account_b)
            .values_list('sort_priority', flat=True),
        )

    @patch('services.golf_api_client.fetch_course')
    def test_catalog_search_flags_owned(self, mock_fetch):
        mock_fetch.return_value = _fake_api_course(99)
        self.client.post(reverse('api-course-import'), {'course_id': 99},
                         format='json')

        resp = self.client.get(reverse('api-catalog-courses'), {'q': 'pebble'})
        self.assertEqual(resp.status_code, 200)
        courses = resp.data['courses']
        self.assertEqual(len(courses), 1)
        self.assertTrue(courses[0]['already_in_account'])
        self.assertEqual(courses[0]['tee_count'], 2)

        # A different account hasn't added it.
        _account_b, user_b = _admin('Acct B', 'b')
        client_b = APIClient(); client_b.force_authenticate(user_b)
        resp_b = client_b.get(reverse('api-catalog-courses'), {'q': 'pebble'})
        self.assertFalse(resp_b.data['courses'][0]['already_in_account'])
