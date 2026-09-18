"""
scoring/tests/test_quota_nassau_shotgun.py
------------------------------------------
Quota Nassau on a shotgun start.

Two bugs of the same family. The scorer walked 1..18 and stopped at the first
unscored hole, so a group starting on 13 scored nothing for its first six
holes; and the quota was pro-rated by HOLE NUMBER, so those six holes (ending
on the 18th) would have demanded 18/18 of the quota rather than 6/18.

Quota Nassau is a cup format and a cup day is very often a shotgun.
"""
from django.test import TestCase

from services.quota_nassau import setup_quota_nassau, calculate_quota_nassau
from ._helpers import make_tee, make_round, make_foursome, submit_hole


class QuotaNassauShotgunTests(TestCase):

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course)
        self.round.starting_hole = 13
        self.round.num_holes = 18
        self.round.save(update_fields=['starting_hole', 'num_holes'])
        self.fs = make_foursome(
            self.round, [('A', 6), ('B', 6), ('C', 6), ('D', 6)], tee=self.tee)
        self.fs.starting_hole = 13
        self.fs.save(update_fields=['starting_hole'])
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_quota_nassau(self.fs, [
            {'player1_id': self.pid['A'], 'player2_id': self.pid['C'],
             'player1_quota': 30, 'player2_quota': 30},
            {'player1_id': self.pid['B'], 'player2_id': self.pid['D'],
             'player1_quota': 30, 'player2_quota': 30},
        ])

    def _play(self, holes):
        par = {h: self.tee.hole(h)['par'] for h in holes}
        for h in holes:
            submit_hole(self.fs, h, [(self.pid[n], par[h]) for n in 'ABCD'])
        calculate_quota_nassau(self.fs)

    def test_the_first_six_holes_of_a_shotgun_are_scored(self):
        """They were dropped entirely: the walk began at hole 1, found no
        score and stopped."""
        from services.quota_nassau import quota_nassau_summary
        self._play([13, 14, 15, 16, 17, 18])
        s = quota_nassau_summary(self.fs)
        m = s['matches'][0]
        self.assertEqual(len(m['holes']), 6, 'six holes played, six scored')
        self.assertEqual([h['hole'] for h in m['holes']],
                         [13, 14, 15, 16, 17, 18])

    def test_the_quota_is_prorated_by_holes_played_not_hole_number(self):
        """Six holes ending on the 18th is 6/18 of the quota owed, not 18/18.
        Everyone plays to par, so every quota is owed the same fraction and
        the match must be level."""
        from services.quota_nassau import quota_nassau_summary
        self._play([13, 14, 15, 16, 17, 18])
        m = quota_nassau_summary(self.fs)['matches'][0]
        self.assertEqual(m['overall']['margin'], 0,
                         'identical play must be level however the round is '
                         'started')
        # And the running figure the card draws must agree.
        self.assertEqual(m['holes'][-1]['overall_margin'], 0)

    def test_a_round_from_the_first_is_unchanged(self):
        from services.quota_nassau import quota_nassau_summary
        self.round.starting_hole = 1
        self.round.save(update_fields=['starting_hole'])
        self.fs.starting_hole = 1
        self.fs.save(update_fields=['starting_hole'])
        self._play([1, 2, 3, 4, 5, 6])
        m = quota_nassau_summary(self.fs)['matches'][0]
        self.assertEqual(len(m['holes']), 6)
        self.assertEqual(m['overall']['margin'], 0)
