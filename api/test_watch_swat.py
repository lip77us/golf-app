"""The public SWAT watch pages: the whole field, the sharer's team read
against it, and the phantom never named before the round is final."""
from django.test import TestCase

from scoring.tests.test_swat import PAR, _Round


class WatchSwatTests(_Round):
    def setUp(self):
        super().setUp()
        self.round.watch_token = 'swat-tok'
        self.round.save(update_fields=['watch_token'])

    def get(self, view=''):
        return self.client.get(f'/watch/swat-tok/{view}')

    def finish(self):
        for h in range(1, 19):
            self.play(self.a, h, 0, 1, 1, 1)
            for fs in (self.b, self.c, self.d):
                self.play(fs, h, 1, 1, 1)

    def test_the_swat_tab_leads_and_names_every_team(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        r = self.get()
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        for name in ('Team Ames', 'Team Eyre', 'Team Hale', 'Team Kerr'):
            self.assertIn(name, body)
        self.assertIn('bets still open', body)

    def test_the_sharers_team_is_read_against_the_field(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        body = self.get('?view=swat').content.decode()
        self.assertIn('v the field', body)
        self.assertIn('Front', body)

    def test_the_scorecard_has_hole_par_index_and_best(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        body = self.get('?view=swat_card').content.decode()
        for word in ('Hole', 'Par', 'Index', 'Best', 'OUT'):
            self.assertIn(word, body)

    def test_the_phantom_is_not_named_while_the_round_is_live(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        self.play(self.b, 1, 1, 1, 1)
        for view in ('', '?view=swat_card'):
            body = self.get(view).content.decode()
            self.assertNotIn('Dunn', body)
            self.assertNotIn('class="don"', body)

    def test_once_final_the_donors_appear_and_money_is_shown(self):
        # The link is shared by a golfer on a threesome (Team Eyre).
        self.round.created_by_id = self.pids(self.b)[0]
        self.round.save(update_fields=['created_by'])
        self.finish()
        self.round.status = 'complete'
        self.round.save(update_fields=['status'])
        body = self.get('?view=swat_card').content.decode()
        self.assertIn('class="don"', body)
        main = self.get('?view=swat').content.decode()
        self.assertIn('MONEY BY TEAM', main)
        self.assertIn('+$54', main)
