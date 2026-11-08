"""The texted receipt link reaching the receipt — the association file, and
the push tap.

Both had the same failure: the link opened something that was not the
receipt.  Safari, because `/r/*` is claimed by nobody; or the round's
leaderboard, because the push carries a `round_id` like every other event.
"""
import json

from django.test import SimpleTestCase, override_settings
from django.urls import reverse


class AssociationFileTests(SimpleTestCase):

    def _paths(self, url='/.well-known/apple-app-site-association'):
        r = self.client.get(url)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r['Content-Type'], 'application/json')
        body = json.loads(r.content)
        return body['applinks']['details'][0]['paths']

    def test_the_watch_link_is_always_claimed(self):
        self.assertIn('/watch/*', self._paths())

    @override_settings(RECEIPT_UNIVERSAL_LINK=False)
    def test_the_receipt_path_is_OFF_by_default(self):
        """iOS reads this file for every INSTALLED build, not just the newest.

        2.14.0 shipped without the receipt capture in `deep_links.dart`, so
        claiming the path while that is what people are running makes a
        texted link open the app and then do nothing — strictly worse than
        Safari, which at least renders the page.
        """
        self.assertNotIn('/r/*', self._paths())

    @override_settings(RECEIPT_UNIVERSAL_LINK=True)
    def test_the_setting_claims_it(self):
        paths = self._paths()
        self.assertIn('/r/*', paths)
        self.assertIn('/watch/*', paths, 'the watch link must survive it')

    @override_settings(RECEIPT_UNIVERSAL_LINK=True)
    def test_both_served_paths_agree(self):
        """Apple probes the legacy root path as well as /.well-known/, and a
        file that answered differently at the two would verify erratically."""
        self.assertEqual(self._paths(),
                         self._paths('/apple-app-site-association'))
