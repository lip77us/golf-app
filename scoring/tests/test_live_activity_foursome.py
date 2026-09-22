"""
scoring/tests/test_live_activity_foursome.py
--------------------------------------------
The foursome-format card — **one composition, four games.**

Scramble, Shamble, Better Ball and Irish Rumble all put a GROUP on the board
against a field of groups, and the three figures a golfer wants off the tee are
the same in every one of them: his team's net to par, his place, and the leader
with the gap. So the tests that matter are the ones about the shared
composition, and one each for the single line that differs.

Spec: `~/Downloads/handoff-foursome-formats/HANDOFF.md` §6.
"""
from django.test import TestCase

from core.models import HandicapMode
from services.live_activity_foursome import (KIND, _place, _sides, _team_name,
                                             better_ball_state,
                                             irish_rumble_state)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    """Three groups, so a place is a place out of something."""

    def setUp(self):
        from services.better_ball import setup_better_ball
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['better_ball'])
        self.round.primary_game = 'better_ball'
        self.round.save(update_fields=['primary_game'])
        self.groups = []
        for n, names in enumerate((('A', 'B', 'C', 'D'),
                                   ('E', 'F', 'G', 'H'),
                                   ('I', 'J', 'K', 'L')), start=1):
            self.groups.append(make_foursome(
                self.round, [(x, 0) for x in names],
                tee=self.tee, group_number=n))
        self.fs, self.second, self.third = self.groups
        setup_better_ball(self.round, balls_to_count=2,
                          handicap_mode=HandicapMode.GROSS)

    def _pids(self, fs):
        return [m.player_id for m in
                fs.memberships.select_related('player').order_by('player__name')
                if not m.player.is_phantom]

    def _play(self, fs, hole, scores):
        submit_hole(fs, hole, list(zip(self._pids(fs), scores)))

    def _state(self, fs=None, **kw):
        fs = fs or self.fs
        return better_ball_state(fs, player_id=self._pids(fs)[0], **kw)


class TheThreeFiguresTests(_Base):

    def test_the_headline_is_the_teams_net_to_par(self):
        """Not a total. Two 4s on a par 4 is level, and `8` says nothing
        without doing the multiplication in your head."""
        self._play(self.fs, 1, [3, 3, 5, 5])          # best two = 6 of par 8
        self.assertEqual(self._state()['number']['text'], '−2')

    def test_the_state_slot_is_the_place_out_of_the_field(self):
        """`OF 9` is the half that makes a place mean anything: third of nine
        is a result and third of three is not."""
        self._play(self.fs, 1, [3, 3, 5, 5])
        self._play(self.second, 1, [5, 5, 6, 6])
        self._play(self.third, 1, [6, 6, 7, 7])
        state = self._state()['state']
        self.assertEqual(state['word'], '1ST')
        self.assertEqual(state['to_play'], 'OF 3')

    def test_a_tie_shows_the_T_because_a_foursome_field_ties_constantly(self):
        """The `T` is in the layout, not bolted on — a place that cannot show
        a tie is wrong most weeks rather than occasionally."""
        self._play(self.fs, 1, [4, 4, 6, 6])
        self._play(self.second, 1, [4, 4, 7, 7])
        self._play(self.third, 1, [6, 6, 7, 7])
        self.assertEqual(self._state()['state']['word'], 'T1ST')

    def test_the_place_suffixes_are_right_including_the_teens(self):
        self.assertEqual(_place(1, False), '1ST')
        self.assertEqual(_place(2, False), '2ND')
        self.assertEqual(_place(3, False), '3RD')
        self.assertEqual(_place(4, False), '4TH')
        self.assertEqual(_place(11, False), '11TH')
        self.assertEqual(_place(12, False), '12TH')
        self.assertEqual(_place(13, False), '13TH')
        self.assertEqual(_place(21, False), '21ST')
        self.assertEqual(_place(3, True), 'T3RD')
        self.assertEqual(_place(None, False), '—')


