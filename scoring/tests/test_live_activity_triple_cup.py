"""
scoring/tests/test_live_activity_triple_cup.py
----------------------------------------------
The Triple Cup lock screen.

One eighteen-hole round cut into thirds — Fourball, Foursomes, two Singles run
together — for four points, where 2½ wins the cup and 2–2 halves it.

Spec: `~/Downloads/handoff-lock-screens 2/triple-cup/HANDOFF.md`.
"""
from decimal import Decimal

from django.test import TestCase

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):

    def setUp(self):
        from services.triple_cup import setup_triple_cup
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['triple_cup'])
        self.round.primary_game = 'triple_cup'
        self.round.bet_unit = Decimal('5.00')
        self.round.save(update_fields=['primary_game', 'bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Tom Hayes', 0), ('Lee Naylor', 0),
             ('Sam Reid', 0), ('Dave Moran', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['Tom Hayes'], self.pid['Lee Naylor']],
            team2_ids=[self.pid['Sam Reid'], self.pid['Dave Moran']],
            handicap_mode='gross')

    def _play(self, hole, hayes, naylor, reid, moran):
        from services.triple_cup import calculate_triple_cup
        submit_hole(self.fs, hole, [
            (self.pid['Tom Hayes'], hayes), (self.pid['Lee Naylor'], naylor),
            (self.pid['Sam Reid'], reid), (self.pid['Dave Moran'], moran)])
        calculate_triple_cup(self.fs)

    def _state(self, thru, who='Tom Hayes'):
        from services.live_activity_triple_cup import triple_cup_activity_state
        return triple_cup_activity_state(
            self.fs, player_id=self.pid[who] if who else None, thru=thru)


class HeadlineTests(_Base):

    def test_the_headline_is_the_cup_score_including_nil_nil(self):
        """A headline that means one thing before the first point and another
        after is a slot nobody can learn. `0–0` over four grey cells is the
        complete and true state of the cup on the third tee."""
        self.assertEqual(self._state(0)['number']['text'], '0–0')

    def test_level_is_neutral_never_mint(self):
        """Mint is the app's colour, not a side's."""
        self.assertEqual(self._state(0)['number']['colour'], 'neutral')

    def test_the_headline_is_not_the_match_in_front_of_you(self):
        """Triple Cup exists to produce a cup score; the match you are in is a
        way of earning one point in it, and gets the smaller slot."""
        self._play(1, 3, 4, 5, 5)
        s = self._state(1)
        self.assertNotIn('UP', s['number']['text'])
        self.assertIn('UP', s['state']['word'] + s['state']['to_play'])

    def test_halves_read_as_halves_not_decimals(self):
        from services.live_activity_triple_cup import _score
        self.assertEqual(_score(2.5), '2½')
        self.assertEqual(_score(3), '3')
        self.assertEqual(_score(0), '0')


class StateSlotTests(_Base):

    def test_it_names_the_segment_so_the_live_third_is_never_inferred(self):
        self._play(1, 3, 4, 5, 5)
        self.assertTrue(self._state(1)['state']['to_play'].startswith('IN THE'))

    def test_the_margin_is_written_from_the_readers_side(self):
        """Team 1 is 1 up, so team 2's reader is 1 down — not 1 up."""
        self._play(1, 3, 4, 5, 5)
        mine = self._state(1, who='Tom Hayes')['state']['word']
        theirs = self._state(1, who='Sam Reid')['state']['word']
        self.assertEqual(mine, '1 UP')
        self.assertEqual(theirs, '1 DN')

    def test_the_cup_outranks_the_hole_when_it_cannot_be_lost(self):
        """The single moment the cup takes the slot from the match."""
        from services.live_activity_triple_cup import _cannot_lose
        self.assertTrue(_cannot_lose(2, 1, 4))     # one out, worst case 2–2
        self.assertFalse(_cannot_lose(1, 1, 4))    # two out
        self.assertFalse(_cannot_lose(1, 0, 4))


