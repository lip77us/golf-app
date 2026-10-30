"""
scoring/tests/test_live_activity_annandale_friday.py
----------------------------------------------------
The Annandale Friday lock screen (`handoff-annandale-friday-lock`).

It is the Triple Nassau card with the matches between TEAMS, so what is
pinned here is what changes: two-line team labels, colour by team with the
reader's team blue, which columns are at weight for which reader, and the
exposure range across every bet the reader is party to — six at $10 open at
−$60 to +$60, the pair in a five at −$90 to +$90.
"""
from django.test import TestCase

from services.annandale_friday import (calculate_annandale_friday,
                                       setup_annandale_friday)
from services.live_activity_annandale_friday import (
    annandale_friday_activity_state, annandale_friday_final_state)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    """Gross, $10 a bet, no auto press unless a test asks — so the nets are
    the scores and the exposure arithmetic is the packet's."""
    NAMES = ('Paul', 'Jim', 'Dave', 'Ray', 'Sam', 'Tom')
    SIZE = 6

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course,
                                active_games=['annandale_friday'])
        self.round.bet_unit = 10
        self.round.primary_game = 'annandale_friday'
        self.round.save(update_fields=['bet_unit', 'primary_game'])
        names = self.NAMES[:self.SIZE]
        self.fs = make_foursome(self.round, [(n, 0) for n in names],
                                tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False, press_unit=10)

    def teams(self):
        p = self.pid
        return [[p['Paul'], p['Jim']], [p['Dave'], p['Ray']],
                [p['Sam'], p['Tom']]]

    def _play(self, hole, **gross):
        submit_hole(self.fs, hole, [(self.pid[n], g) for n, g in gross.items()])
        calculate_annandale_friday(self.fs)

    def _state(self, thru, who='Paul'):
        return annandale_friday_activity_state(
            self.fs, player_id=self.pid[who] if who else None, thru=thru)