class TheLeaderLineTests(_Base):

    def test_a_chaser_is_told_who_leads_and_by_how_much(self):
        self._play(self.fs, 1, [5, 5, 6, 6])
        self._play(self.second, 1, [3, 3, 5, 5])
        side = self._state()['sides'][0]
        self.assertEqual(side['label'], 'LEADER')
        self.assertEqual(side['figure'], '4 BACK')

    def test_a_leader_is_told_who_is_coming(self):
        """**The label flips rather than the row moving.** The number he needs
        is the same one seen from the other side."""
        self._play(self.fs, 1, [3, 3, 5, 5])
        self._play(self.second, 1, [4, 4, 6, 6])
        side = self._state()['sides'][0]
        self.assertEqual(side['label'], 'NEXT')
        self.assertEqual(side['figure'], 'LEAD 2')

    def test_level_says_so_rather_than_printing_a_nought(self):
        self._play(self.fs, 1, [4, 4, 6, 6])
        self._play(self.second, 1, [4, 4, 7, 7])
        self.assertEqual(self._state()['sides'][0]['figure'], 'LEVEL')

    def test_the_line_carries_no_side_colour(self):
        """There are no sides here for a colour to mark, and a coloured dot
        would be a third accent competing with the two that mean something."""
        self._play(self.fs, 1, [3, 3, 5, 5])
        self._play(self.second, 1, [5, 5, 6, 6])
        self.assertEqual(self._state()['sides'][0]['colour'], '')

    def test_the_leader_is_a_team_never_a_golfer(self):
        """A scramble has no individual score to name one with."""
        self.assertEqual(_team_name({'name': "Reilly's Four"}),
                         "Reilly's Four")
        self.assertEqual(
            _team_name({'players': ['Ben Yau', 'Ana Salas']}),
            'Yau · Salas')

    def test_an_overrun_cuts_whole_names_only(self):
        """`Gunst · Maiolini…`, never a cut surname — a half-name reads as a
        typo rather than as an abbreviation."""
        out = _team_name({'players': ['A Gunst', 'B Maiolini',
                                      'C Fitzwilliam', 'D Abernathy']})
        self.assertTrue(out.endswith('…'), out)
        for part in out.rstrip('…').split(' · '):
            self.assertIn(part, ('Gunst', 'Maiolini', 'Fitzwilliam',
                                 'Abernathy'))

    def test_the_closing_frame_says_won_by(self):
        for h in range(1, 19):
            self._play(self.fs, h, [5, 5, 6, 6])
            self._play(self.second, h, [4, 4, 6, 6])
            self._play(self.third, h, [6, 6, 7, 7])
        side = better_ball_state(self.fs, player_id=self._pids(self.fs)[0],
                                 final=True)['sides'][0]
        self.assertEqual(side['label'], 'WON BY')


class WhatTheCardDoesNotHaveTests(_Base):

    def test_the_needle_is_sent_as_zeros_and_must_not_draw(self):
        """The key is part of the required set, so it ships — but a field of
        nine groups has neither two sides nor a pool, and reading the zeros as
        'no track' is the widget's job."""
        self._play(self.fs, 1, [4, 4, 6, 6])
        self.assertEqual(self._state()['needle'], {'blue': 0.0, 'orange': 0.0})

    def test_the_widget_refuses_to_draw_an_empty_track(self):
        """The half of that rule that lives in Swift — and the reason the
        server can keep sending a required key it does not use."""
        from pathlib import Path
        from django.conf import settings
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        self.assertIn('needle.blue + needle.orange > 0', swift)

    def test_there_are_no_cells_either(self):
        self._play(self.fs, 1, [4, 4, 6, 6])
        self.assertEqual(self._state()['pips'], [])

    def test_no_popping_band_yet(self):
        """The band is local to `triple_cup` until it has run through a cup.
        These are the first three that should have it when it rolls out."""
        self._play(self.fs, 1, [4, 4, 6, 6])
        self.assertIsNone(self._state().get('ribbon'))

    def test_this_card_never_pushes(self):
        """Nine groups resolving holes all afternoon would fire all
        afternoon. A deliberate zero, pinned so it stays one."""
        import services.live_activity_foursome as mod
        self.assertFalse([n for n in dir(mod)
                          if 'push' in n.lower() or 'alert' in n.lower()])