class StripTests(_Base):
    """Four cells are the FORMAT, not a guess — which is why this card can
    carry a structure graphic where Sixes could not. Sixes cut its pips because
    a round has no fixed number of matches."""

    def test_four_cells_and_all_of_them_out_at_the_start(self):
        s = self._state(0)
        self.assertEqual(len(s['pips']), 4)
        self.assertEqual(set(s['pips']), {'out'})

    def test_a_banked_point_takes_its_side_s_colour(self):
        from services.live_activity_triple_cup import _cells
        summary = {'matches': [
            {'status': 'complete', 'result': 'team1'},
            {'status': 'complete', 'result': 'team2'},
            {'status': 'complete', 'result': 'halved'},
            {'status': 'in_progress', 'result': None},
        ]}
        self.assertEqual(_cells(summary),
                         ['blue', 'orange', 'halved', 'out'])


class SidesLineTests(_Base):
    """**One row, everywhere.** A row each measured 163pt — over the ceiling on
    its own — and the second sides row is the most expensive line in the set at
    18pt. Abbreviating to surnames buys both matches for nothing."""

    def test_the_sides_line_never_carries_more_than_two_entries(self):
        """**One ROW, not one entry.** The entries run ACROSS — the widget
        lays them out in an HStack — so two of them are a line, not two lines.
        What the ceiling forbids is a third: the format's only simultaneous
        state is the two Singles, and that is deliberate.
        """
        for thru in (0, 1, 7, 13, 18):
            for h in range(1, thru + 1):
                self._play(h, 4, 4, 4, 4)
            self.assertLessEqual(len(self._state(thru)['sides']), 2,
                                 f'three entries would wrap at thru {thru}')

    def test_the_entries_run_across_rather_than_down(self):
        """The assertion the height depends on, and it lives in the widget:
        a VStack here is the 18pt that puts this card over the ceiling."""
        from pathlib import Path
        from django.conf import settings
        swift = (Path(settings.BASE_DIR) / 'mobile' / 'ios' / 'SixesActivity'
                 / 'SixesActivityLiveActivity.swift').read_text()
        body = swift.split('private struct CupSidesView')[1][:600]
        self.assertIn('HStack', body)
        self.assertNotIn('VStack', body)

    def test_the_two_singles_share_that_row_with_the_readers_first(self):
        for h in range(1, 14):
            self._play(h, 4, 4, 4, 4)
        sides = self._state(13)['sides']
        if len(sides) == 2 and sides[0]['names'].startswith('You'):
            self.assertTrue(sides[0]['leading'],
                            'the reader own single leads the row')
            self.assertTrue(sides[1]['note'].startswith('·'),
                            'the other single keeps its standing')

    def test_every_entry_carries_a_side_colour(self):
        """Unlike the personal three, this line HAS sides — yours and theirs
        — so every entry gets a dot, and yours is the one at full weight."""
        self._play(1, 3, 4, 5, 5)
        for side in self._state(1)['sides']:
            self.assertIn(side['colour'], ('blue', 'orange'))


class FooterTests(_Base):

    def test_the_stake_is_per_man(self):
        self.assertEqual(self._state(0)['footer']['context'], '$5 a man')

    def test_the_money_is_empty_until_the_cup_settles(self):
        self._play(1, 3, 4, 5, 5)
        self.assertEqual(self._state(1)['footer']['money'], '')


