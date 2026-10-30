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

    def test_a_team_is_one_colour_for_every_reader(self):
        """Pine, clay, slate by team index — the score tray's colours. The
        first build made the READER's team blue, which put one team in two
        colours between the tray and the lock screen."""
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=4, Tom=5)
        # Each reader sees the same three colour pairs — a match's colours do
        # not move with who is holding the phone (only its label and order).
        want = {frozenset(['team_pine', 'team_clay']),
                frozenset(['team_pine', 'team_slate']),
                frozenset(['team_clay', 'team_slate'])}
        for who in ('Paul', 'Dave', 'Sam', None):
            strip = self._state(1, who=who)['strip']
            self.assertEqual({frozenset(c['dots']) for c in strip}, want,
                             f'{who} sees different colours')
        third = [c for c in self._state(1)['strip'] if not c['is_reader']][0]
        self.assertEqual(third['dots'], ['team_clay', 'team_slate'])
        mine = self._state(1)['strip'][0]
        self.assertEqual(mine['dots'], ['team_pine', 'team_clay'])

    def test_a_figure_wears_the_leading_teams_colour_and_never_says_down(self):
        # Paul & Jim beat Dave & Ray; Sam & Tom beat Paul & Jim.
        self._play(1, Paul=4, Jim=5, Dave=5, Ray=5, Sam=3, Tom=5)
        strip = self._state(1)['strip']
        v_dr, v_st, third = strip
        self.assertEqual((v_dr['figure'], v_dr['colour']),
                         ('1 UP', 'team_pine'))
        self.assertEqual((v_st['figure'], v_st['colour']),
                         ('1 UP', 'team_slate'))
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

    def test_a_cap_moves_the_floor_and_the_footer_says_so(self):
        """A $20 cap per side per Nassau: each of the two matches is
        clamped to ±$20 before summing. **±, not just the floor** — the
        engine's cap is symmetric, because with two sides the loser's cap is
        the winner's ceiling. The revised packet draws −$40 to +$60, which
        would promise a win the other side cannot be asked to pay."""
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False, press_unit=10)
        from games.models import NassauGame
        NassauGame.objects.filter(game_type__startswith='af_').update(loss_cap=20)
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        s = self._state(1)
        self.assertEqual(s['footer']['money'], '−$40 to +$40')
        self.assertEqual(s['footer']['context'], '$10 a bet · capped $20')

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
        # White, not mint: mint is the pine team's colour on this card.
        self.assertEqual(s['number']['colour'], 'white')
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
        self.assertEqual({c['dots'][1] for c in strip}, {'team_clay'})

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
        # Colour is the team's, not the reader's: the three is clay to Dave
        # too, exactly as it is on his tray.
        self.assertTrue(all(c['dots'][0] == 'team_clay' for c in mine))
        self.assertEqual([c['dim'] for c in strip].count(True), 1)


class _PushBase(_Base):
    def setUp(self):
        super().setUp()
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=True, press_unit=10)

    def _alerts(self):
        from services.live_activity_annandale_push import annandale_alerts
        return annandale_alerts(self.round)

    def _named(self, alerts):
        by_id = {v: k for k, v in self.pid.items()}
        return {by_id[p]: a for p, a in alerts.items()}


