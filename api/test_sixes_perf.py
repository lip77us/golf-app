"""What a Sixes score POST costs.

Reported from a phone, 30 Oct 2026: *"Getting results is taking many seconds
after entering a hole."* The hole card is returned WITH the save, so anything
it does lands on the scorer's wait.

Measured before changing anything, the way the Team Play slowness was.
"""
import time

from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.db import connection
from django.urls import reverse
from rest_framework.test import APIClient

from api.test_sixes_hole_card import _Base


class SixesSavePerfTests(_Base):
    def _fill(self, upto):
        for h in range(1, upto + 1):
            self._post_hole(h, {'Ann': 4, 'Ben': 5, 'Cal': 5, 'Dee': 5})

    def _measure(self, hole):
        url = reverse('api-score-submit', args=[self.fs.id])
        body = {'hole_number': hole,
                'scores': [{'player_id': self.pid[n], 'gross_score': g}
                           for n, g in
                           {'Ann': 4, 'Ben': 5, 'Cal': 5, 'Dee': 5}.items()]}
        with CaptureQueriesContext(connection) as ctx:
            t0 = time.perf_counter()
            r = self.client.post(url, body, format='json')
            ms = (time.perf_counter() - t0) * 1000
        assert r.status_code in (200, 201), r.content
        return len(ctx.captured_queries), ms

    def test_what_a_save_costs_through_the_round(self):
        rows = []
        for upto in (0, 5, 11, 17):
            self._fill(upto)
            q, ms = self._measure(upto + 1)
            rows.append((upto + 1, q, ms))
        for hole, q, ms in rows:
            print(f'  hole {hole:>2}: {q:>4} queries  {ms:>7.1f} ms')
        # It must not grow with the round: a card for ONE hole should cost the
        # same on the 18th as on the 1st.
        first, last = rows[0][1], rows[-1][1]
        self.assertLess(last, first * 2,
                        f'the save gets dearer as the round goes on: {rows}')