class _TeamCupBase(TestCase):
    """Two groups in a cup worth eight points — enough that a group's own
    four are genuinely a share of something larger, which is the premise of
    this configuration."""


    def setUp(self):
        from datetime import date
        from core.models import GameType
        from tournament.models import (Tournament, TeamTournament,
                                       TournamentTeam, RyderCupRoundConfig,
                                       RyderCupFoursomeConfig)
        from services.triple_cup import setup_triple_cup
        from ._helpers import (make_tee, make_round, make_foursome,
                               _test_account)

        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        tourn = Tournament.objects.create(
            account=_test_account(), name='Cup', start_date=date(2026, 1, 1))
        self.tt = TeamTournament.objects.create(
            tournament=tourn, cup_name='Sheldon Cup', players_per_team=4)
        self.t1 = TournamentTeam.objects.create(
            tournament=self.tt, name='Blue', team_number=1, colour='blue')
        self.t2 = TournamentTeam.objects.create(
            tournament=self.tt, name='Orange', team_number=2, colour='orange')
        self.round.tournament = tourn
        self.round.save(update_fields=['tournament'])
        self.rc = RyderCupRoundConfig.objects.create(
            round=self.round, tournament=self.tt,
            nassau_point_value=1, point_multiplier=1)

        # TWO groups, so the cup is eight points and a group's own four are
        # genuinely a share of something larger — which is the whole premise
        # of this configuration.
        self.groups = []
        for n, names in enumerate((('A', 'B', 'C', 'D'),
                                   ('E', 'F', 'G', 'H')), start=1):
            fs = make_foursome(self.round, [(x, 0) for x in names],
                               tee=self.tee, group_number=n)
            m = {x.player.name: x
                 for x in fs.memberships.select_related('player')}
            self.t1.players.add(m[names[0]].player, m[names[1]].player)
            self.t2.players.add(m[names[2]].player, m[names[3]].player)
            RyderCupFoursomeConfig.objects.create(
                foursome=fs, round_config=self.rc,
                game_type=GameType.TRIPLE_CUP,
                team1=self.t1, team2=self.t2, point_value=1)
            setup_triple_cup(
                fs,
                team1_ids=[m[names[0]].player_id, m[names[1]].player_id],
                team2_ids=[m[names[2]].player_id, m[names[3]].player_id],
                handicap_mode='gross')
            self.groups.append((fs, m))
        self.fs, self.m = self.groups[0]

    # -- helpers ------------------------------------------------------------

    def _sweep(self, group, holes, winner='team1'):
        """Run `holes` of a group with one side winning every one of them."""
        from services.triple_cup import calculate_triple_cup
        from ._helpers import submit_hole
        fs, m = group
        names = sorted(m)
        good, bad = (names[:2], names[2:]) if winner == 'team1' \
            else (names[2:], names[:2])
        for h in holes:
            par = self.tee.hole(h)['par']
            submit_hole(fs, h, [(m[n].player_id, par) for n in good]
                        + [(m[n].player_id, par + 2) for n in bad])
        calculate_triple_cup(fs)

    def _state(self, thru, who='A'):
        from services.live_activity_triple_cup import triple_cup_activity_state
        return triple_cup_activity_state(
            self.fs, player_id=self.m[who].player_id, thru=thru)