class PushTests(_PushBase):
    """**Three events ring, only for the golfers in that match, and once.**"""

    def test_the_first_call_takes_a_baseline_and_announces_nothing(self):
        for h in (1, 2):
            self._play(h, Paul=5, Jim=5, Dave=5, Ray=5, Sam=3, Tom=5)
        self.assertEqual(self._alerts(), {},
                         'a round already under way is not news')

    def test_an_auto_press_rings_only_the_two_teams_in_that_match(self):
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        self._alerts()                                   # baseline
        # Best ball is a total order within a hole, so moving ONE match takes
        # two hole shapes that swap the other two: Dave > Sam > Paul, then
        # Sam > Paul > Dave. Sam & Tom win both against Paul & Jim; the other
        # two matches go one each way and stay level.
        self._play(2, Paul=5, Jim=6, Dave=3, Ray=6, Sam=4, Tom=6)
        self.assertEqual(self._alerts(), {})
        self._play(3, Paul=4, Jim=6, Dave=5, Ray=6, Sam=3, Tom=6)
        got = self._named(self._alerts())
        self.assertEqual(set(got), {'Paul', 'Jim', 'Sam', 'Tom'},
                         'Dave & Ray are not in that match')
        self.assertEqual(got['Paul']['title'], 'Auto press v Sam & Tom')
        self.assertEqual(
            got['Paul']['body'],
            'You went 2 down on 3. A new $10 bet from hole 4 to the end of '
            'the front nine.')
        self.assertEqual(got['Sam']['title'], 'Auto press v Paul & Jim')
        self.assertTrue(got['Sam']['body'].startswith('Paul & Jim went 2 down'))

    def test_it_fires_once(self):
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        self._alerts()
        for h in (2, 3):
            self._play(h, Paul=5, Jim=5, Dave=5, Ray=5, Sam=3, Tom=5)
        self.assertTrue(self._alerts())
        self.assertEqual(self._alerts(), {}, 'the same press twice')

    def test_a_nine_closing_out_names_the_result_and_the_money(self):
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False, press_unit=10)
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        self._alerts()
        # Paul & Jim win holes 2–6 against Dave & Ray: 5 up with 3 to play.
        for h in range(2, 7):
            self._play(h, Paul=3, Jim=5, Dave=4, Ray=5, Sam=3, Tom=5)
        got = self._named(self._alerts())
        self.assertEqual(got['Paul']['title'], 'Front nine v Dave & Ray')
        self.assertEqual(got['Paul']['body'], 'You won 5&3. +$10 each.')
        self.assertEqual(got['Dave']['title'], 'Front nine v Paul & Jim')
        self.assertEqual(got['Dave']['body'], 'Paul & Jim won 5&3. −$10 each.')

    def test_the_third_match_never_pushes(self):
        """Dave & Ray v Sam & Tom closes and neither Paul nor Jim hears of
        it: each Nassau settles on its own, so it never changes what they
        settle."""
        setup_annandale_friday(self.fs, self.teams(), handicap_mode='gross',
                               auto_press=False, press_unit=10)
        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        self._alerts()
        # Paul > Sam > Dave, then Sam > Dave > Paul, alternating: Sam & Tom
        # beat Dave & Ray every hole, and both of Paul & Jim's matches swing
        # a hole each way and stay open.
        for h in range(2, 7):
            if h % 2:
                self._play(h, Paul=5, Jim=6, Dave=4, Ray=6, Sam=3, Tom=6)
            else:
                self._play(h, Paul=3, Jim=6, Dave=5, Ray=6, Sam=4, Tom=6)
        got = self._named(self._alerts())
        self.assertNotIn('Paul', got)
        self.assertNotIn('Jim', got)
        self.assertEqual(got['Sam']['title'], 'Front nine v Dave & Ray')


class PushRoundDeliversPerGolferTests(_PushBase):
    """`push_round` hands each phone ITS golfer's alert — the cup's alerts are
    one per round, and these are the first that differ between phones."""

    def test_only_the_golfers_in_the_match_get_the_sound(self):
        from unittest import mock

        from django.contrib.auth import get_user_model

        from core.models import Player
        from services import live_activity_push as lap
        from tournament.models import LiveActivityToken

        User = get_user_model()
        acct = self.round.account
        users = {}
        for name in ('Paul', 'Dave'):
            users[name] = User.objects.create_user(username=name.lower(),
                                                   account=acct)
            Player.objects.filter(pk=self.pid[name]).update(user=users[name])
            LiveActivityToken.objects.create(round=self.round,
                                             user=users[name], token=name)

        self._play(1, Paul=4, Jim=4, Dave=4, Ray=4, Sam=4, Tom=4)
        self._alerts()                                   # baseline
        self._play(2, Paul=5, Jim=6, Dave=3, Ray=6, Sam=4, Tom=6)
        self._play(3, Paul=4, Jim=6, Dave=5, Ray=6, Sam=3, Tom=6)

        with mock.patch.object(lap, 'is_enabled', return_value=True), \
             mock.patch('services.live_activity_registry.UNSHIPPED_KINDS',
                        set()), \
             mock.patch.object(lap, 'send_state',
                               return_value=True) as send:
            lap.push_round(self.round)

        alerts = {c.args[0]: c.kwargs.get('alert')
                  for c in send.call_args_list}
        self.assertEqual(alerts['Paul']['title'], 'Auto press v Sam & Tom')
        self.assertIsNone(alerts['Dave'], 'Dave & Ray are not in that match')