class TheColourRuleTests(_Base):

    def test_the_score_is_mint_while_it_is_still_a_question(self):
        self._play(self.fs, 1, [4, 4, 6, 6])
        self.assertEqual(self._state()['number']['colour'], 'mint')

    def test_the_headline_gives_up_the_mint_on_the_closing_frame(self):
        """The score has stopped being a question and the place is the
        result, so the place keeps it and the headline goes white."""
        for h in range(1, 19):
            for g in self.groups:
                self._play(g, h, [4, 4, 6, 6])
        state = better_ball_state(self.fs, player_id=self._pids(self.fs)[0],
                                  final=True)
        self.assertEqual(state['number']['colour'], 'neutral')
        self.assertEqual(state['state']['colour'], 'mint')

    def test_a_finished_round_says_round_complete_not_hole_nineteen(self):
        """A locked corner with no par and no yardage reads as a failed
        fetch."""
        for h in range(1, 19):
            for g in self.groups:
                self._play(g, h, [4, 4, 6, 6])
        state = better_ball_state(self.fs, player_id=self._pids(self.fs)[0],
                                  final=True)
        self.assertEqual(state['header']['segment'], 'ROUND COMPLETE')
        self.assertTrue(state['closed'])


class TheOneLineThatDiffersTests(_Base):

    def test_better_ball_puts_the_count_in_the_title(self):
        """The app names the game from it and it cannot change mid-round, so a
        header corner repeating it would be the same three words on all
        eighteen holes."""
        self._play(self.fs, 1, [4, 4, 6, 6])
        self.assertEqual(self._state()['header']['game'], 'BEST 2 OF 4')

    def test_a_td_named_game_titles_the_card(self):
        from services.better_ball import setup_better_ball
        setup_better_ball(self.round, balls_to_count=2, name='Saturday Sweep',
                          handicap_mode=HandicapMode.GROSS)
        self._play(self.fs, 1, [4, 4, 6, 6])
        self.assertEqual(self._state()['header']['game'], 'SATURDAY SWEEP')

    def test_rumble_puts_the_count_where_the_yardage_was(self):
        """Of hole, par and yardage, the yardage is the one nobody needs — the
        hole is in front of them and this corner is a scorecard corner, not a
        rangefinder."""
        from games.models import BetterBallConfig, IrishRumbleConfig
        BetterBallConfig.objects.filter(round=self.round).delete()
        IrishRumbleConfig.objects.create(
            round=self.round, variant='classic',
            handicap_mode=HandicapMode.GROSS, net_percent=100,
            segments=[{'start_hole': 1, 'end_hole': 6, 'balls_to_count': 2},
                      {'start_hole': 7, 'end_hole': 18, 'balls_to_count': 3}])
        self._play(self.fs, 1, [4, 4, 6, 6])
        state = irish_rumble_state(self.fs, player_id=self._pids(self.fs)[0],
                                   thru=1)
        self.assertIn('2 BALLS', state['header']['segment'])
        self.assertNotIn('YD', state['header']['segment'].upper())

    def test_one_ball_is_singular(self):
        from games.models import BetterBallConfig, IrishRumbleConfig
        BetterBallConfig.objects.filter(round=self.round).delete()
        IrishRumbleConfig.objects.create(
            round=self.round, variant='classic',
            handicap_mode=HandicapMode.GROSS, net_percent=100,
            segments=[{'start_hole': 1, 'end_hole': 18, 'balls_to_count': 1}])
        self._play(self.fs, 1, [4, 4, 6, 6])
        state = irish_rumble_state(self.fs, player_id=self._pids(self.fs)[0],
                                   thru=1)
        self.assertIn('1 BALL', state['header']['segment'])
        self.assertNotIn('1 BALLS', state['header']['segment'])

    def test_the_closer_puts_all_four_in_gold(self):
        """Gold means the stakes just went up — the same rule that keeps
        Skins' carry and Banker's counter-double amber. It rides its own
        field, so answering the open question the other way is deleting a
        line rather than unpicking a string."""
        from games.models import BetterBallConfig, IrishRumbleConfig
        BetterBallConfig.objects.filter(round=self.round).delete()
        IrishRumbleConfig.objects.create(
            round=self.round, variant='classic',
            handicap_mode=HandicapMode.GROSS, net_percent=100,
            segments=[{'start_hole': 1, 'end_hole': 17, 'balls_to_count': 3},
                      {'start_hole': 18, 'end_hole': 18, 'balls_to_count': 4}])
        for h in range(1, 18):
            for g in self.groups:
                self._play(g, h, [4, 4, 6, 6])
        state = irish_rumble_state(self.fs, player_id=self._pids(self.fs)[0],
                                   thru=17)
        self.assertEqual(state['header']['tail'], 'ALL 4')
        self.assertNotIn('ALL 4', state['header']['segment'])