class TeamCupThroughTheRegistryTests(_TeamCupBase):
    """The team-cup card, reached the way a phone reaches it.

    Every other test in this file calls `triple_cup_activity_state` DIRECTLY,
    which skips the one decision a real round has to get right first: which
    card the round is. `activity_state` picks ONE game per round — the stored
    primary, else the first entry in `active_games` — and a tournament round
    has no stored primary. So the card a cup round draws is decided by the
    ORDER of that list, and until this class nothing had ever built one the
    way the cup wizard does.

    The wizard writes a Triple-Cup-only round as `['triple_cup']` and APPENDS
    a field-wide side game after it, so the realistic list is below.

    **The headline is the whole cup, and it moves when a point lands in a
    group you are not in.** `push_round` rebuilds the card for every phone
    registered on the round rather than for the group that scored, so this is
    what a captain in group 1 sees when group 2 wins its fourball.
    """

    def setUp(self):
        super().setUp()
        from django.contrib.auth import get_user_model
        self.round.active_games = ['triple_cup', 'irish_rumble']
        self.round.primary_game = None
        self.round.save(update_fields=['active_games', 'primary_game'])
        User = get_user_model()
        self.users = {}
        for group, who in ((0, 'A'), (1, 'E')):
            u = User.objects.create_user(username=f'cup_{who}',
                                         account=self.round.account)
            player = self.groups[group][1][who].player
            player.user = u
            player.save(update_fields=['user'])
            self.users[who] = u

    def _card(self, who='A'):
        from services.live_activity_registry import activity_state
        return activity_state(self.round, self.users[who])

    def test_a_triple_cup_only_cup_round_draws_the_team_cup_card(self):
        self._sweep(self.groups[0], range(1, 7))
        card = self._card()
        self.assertEqual(card['kind'], 'triple_cup')
        self.assertIn('SHELDON CUP', card['header']['game'])
        self.assertEqual(card['state']['to_play'], 'TO WIN')

    def test_a_point_in_another_group_moves_your_headline(self):
        self._sweep(self.groups[0], range(1, 7))       # your group banks one
        self.assertEqual(self._card('A')['number']['text'], '1–0')
        # You play nothing more. Group 2 wins its first six.
        self._sweep(self.groups[1], range(1, 7))
        self.assertEqual(self._card('A')['number']['text'], '2–0',
                         "group 2's point must reach group 1's lock screen")

    def test_every_group_reads_the_same_cup(self):
        self._sweep(self.groups[0], range(1, 13))      # group 1 banks two
        self._sweep(self.groups[1], range(1, 7))       # group 2 banks one
        self.assertEqual(self._card('A')['number']['text'], '3–0')
        self.assertEqual(self._card('E')['number']['text'], '3–0')

    def test_the_team_cup_payload_decodes_against_the_swift_contract(self):
        """The `closed` outage, guarded for this card: a key the Swift does
        not declare is ignored, but a REQUIRED key the payload lacks throws
        and iOS drops the whole update with no error anywhere. So both
        directions, on the payload the registry actually dispatches."""
        import pathlib
        swift = (pathlib.Path(__file__).resolve().parents[2] / 'mobile' / 'ios'
                 / 'SixesActivity' / 'SixesActivity.swift').read_text()
        self._sweep(self.groups[0], range(1, 7))
        self._sweep(self.groups[1], range(1, 7))
        card = self._card()
        for key in card:
            self.assertTrue(f'let {key}:' in swift or f'var {key}:' in swift,
                            f'`{key}` has no field in ContentState')
        for key in ('header', 'number', 'sides', 'state', 'pips', 'footer'):
            self.assertIn(key, card, f'required key `{key}` missing')


