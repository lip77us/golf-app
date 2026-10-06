"""Singles pairings: ties break on the unrounded course handicap.

Reported from a real cup draw (TPSGC 2026, group 6). Two golfers on 16.6 and
16.9 both store a playing handicap of 17, so `_sort_by_handicap` saw a tie and
`sorted` resolved it stably — by whatever order the cup setup screen sent,
i.e. the TD's click order. The lower golfer was pulled behind the higher one,
and the singles pairings were decided by something that is not golf.
"""
from decimal import Decimal

from django.test import TestCase

from core.models import Player, PlayerSex
from scoring.tests._helpers import make_tee, make_round, _test_account
from services.triple_cup import _sort_by_handicap, _unrounded_ch
from tournament.models import Foursome, FoursomeMembership


class SinglesPairingTieBreakTests(TestCase):

    def setUp(self):
        self.acct = _test_account()
        # slope 113 + rating == par, so course handicap == index exactly and
        # the fractions in the test are the ones the TD quoted.
        self.tee = make_tee(slope=113, course_rating=72.0, par=72)
        rnd = make_round(self.tee.course)
        self.fs = Foursome.objects.create(round=rnd, group_number=6)

    def _member(self, name, index, *, playing, override=None):
        p = Player.objects.create(
            account=self.acct, name=name, short_name=name,
            handicap_index=Decimal(str(index)), sex=PlayerSex.MALE)
        m = FoursomeMembership.objects.create(
            foursome=self.fs, player=p, tee=self.tee,
            course_handicap=playing, playing_handicap=playing,
            playing_handicap_override=override)
        return p.pk, m

    def test_the_lower_unrounded_handicap_goes_first(self):
        """Dan 16.6 and CC 16.9 both store 17 — Dan is the lower golfer."""
        cc,  m_cc  = self._member('CC',  16.9, playing=17)
        dan, m_dan = self._member('Dan', 16.6, playing=17)
        members = {cc: m_cc, dan: m_dan}
        # Sent CC-first, the way the setup screen happened to order them.
        self.assertEqual(_sort_by_handicap([cc, dan], members), [dan, cc])
        # And the answer must not depend on the order it was sent in.
        self.assertEqual(_sort_by_handicap([dan, cc], members), [dan, cc])

    def test_a_whole_stroke_apart_is_unaffected(self):
        lo, m_lo = self._member('Lo', 12.9, playing=13)
        hi, m_hi = self._member('Hi', 16.1, playing=16)
        members = {lo: m_lo, hi: m_hi}
        self.assertEqual(_sort_by_handicap([hi, lo], members), [lo, hi])

    def test_a_forced_handicap_compares_at_face_value(self):
        """An override IS the final number — the figure behind it was
        deliberately replaced and must not speak for the golfer."""
        # Forced to 17 off a 20.4 index; a computed 16.6 is still lower.
        forced, m_f = self._member('Frcd', 20.4, playing=17, override=17)
        dan,    m_d = self._member('Dan',    16.6, playing=17)
        members = {forced: m_f, dan: m_d}
        self.assertEqual(_sort_by_handicap([forced, dan], members),
                         [dan, forced],
                         'the computed 16.6 plays lower than a forced 17')

    def test_unknowns_still_sink_to_the_bottom(self):
        known, m_k = self._member('K', 10.0, playing=10)
        self.assertEqual(_sort_by_handicap([999, known], {known: m_k}),
                         [known, 999])

    def test_the_helper_respects_the_tee_not_just_the_index(self):
        """Two golfers on the same index but different tees do not tie."""
        hard = make_tee(course=self.tee.course, tee_name='Black',
                        slope=140, course_rating=75.0, par=72)
        a, m_a = self._member('A', 14.0, playing=14)
        m_a.tee = hard; m_a.save(update_fields=['tee'])
        b, m_b = self._member('B', 14.0, playing=14)
        self.assertGreater(_unrounded_ch(m_a), _unrounded_ch(m_b),
                           'the harder tee yields the higher course handicap')
        self.assertEqual(_sort_by_handicap([a, b], {a: m_a, b: m_b}), [b, a])