class SixGolferTests(_Base):

    def test_the_header_names_the_game_and_the_bet(self):
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=4, Tom=5)
        s = self._state(1)
        self.assertEqual(s['kind'], 'annandale_friday')
        self.assertEqual(s['header']['game'], 'ANNANDALE FRIDAY')
        self.assertEqual(s['header']['segment'], 'HOLE 2 · FRONT 9')

    def test_labels_are_two_lines_one_team_each(self):
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=4, Tom=5)
        strip = self._state(1)['strip']
        self.assertEqual([(c['label'], c['label2']) for c in strip], [
            ('YOU', 'v DAVE·RAY'),
            ('YOU', 'v SAM·TOM'),
            ('DAVE·RAY', 'v SAM·TOM'),
        ])

    def test_your_team_is_blue_and_the_others_orange_and_plum(self):
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=4, Tom=5)
        for who in ('Paul', 'Dave', 'Sam'):
            strip = self._state(1, who=who)['strip']
            mine = [c for c in strip if c['is_reader']]
            self.assertEqual(len(mine), 2)
            self.assertTrue(all(c['dots'][0] == 'blue' for c in mine),
                            f'{who}: his own team is blue, on top')
            theirs = [c for c in strip if not c['is_reader']][0]
            self.assertEqual(set(theirs['dots']), {'orange', 'plum'})

    def test_a_figure_wears_the_leading_teams_colour_and_never_says_down(self):
        # Paul & Jim beat Dave & Ray; Sam & Tom beat Paul & Jim.
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=3, Tom=5)
        strip = self._state(1)['strip']
        v_dr, v_st, third = strip
        self.assertEqual((v_dr['figure'], v_dr['colour']), ('1 UP', 'blue'))
        self.assertEqual(v_st['figure'], '1 UP')
        self.assertIn(v_st['colour'], ('orange', 'plum'))
        self.assertNotEqual(v_st['colour'], 'blue')
        for c in strip:
            self.assertNotIn('DN', c['figure'])

    def test_level_is_all_square_and_owns_no_colour(self):
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        for c in self._state(1)['strip']:
            self.assertEqual((c['figure'], c['colour'], c['rule']),
                             ('ALL SQ', '', ''))

    def test_the_third_match_is_held_back_never_dropped(self):
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=4, Tom=5)
        strip = self._state(1)['strip']
        self.assertEqual(len(strip), 3)
        self.assertEqual([c['dim'] for c in strip], [False, False, True])

    def test_a_watcher_holds_nothing_back(self):
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=4, Tom=5)
        s = self._state(1, who=None)
        self.assertFalse(any(c['dim'] for c in s['strip']))
        self.assertFalse(any(c['label'] == 'YOU' for c in s['strip']))
        self.assertEqual(s['footer']['money'], '')

    def test_exposure_opens_at_sixty_each_way(self):
        """2 Nassaus × 3 bets × $10 — the packet's own figure."""
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        s = self._state(1)
        self.assertEqual(s['footer']['money'], '−$60 to +$60')
        self.assertEqual(s['footer']['context'], '$10 a bet')

    def test_a_press_is_a_chip_on_its_figure_and_widens_the_range(self):
        from services.annandale_friday import press_annandale
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False, manual_press=True,
                               press_unit=10)
        self._play(1, Paul=5, Jim=5, Dave=4, Ray=5, Sam=5, Tom=5)
        press_annandale(self.fs, 1, 2)
        s = self._state(1)
        self.assertEqual(s['strip'][0]['chip'], '+1')
        self.assertEqual(s['footer']['money'], '−$70 to +$70')

    def test_the_thru_corner_is_the_readers_own_gross(self):
        self._play(1, Paul=5, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        self.assertIn('+1', self._state(1)['thru'])


class FinalTests(_Base):

    def _round(self):
        # Paul & Jim beat Dave & Ray every hole and lose every hole to
        # Sam & Tom: +$30 and −$30, net zero.
        for h in range(1, 19):
            self._play(h, Paul=4, Jim=5, Dave=5, Ray=5, Sam=3, Tom=5)
        return annandale_friday_final_state(self.fs,
                                            player_id=self.pid['Paul'])

    def test_the_board_stays_with_money_in_place_of_holes(self):
        s = self._round()
        self.assertTrue(s['closed'])
        self.assertIsNone(s['final'])
        self.assertEqual(s['header']['segment'], 'ROUND COMPLETE')
        self.assertEqual([c['figure'] for c in s['strip']][:2],
                         ['+$30', '−$30'])
        self.assertTrue(all(c['rule'] == '' for c in s['strip']))

    def test_the_headline_is_the_readers_net_and_his_match_count(self):
        s = self._round()
        self.assertEqual(s['number']['text'], 'EVEN')
        self.assertEqual(s['state']['word'], '2 NASSAUS')

    def test_the_footer_names_whom_to_collect_from_and_pay(self):
        ctx = self._round()['footer']['context']
        self.assertEqual(
            ctx, 'Each · collect $30 from Dave & Ray · pay Sam & Tom $30')


class FiveGolferTests(_Base):
    SIZE = 5

    def teams(self):
        p = self.pid
        return [[p['Paul'], p['Jim']], [p['Dave'], p['Ray'], p['Sam']]]

    def test_the_pair_has_all_three_at_weight(self):
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4)
        strip = self._state(1)['strip']
        self.assertTrue(all(c['is_reader'] for c in strip))
        self.assertFalse(any(c['dim'] for c in strip))
        self.assertTrue(all(c['label'] == 'YOU' for c in strip))

    def test_the_three_is_one_team_and_one_colour(self):
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4)
        strip = self._state(1)['strip']
        self.assertEqual({c['dots'][1] for c in strip}, {'orange'})

    def test_the_pairs_range_is_nine_bets(self):
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4)
        s = self._state(1)
        self.assertEqual(s['footer']['money'], '−$90 to +$90')
        self.assertEqual(s['footer']['context'], '$10 a bet · 5 golfers')

    def test_one_of_the_three_names_his_partner_in_each_match(self):
        """Departure from the packet: his partner changes match to match, so
        `YOU` alone would hide the one thing that differs between columns."""
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4)
        strip = self._state(1, who='Dave')['strip']
        mine = [c for c in strip if c['is_reader']]
        self.assertEqual(len(mine), 2)
        self.assertEqual(sorted(c['label'] for c in mine),
                         ['YOU·RAY', 'YOU·SAM'])
        self.assertTrue(all(c['dots'][0] == 'blue' for c in mine))
        self.assertEqual([c['dim'] for c in strip].count(True), 1)