class TeamCupTests(_TeamCupBase):
    """The **team** configuration — same composition, a different view model.

    Seven rows of the packet's difference table, and the headline carries the
    rest: your Triple Cup is one match in a tournament cup, so the card is
    about the cup the moment there is a cup score to report. A point here is
    one twenty-fourth of the thing being decided.

    Nothing about the panel changes — same slot order, same type sizes, same
    one-row sides line. What changes is what each slot is ABOUT.
    """

    # -- the headline is the whole cup --------------------------------------

    def test_the_headline_is_the_cup_not_this_groups_four_points(self):
        """`6½–4½`, not `2–1`. Your Triple Cup is a way of earning one point
        in something larger, and the card stops being about the match the
        moment there is a cup score to report."""
        self._sweep(self.groups[0], range(1, 13))     # group 1 banks two
        self._sweep(self.groups[1], range(1, 7))      # group 2 banks one
        s = self._state(12)
        self.assertEqual(s['number']['text'], '3–0')

    def test_the_header_names_the_cup(self):
        self._sweep(self.groups[0], range(1, 7))
        self.assertIn('SHELDON CUP', self._state(6)['header']['game'])

    # -- the right-hand slot ------------------------------------------------

    def test_the_right_slot_is_points_to_win_never_the_match(self):
        """The headline now counts eight points and twelve other golfers; a
        `1 UP` beside it reads as a contradiction. Points-to-win is the figure
        a captain recites all afternoon."""
        self._sweep(self.groups[0], range(1, 7))
        st = self._state(6)['state']
        self.assertEqual(st['to_play'], 'TO WIN')
        self.assertEqual(st['word'], '4½')          # eight available
        self.assertNotIn('UP', st['word'])

    def test_a_clinched_cup_outranks_the_hole_you_are_standing_on(self):
        """The cup can be decided while your group is on the fourteenth, and
        when it is, it takes the slot — the same rule that gives the casual
        cup its CANNOT LOSE override."""
        self._sweep(self.groups[0], range(1, 19))    # all four to team 1
        self._sweep(self.groups[1], range(1, 13))    # two more: 6 of 8
        st = self._state(18)['state']
        self.assertEqual(st['word'], 'BLUE')
        self.assertEqual(st['to_play'], 'TAKES IT')
        self.assertEqual(st['colour'], 'mint')

    # -- the sides line -----------------------------------------------------

    def test_the_sides_line_is_your_own_match_as_a_cup_sub_total(self):
        """The headline has been taken by the cup, so your own match keeps the
        sides line — and reads as a share of the cup rather than as a match,
        which is why the qualifier is a cup score and not `2 up`."""
        self._sweep(self.groups[0], range(1, 7))
        sides = self._state(6)['sides']
        self.assertEqual(len(sides), 1)
        self.assertEqual(sides[0]['names'], 'Your Triple Cup')
        self.assertIn('–', sides[0]['note'])
        self.assertNotIn('up', sides[0]['note'])

    # -- the needle ---------------------------------------------------------

    def test_the_needle_replaces_the_cells_and_never_joins_them(self):
        """Four cells are the casual format; twenty-four of them across 320
        points would be decoration."""
        self._sweep(self.groups[0], range(1, 7))
        s = self._state(6)
        self.assertEqual(s['pips'], [])
        self.assertIsNotNone(s['needle'])

    def test_the_needle_is_a_share_of_points_available_not_points_scored(self):
        """Normalised to points played the grey band vanishes at the turn and
        the centre tick stops meaning half the cup — which is the only thing
        on the card that answers *is it gone*."""
        self._sweep(self.groups[0], range(1, 7))     # one of eight, to team 1
        needle = self._state(6)['needle']
        self.assertAlmostEqual(needle['blue'], 1 / 8)
        self.assertAlmostEqual(needle['orange'], 0.0)
        self.assertLess(sum(needle.values()), 1.0,
                        'the grey band is what is still out')

    # -- the footer ---------------------------------------------------------

    def test_the_footer_counts_groups_rather_than_money(self):
        """Cup money settles in the team room, not on a lock screen."""
        self._sweep(self.groups[0], range(1, 7))
        foot = self._state(6)['footer']
        self.assertEqual(foot['context'], '2 groups still out')
        self.assertEqual(foot['money'], '')

    def test_a_group_is_counted_once_however_many_points_it_owes(self):
        """Two Singles still on the course are one group still out."""
        self._sweep(self.groups[0], range(1, 19))
        self._sweep(self.groups[1], range(1, 7))
        self.assertEqual(self._state(18)['footer']['context'],
                         '1 group still out')

    # -- the palette --------------------------------------------------------

    def test_the_sides_wear_the_colours_the_cup_declared(self):
        """A blue headline over a slot reading `ORANGE TAKES IT` is the
        fourball's hardcoded-blue defect arriving by another route."""
        from services.live_activity_triple_cup import _cup_palette
        self.assertEqual(_cup_palette({'team1_colour': 'Orange',
                                       'team2_colour': 'Blue'}),
                         ('orange', 'blue'))

    def test_a_colour_the_widget_cannot_draw_falls_back_to_position(self):
        """A Red/Green cup, or one where both sides picked blue: position at
        least keeps the two halves of the needle distinguishable."""
        from services.live_activity_triple_cup import _cup_palette
        for pair in ({'team1_colour': 'Red', 'team2_colour': 'Green'},
                     {'team1_colour': 'Blue', 'team2_colour': 'Blue'},
                     {}):
            self.assertEqual(_cup_palette(pair), ('blue', 'orange'), pair)

    def test_red_wears_orange_so_the_default_cup_is_not_inverted(self):
        """Red v. Blue is the app's own default cup. Before the alias it fell
        back on position — Red's points in blue, the Blue team in orange —
        which is the inversion this whole palette exists to prevent."""
        from services.live_activity_triple_cup import _cup_palette
        self.assertEqual(_cup_palette({'team1_colour': 'Red',
                                       'team2_colour': 'Blue'}),
                         ('orange', 'blue'))
        self.assertEqual(_cup_palette({'team1_colour': 'Blue',
                                       'team2_colour': 'Red'}),
                         ('blue', 'orange'))

    def test_red_against_orange_is_a_collision_not_a_match(self):
        """Both would wear orange, so neither can have its own colour —
        position keeps the two halves apart."""
        from services.live_activity_triple_cup import _cup_palette
        self.assertEqual(_cup_palette({'team1_colour': 'Red',
                                       'team2_colour': 'Orange'}),
                         ('blue', 'orange'))

    def test_a_red_v_blue_cup_draws_each_team_in_its_own_half(self):
        """Through the real card: Red leads, so the headline is orange and
        Red's share of the needle sits under `orange`, with the Blue team's
        under `blue`. Both required needle keys stay present, which is what
        keeps this decodable on every installed build."""
        self.t1.name, self.t1.colour = 'Red', 'Red'
        self.t1.save(update_fields=['name', 'colour'])
        self.t2.name, self.t2.colour = 'Blue', 'Blue'
        self.t2.save(update_fields=['name', 'colour'])
        self._sweep(self.groups[0], range(1, 7))     # one point, to Red
        s = self._state(6)
        self.assertEqual(s['number']['colour'], 'orange')
        self.assertAlmostEqual(s['needle']['orange'], 1 / 8)
        self.assertAlmostEqual(s['needle']['blue'], 0.0)
        self.assertEqual(set(s['needle']), {'blue', 'orange'})

    # -- and the casual card is untouched -----------------------------------

    def test_a_round_with_no_cup_config_still_gets_the_casual_card(self):
        """A tournament round is not automatically a cup round, and the
        configuration follows the cup rather than a flag."""
        from tournament.models import RyderCupRoundConfig
        RyderCupRoundConfig.objects.filter(pk=self.rc.pk).delete()
        self.round.refresh_from_db()
        self._sweep(self.groups[0], range(1, 7))
        s = self._state(6)
        self.assertIsNone(s.get('needle'))
        self.assertEqual(len(s['pips']), 4)
        self.assertEqual(s['header']['game'], 'TRIPLE CUP')