class TheContractTests(_Base):

    def test_four_games_would_draw_one_card(self):
        from services.live_activity_registry import BUILDERS, card_kind
        for slug in ('better_ball', 'irish_rumble', 'scramble'):
            self.assertIn(slug, BUILDERS)
            self.assertEqual(card_kind(slug), KIND)

    def test_shamble_is_written_but_not_registered(self):
        """**A slug `primary_game` can never return.** A shamble here is a Team
        Play format, and `team_play` is a marker on the TOURNAMENT with no
        round-level game identity — so a builder keyed on `shamble` is a
        branch nothing can reach. The adapter exists for the day that question
        is answered; registering it before then would put a dead key in the
        contract that reads as a shipped feature.
        """
        import services.live_activity_foursome as mod
        from services.live_activity_registry import BUILDERS
        self.assertTrue(hasattr(mod, 'shamble_state'))
        self.assertNotIn('shamble', BUILDERS)

    def test_the_card_is_gated_until_the_build_carrying_it_goes_out(self):
        """A kind enters `UNSHIPPED_KINDS` with its builder and leaves in the
        commit that bumps the build. These four games have NO card today, so
        an ungated kind would replace nothing at all with a lock-screen nag
        pointing at an update that does not exist."""
        from services.live_activity_registry import UNSHIPPED_KINDS
        self.assertIn(KIND, UNSHIPPED_KINDS)

    def test_every_slot_it_sends_decodes(self):
        from pathlib import Path
        from django.conf import settings
        contract = (Path(settings.BASE_DIR) / 'mobile' / 'ios'
                    / 'SixesActivity' / 'SixesActivity.swift').read_text()
        self._play(self.fs, 1, [4, 4, 6, 6])
        self._play(self.second, 1, [5, 5, 6, 6])
        s = self._state()
        for key in s:
            self.assertTrue(f'let {key}:' in contract or f'var {key}:' in contract,
                            f'`{key}` has no field in ContentState')
        for key in s['header']:
            self.assertTrue(f'let {key}:' in contract or f'var {key}:' in contract,
                            f'header.{key} has no field')
        for key in s['sides'][0]:
            self.assertTrue(f'let {key}:' in contract or f'var {key}:' in contract,
                            f'sides.{key} has no field')

    def test_the_widget_can_already_draw_it(self):
        """The Swift lands first; the gate comes off in the commit that bumps
        the build carrying it. That order is the only safe one."""
        import re
        from pathlib import Path
        from django.conf import settings
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        known = re.search(r'static let known: Set<String> = \[(.*?)\]',
                          swift, re.S).group(1)
        self.assertIn(f'"{KIND}"', known)
