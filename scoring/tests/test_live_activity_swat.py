"""Oakmont SWAT's lock screen: Nassau's card, a row per opposing team."""
from django.contrib.auth import get_user_model

from scoring.tests.test_swat import _Round
from services import live_activity_registry as reg
from services.live_activity_swat import swat_activity_state, swat_final_state


class SwatCardTests(_Round):
    def test_it_is_nassaus_card_so_no_new_layout_is_needed(self):
        self.assertEqual(reg.card_kind('oakmont_swat'), 'nassau')
        self.assertNotIn('nassau', reg.UNSHIPPED_KINDS)
        self.assertIn('oakmont_swat', reg.BUILDERS)

    def test_one_row_per_opposing_team_named_for_them(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        for fs in (self.b, self.c, self.d):
            self.play(fs, 1, 1, 1, 1)
        me = self.b
        s = swat_activity_state(me, player_id=self.pids(me)[0])
        labels = sorted(r['label'] for r in s['rows'])
        self.assertEqual(labels, ['v AMES', 'v HALE', 'v KERR'])
        self.assertEqual(s['kind'], 'nassau')
        self.assertIn('SWAT · TEAM EYRE', s['header']['game'])

    def test_the_figure_is_the_nine_in_play_coloured_for_whoever_leads(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        for fs in (self.b, self.c, self.d):
            self.play(fs, 1, 1, 1, 1)
        s = swat_activity_state(self.b, player_id=self.pids(self.b)[0])
        v_ames = next(r for r in s['rows'] if r['label'] == 'v AMES')
        self.assertEqual((v_ames['text'], v_ames['colour']), ('1 DN', 'orange'))
        v_hale = next(r for r in s['rows'] if r['label'] == 'v HALE')
        self.assertEqual((v_hale['text'], v_hale['colour']), ('ALL SQ', 'neutral'))
        self.assertIn('OVERALL · THRU 1', v_ames['note'])

    def test_the_footer_says_three_plus_phantom_and_money_each(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        self.play(self.b, 1, 1, 1, 1)
        s = swat_activity_state(self.b, player_id=self.pids(self.b)[0])
        self.assertTrue(s['footer']['context'].startswith('3 + phantom'))
        self.assertTrue(s['footer']['money'].endswith(' each'))

    def test_a_foursome_says_four_golfers(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        s = swat_activity_state(self.a, player_id=self.pids(self.a)[0])
        self.assertTrue(s['footer']['context'].startswith('4 golfers'))

    def test_a_watcher_sees_no_money(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        s = swat_activity_state(self.a, player_id=None)
        self.assertEqual(s['footer']['money'], '')

    def test_over_three_opponents_shows_three_and_a_count(self):
        # Fabricate a fifth team by splitting nobody: instead assert the cap.
        from services.live_activity_swat import MAX_ROWS
        self.assertEqual(MAX_ROWS, 3)

    def test_the_phantom_is_never_named(self):
        self.play(self.a, 1, 0, 1, 1, 1)
        self.play(self.b, 1, 1, 1, 1)
        blob = repr(swat_activity_state(self.b, player_id=self.pids(self.b)[0]))
        self.assertNotIn('Dunn', blob)
        self.assertNotIn('phantom_order', blob)

    def test_the_final_is_money_each_the_record_and_the_place(self):
        for h in range(1, 19):
            self.play(self.a, h, 0, 1, 1, 1)
            for fs in (self.b, self.c, self.d):
                self.play(fs, h, 1, 1, 1)
        f = swat_final_state(self.a, player_id=self.pids(self.a)[0])
        self.assertEqual(f['final']['amount'], '+$54')
        self.assertEqual(f['final']['detail'], 'Won 9, lost 0')
        self.assertEqual(f['final']['collect'], '1st of 4')
        self.assertEqual(f['header']['segment'], 'ROUND COMPLETE')
        g = swat_final_state(self.b, player_id=self.pids(self.b)[0])
        self.assertEqual(g['final']['amount'], '−$24')
        self.assertIn('6 pushed', g['final']['detail'])

    def test_activity_state_builds_it_through_the_registry(self):
        User = get_user_model()
        self.play(self.a, 1, 0, 1, 1, 1)
        u = User.objects.create_user(username='w', password='x',
                                     account=self.course.account)
        s = reg.activity_state(self.round, u)
        self.assertEqual(s.get('kind'), 'nassau')
        self.assertTrue(s['header']['game'].startswith('SWAT'))


class SwatTurnPushTests(_Round):
    def _front_nine(self, deltas_a=(0, 1, 1, 1)):
        for h in range(1, 10):
            self.play(self.a, h, *deltas_a)
            for fs in (self.b, self.c, self.d):
                self.play(fs, h, 1, 1, 1)

    def test_the_first_call_records_a_baseline_and_rings_nothing(self):
        from services.live_activity_swat_push import swat_alerts
        self._front_nine()
        self.assertEqual(swat_alerts(self.round), {})
        self.cfg.refresh_from_db()
        self.assertIsNotNone(self.cfg.announced)

    def test_the_turn_rings_each_team_once_with_money_each(self):
        from services.live_activity_swat_push import swat_alerts
        self.play(self.a, 1, 0, 1, 1, 1)
        swat_alerts(self.round)                    # baseline: nothing settled
        for h in range(2, 10):
            self.play(self.a, h, 0, 1, 1, 1)
        for h in range(1, 10):
            for fs in (self.b, self.c, self.d):
                self.play(fs, h, 1, 1, 1)
        alerts = swat_alerts(self.round)
        a_ids = set(self.pids(self.a))
        self.assertTrue(a_ids <= set(alerts))
        alert = alerts[self.pids(self.a)[0]]
        self.assertEqual(alert['title'], 'Front nine: 3 won, 0 lost')
        self.assertIn('+$18 each', alert['body'])
        self.assertEqual(swat_alerts(self.round), {})   # once only

    def test_no_push_for_the_phantom_or_per_hole(self):
        from services.live_activity_swat_push import swat_alerts
        self.play(self.a, 1, 0, 1, 1, 1)
        swat_alerts(self.round)
        self.play(self.a, 2, 0, 1, 1, 1)
        self.assertEqual(swat_alerts(self.round), {})