class CupPushTests(_TeamCupBase):
    """**Exactly two events fire**, and the rest of the cup stays silent.

    A six-group cup has twenty-four points. A push per point is twenty-four
    pushes, at which point the golfer turns the activity off and loses the
    nineteen that were worth having. Every other settled point is already on
    the card, a glance away — the activity does not also flash.
    """

    def _alert(self):
        from services.live_activity_cup_push import cup_alert
        return cup_alert(self.round)

    def test_the_first_score_of_a_cup_is_not_a_lead_change(self):
        """Somebody has to be ahead of somebody first."""
        self._sweep(self.groups[0], range(1, 7))
        self.assertIsNone(self._alert())

    def test_taking_the_lead_fires_once_and_carries_the_score(self):
        self._sweep(self.groups[0], range(1, 7))
        self._alert()                                  # establish the marker
        self._sweep(self.groups[1], range(1, 7), winner='team2')
        alert = self._alert()
        self.assertIsNotNone(alert)
        self.assertIn('–', alert['title'])

    def test_extending_a_lead_fires_nothing(self):
        """The point is already on the card. This is the case that would have
        been twenty-four pushes."""
        self._sweep(self.groups[0], range(1, 7))
        self._alert()
        self._sweep(self.groups[0], range(7, 13))       # same side, 2–0
        self.assertIsNone(self._alert())

    def test_going_level_is_a_lead_change(self):
        """**Level is a state, not a missing one.** Who is ahead has changed
        — from somebody to nobody — and that is the fact the push reports."""
        self._sweep(self.groups[0], range(1, 7))        # 1–0
        self._alert()
        self._sweep(self.groups[1], range(1, 7), winner='team2')   # 1–1
        alert = self._alert()
        self.assertIn('All square', alert['title'])

    def test_a_second_point_that_keeps_it_level_does_not(self):
        self._sweep(self.groups[0], range(1, 7))
        self._alert()
        self._sweep(self.groups[1], range(1, 7), winner='team2')   # 1–1
        self._alert()
        self._sweep(self.groups[0], range(7, 13))                  # 2–1
        self._alert()
        self._sweep(self.groups[1], range(7, 13), winner='team2')  # 2–2
        self.assertIn('All square', self._alert()['title'])

    def test_the_clinch_fires_once_and_then_never_again(self):
        """The marker is what makes that true. Without it, every score posted
        after the clinch is another `Blue take the Sheldon Cup`."""
        self._sweep(self.groups[0], range(1, 7))
        self._alert()
        self._sweep(self.groups[0], range(7, 19))       # 4–0 of eight
        self._alert()
        self._sweep(self.groups[1], range(1, 13))       # 6–0: out of reach
        alert = self._alert()
        self.assertIn('take the Sheldon Cup', alert['title'])
        self.assertIn('out of reach', alert['body'])
        self._sweep(self.groups[1], range(13, 19))
        self.assertIsNone(self._alert(),
                          'the activity settles under it; it does not re-fire')

    def test_a_clinch_fires_one_push_not_two(self):
        """A clinch is by definition also a lead change. Two pushes for one
        half-point is the noise this design exists to avoid."""
        self._sweep(self.groups[0], range(1, 19))       # 4–0
        self._alert()
        self._sweep(self.groups[1], range(1, 13), winner='team2')  # 4–2
        self._alert()
        self._sweep(self.groups[1], range(13, 19), winner='team2')  # 4–4
        alert = self._alert()
        # Level AND all eight awarded — the halved cup, which is decided.
        self.assertIn('halved', alert['title'])

    def test_a_casual_round_is_silent(self):
        """The same reason Wolf, Points and Stableford are: four men in one
        group, and a push for the Fourball is a phone telling you what you
        watched."""
        from tournament.models import RyderCupRoundConfig
        RyderCupRoundConfig.objects.filter(pk=self.rc.pk).delete()
        self.round.refresh_from_db()
        self._sweep(self.groups[0], range(1, 7))
        self.assertIsNone(self._alert())

    def test_the_alert_reaches_the_apns_envelope(self):
        """A content-state update with no `alert` is silent by design, so the
        two that ring have to add one — this is the line that makes the
        difference between a board that moves and a phone that buzzes."""
        from services.live_activity_push import _apns_payload
        quiet = _apns_payload({'kind': 'triple_cup'})
        self.assertNotIn('alert', quiet['aps'])
        loud = _apns_payload({'kind': 'triple_cup'},
                             alert={'title': 'Blue take the lead — 5–4',
                                    'body': '2 groups still out'})
        self.assertEqual(loud['aps']['alert']['title'],
                         'Blue take the lead — 5–4')


class CasualFinalTests(_Base):
    """**The headline does not move.** It has been the cup score since the
    third tee and it is the cup score now — the one card in the set whose
    closing frame changes least, because the thing it reports is the thing
    that just finished. What changes is the right-hand slot.
    """

    def _final(self, who=None):
        from services.live_activity_triple_cup import triple_cup_final_state
        return triple_cup_final_state(
            self.fs, player_id=self.pid[who] if who else None)

    def _play_out(self, low='team1'):
        for h in range(1, 19):
            self._play(h, 3, 4, 5, 5) if low == 'team1' \
                else self._play(h, 5, 5, 3, 4)

    def test_the_headline_is_still_the_cup_score(self):
        self._play_out()
        s = self._final()
        self.assertIn('–', s['number']['text'])
        self.assertTrue(s['closed'])

    def test_the_segment_slot_becomes_the_verdict(self):
        self._play_out()
        self.assertIn(self._final()['header']['segment'],
                      ('CUP WON', 'CUP LOST', 'CUP HALVED'))

    def test_it_never_says_retained(self):
        """Retaining is a holder keeping a cup he already had, and nothing in
        the app knows who held it last."""
        self._play_out()
        self.assertNotIn('RETAINED', self._final()['header']['segment'])

    def test_the_state_slot_becomes_the_money(self):
        self._play_out()
        st = self._final()['state']
        self.assertEqual(st['to_play'], 'WINNERS TAKE ALL')
        self.assertEqual(st['colour'], 'mint')

    def test_all_four_cells_are_readable_at_the_end(self):
        """The segments won are readable off the strip, which is the strip
        earning its place one last time."""
        self._play_out()
        cells = self._final()['pips']
        self.assertEqual(len(cells), 4)
        self.assertNotIn('out', cells)

    def test_a_halved_cup_says_so_rather_than_printing_zero(self):
        """A zero in a money slot reads as a round played for nothing."""
        from services.live_activity_triple_cup import triple_cup_final_state
        # Every hole halved: nobody takes a point, nothing changes hands.
        for h in range(1, 19):
            self._play(h, 4, 4, 4, 4)
        s = triple_cup_final_state(self.fs)
        self.assertNotIn('$0', s['state']['word'])
        self.assertIn('nothing changes hands', s['sides'][0]['names'])


class TeamFinalTests(_TeamCupBase):
    """The team cup signs off on the CUP's verdict, not the group's.

    Your four points are one twenty-fourth of it and the card has said so all
    afternoon; it does not change its mind at the last.
    """

    def _final(self, who='A'):
        from services.live_activity_triple_cup import triple_cup_final_state
        return triple_cup_final_state(self.fs,
                                      player_id=self.m[who].player_id)

    def test_the_headline_is_the_cup_not_the_group(self):
        self._sweep(self.groups[0], range(1, 19))     # 4–0 of eight
        self._sweep(self.groups[1], range(1, 13))     # 6–0: decided
        s = self._final()
        self.assertEqual(s['number']['text'], '6–0')
        self.assertEqual(s['state']['word'], 'BLUE')
        self.assertEqual(s['state']['to_play'], 'TAKES IT')

    def test_it_keeps_the_needle_rather_than_the_cells(self):
        self._sweep(self.groups[0], range(1, 19))
        self._sweep(self.groups[1], range(1, 13))
        s = self._final()
        self.assertEqual(s['pips'], [])
        self.assertIsNotNone(s['needle'])

    def test_the_sides_line_reports_your_own_match_as_a_result(self):
        self._sweep(self.groups[0], range(1, 19))
        self._sweep(self.groups[1], range(1, 13))
        note = self._final()['sides'][0]['note']
        self.assertTrue(note.startswith(('· won', '· lost', '· halved')), note)

    def test_the_verdict_is_written_from_the_readers_side(self):
        """A card that told half the group the wrong thing is the defect this
        whole set keeps finding."""
        self._sweep(self.groups[0], range(1, 19))
        self._sweep(self.groups[1], range(1, 13))
        self.assertEqual(self._final('A')['header']['segment'], 'CUP WON')
        self.assertEqual(self._final('C')['header']['segment'], 'CUP LOST')

    def test_winning_your_group_on_a_halved_cup_is_not_cup_won(self):
        """The verdict is the cup's. Group 1 goes 4–0 to team 1 and group 2
        goes 4–0 the other way: the cup is 4–4, and a card that said CUP WON
        above HALVED · CUP SHARED would contradict itself in the frame that
        gets screenshotted."""
        self._sweep(self.groups[0], range(1, 19))
        self._sweep(self.groups[1], range(1, 19), winner='team2')
        s = self._final('A')
        self.assertEqual(s['number']['text'], '4–4')
        self.assertEqual(s['state']['word'], 'HALVED')
        self.assertEqual(s['header']['segment'], 'CUP HALVED')

    def test_a_cup_with_rounds_left_is_not_called_halved(self):
        """Finishing round 1 of 2 at 5–3 is a lead, not a shared cup. The
        undecided case used to fall into the HALVED branch."""
        from unittest import mock
        self._sweep(self.groups[0], range(1, 19))
        undecided = {'team1_points': 5, 'team2_points': 3,
                     'total_possible': 16, 'to_win': 8.5,
                     'cup_status': 'in_progress', 'winner_team': None,
                     'team1_name': 'Red', 'team2_name': 'Blue',
                     'team1_colour': 'Red', 'team2_colour': 'Blue'}
        with mock.patch('services.live_activity_triple_cup._cup_standings',
                        return_value=undecided):
            s = self._final('A')
        self.assertEqual(s['header']['segment'], 'ROUND COMPLETE')
        self.assertEqual(s['state']['to_play'], 'TO WIN')
        self.assertEqual(s['state']['word'], '8½')
        self.assertNotEqual(s['state']['word'], 'HALVED')
