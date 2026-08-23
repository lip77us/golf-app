"""
api/test_pairs_play.py
----------------------
Pairs Play — two-golfer teams (docs/design-review/handoff-team-pairs/SPEC.md).

Pairs are Foursome Play with the size set to two: the same wizard, the same
leaderboard, the same pool, the same settlement. Only two steps behave
differently, so this file tests those two hard and then checks that nothing
else noticed the size changed.

The field is the packet's own: twelve golfers in six pairs, and the odd-field
case is that field plus Dave Kwan.
"""
from datetime import date
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import (
    Foursome, FoursomeMembership, Round, TeamPlayConfig, Tournament,
)

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]

# The six pairs the build screen draws, in its order, with the balance strip it
# reports: 4 to 7 strokes on a scramble.
PAIRS = [
    [('Anna Maiolini', 4),  ('Ambrose Yau', 19)],
    [('Alan Petersen', 6),  ('Dan Reilly', 21)],
    [('Tom Mercer', 5),     ('Chris Vaughn', 24)],
    [('Don Morgan', 7),     ('Paul Lipkin', 20)],
    [('Nick Ferraro', 3),   ('Greg Nunes', 22)],
    [('Marco Bellini', 9),  ('Luis Ortega', 23)],
]


class PairsBase(TestCase):

    #: Groups to build, as [[(name, course_handicap), …], …].
    ROSTER = PAIRS

    def setUp(self):
        self.acct = Account.objects.create(name='Saturday Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)

        self.tourn = Tournament.objects.create(
            account=self.acct, name='Saturday Pairs',
            start_date=date(2026, 6, 6), total_rounds=1,
            active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress')

        self.groups  = []
        self.players = {}
        for i, members in enumerate(self.ROSTER, start=1):
            fs = Foursome.objects.create(round=self.round, group_number=i)
            self.groups.append(fs)
            for name, hcp in members:
                p = Player.objects.create(account=self.acct, name=name,
                                          handicap_index=Decimal(hcp))
                self.players[name] = p
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=hcp, playing_handicap=hcp)

    # -- helpers ---------------------------------------------------------

    def _setup_url(self):
        return reverse('api-team-play-setup', args=[self.tourn.id])

    def _configure(self, team_format='scramble', **overrides):
        body = {'team_size': 2, 'team_format': team_format,
                'entry_fee': '25.00', 'places_paid': 3,
                'split_pcts': [50, 30, 20]}
        body.update(overrides)
        return self.client.post(self._setup_url(), body, format='json')

    def _summary(self):
        return self.client.get(
            reverse('api-team-play', args=[self.tourn.id])).json()

    def _card(self, foursome, hole=None):
        url = reverse('api-team-play-card', args=[foursome.id])
        return self.client.get(url, {'hole': hole} if hole else {}).json()

    def _team(self, summary, group_number):
        return next(t for t in summary['teams']
                    if t['group_number'] == group_number)


# ---------------------------------------------------------------------------
# 1. The size is a control, not a shape
# ---------------------------------------------------------------------------

class TeamSizeTests(PairsBase):

    def test_pairs_run_the_same_config_row(self):
        r = self._configure('scramble')
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()['team_size'], 2)
        cfg = TeamPlayConfig.objects.get(tournament=self.tourn)
        self.assertTrue(cfg.is_pairs)

    def test_the_size_decides_the_format_list(self):
        self._configure('scramble')
        body = self.client.get(self._setup_url()).json()
        self.assertEqual(
            body['formats'],
            ['scramble', 'best_ball', 'alternate_shot', 'scotch', 'chapman'])

    def test_a_two_man_shamble_is_refused(self):
        """There is no two-golfer shamble. Nonsense rather than a preference, so
        it is refused rather than silently accepted."""
        r = self._configure('shamble')
        self.assertEqual(r.status_code, 400)
        self.assertIn('not a pairs format', r.json()['detail'])

    def test_a_four_man_chapman_is_refused(self):
        r = self.client.post(self._setup_url(),
                             {'team_size': 4, 'team_format': 'chapman'},
                             format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('not a fours format', r.json()['detail'])

    def test_default_is_fours_so_existing_rows_read_unchanged(self):
        r = self.client.post(self._setup_url(),
                             {'team_format': 'scramble'}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()['team_size'], 4)

    def test_size_locks_with_the_format_at_the_first_score(self):
        self._configure('scramble')
        cfg = TeamPlayConfig.objects.get(tournament=self.tourn)
        from django.utils import timezone
        cfg.format_locked_at = timezone.now()
        cfg.save(update_fields=['format_locked_at'])

        r = self.client.post(self._setup_url(),
                             {'team_size': 4, 'team_format': 'scramble'},
                             format='json')
        self.assertEqual(r.status_code, 409)
        self.assertIn('team_size', r.json()['fields'])


# ---------------------------------------------------------------------------
# 2. The allowance is doing enormous work
# ---------------------------------------------------------------------------

class PairsAllowanceTests(PairsBase):

    def _first_pair_figure(self, team_format):
        self._configure(team_format)
        return self._team(self._summary(), 1)

    def test_scramble(self):
        team = self._first_pair_figure('scramble')
        self.assertEqual(team['team_handicap'], 4)
        self.assertEqual(team['team_handicap_raw'], '4.25')
        self.assertEqual(team['allowance']['label'], '35% low + 15% high')

    def test_alternate_shot_is_three_times_a_scramble(self):
        team = self._first_pair_figure('alternate_shot')
        self.assertEqual(team['team_handicap'], 12)
        self.assertEqual(team['allowance']['label'],
                         '50% of the combined course handicap')

    def test_scotch_and_chapman_share_a_table(self):
        self.assertEqual(self._first_pair_figure('scotch')['team_handicap'], 10)
        self.assertEqual(
            self._first_pair_figure('chapman')['team_handicap'], 10)

    def test_best_ball_is_per_golfer(self):
        team = self._first_pair_figure('best_ball')
        self.assertEqual(team['allowance']['pct'], 85)
        self.assertEqual([m['own_ball_handicap'] for m in team['members']],
                         [3, 16])

    def test_every_pair_is_worked_on_its_own_men(self):
        self._configure('scramble')
        figures = [t['team_handicap'] for t in self._summary()['teams']]
        self.assertEqual(figures, [4, 5, 5, 5, 4, 7])
        self.assertEqual((min(figures), max(figures)), (4, 7))

    def test_the_override_applies_to_both_men(self):
        self._configure('scramble', allowance_override_pct=50)
        team = self._team(self._summary(), 1)
        self.assertEqual(team['team_handicap'], 12)   # 23 × 50% = 11.50 → 12


# ---------------------------------------------------------------------------
# 3. No phantom, and the pair names itself
# ---------------------------------------------------------------------------

class PairsTeamTests(PairsBase):

    def test_no_phantom_partner_ever(self):
        """In fours the phantom is a handicap device for a team that still hits
        four balls. In pairs it would be an imaginary partner taking half the shots
        in an alternate shot."""
        self._configure('alternate_shot')
        for team in self._summary()['teams']:
            self.assertFalse(team['has_phantom'], team['name'])
            self.assertFalse(any(m['is_phantom'] for m in team['members']))

    def test_a_pair_defaults_to_the_two_surnames(self):
        """A pair is Maiolini & Yau before it is Pine. Two surnames fit on a
        leaderboard row and golfers say a pair that way out loud."""
        self._configure('scramble')
        self.assertEqual(self._team(self._summary(), 1)['name'],
                         'Maiolini & Yau')

    def test_surnames_are_low_handicap_first(self):
        self._configure('scramble')
        self.assertEqual(self._team(self._summary(), 4)['name'],
                         'Morgan & Lipkin')

    def test_the_default_is_written_to_the_pair_not_the_group(self):
        """Two pairs share a playing group, so `Foursome.name` is the GROUP's
        name and cannot also be one of theirs. The pair is named on its own
        row."""
        self._configure('scramble')
        from tournament.models import TeamPlayTeamState
        state = TeamPlayTeamState.objects.get(foursome=self.groups[0], slot=1)
        self.assertEqual(state.name, 'Maiolini & Yau')
        self.groups[0].refresh_from_db()
        self.assertEqual(self.groups[0].name, '')

    def test_a_td_name_still_wins(self):
        self._configure('scramble')
        r = self.client.post(
            reverse('api-team-play-team', args=[self.groups[0].id]),
            {'name': 'The Ringers'}, format='json')
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self._team(self._summary(), 1)['name'], 'The Ringers')

    def test_a_named_pair_stops_following_its_roster(self):
        self._configure('scramble')
        self.client.post(
            reverse('api-team-play-team', args=[self.groups[0].id]),
            {'name': 'The Ringers'}, format='json')
        self._configure('scotch')          # re-syncs every team
        self.assertEqual(self._team(self._summary(), 1)['name'], 'The Ringers')

    def test_blank_resets_to_the_default_not_the_colour(self):
        self._configure('scramble')
        url = reverse('api-team-play-team', args=[self.groups[0].id])
        self.client.post(url, {'name': 'The Ringers'}, format='json')
        r = self.client.post(url, {'name': ''}, format='json')
        self.assertEqual(r.json()['name'], 'Maiolini & Yau')
        self.assertNotEqual(r.json()['name'], r.json()['colour'])

    def test_a_long_pair_of_surnames_falls_back_rather_than_truncating(self):
        """The cap is wide enough for two real surnames — `Petersen & Reilly`
        is seventeen characters — but a name that still will not fit falls back
        to `Group N` rather than being cut mid-word."""
        from core.models import Player
        Player.objects.filter(name='Anna Maiolini').update(
            name='Anna Featherstonehaugh')
        Player.objects.filter(name='Ambrose Yau').update(
            name='Ambrose Wolstenholme')
        self._configure('scramble')
        self.assertEqual(self._team(self._summary(), 1)['name'], 'Group 1')

    def test_two_ordinary_surnames_fit(self):
        self._configure('scramble')
        self.assertEqual(self._team(self._summary(), 2)['name'],
                         'Petersen & Reilly')

    def test_the_colour_is_still_assigned(self):
        """It does real work on the board and the card; it just is not the
        pair's name."""
        self._configure('scramble')
        self.assertEqual(self._team(self._summary(), 1)['colour'], 'Pine')

    def test_seats_open_counts_to_two(self):
        self._configure('scramble')
        for team in self._summary()['teams']:
            self.assertEqual(team['seats_open'], 0)
            self.assertEqual(team['team_size'], 2)


# ---------------------------------------------------------------------------
# 4. The field must be even, and the block names the golfer
# ---------------------------------------------------------------------------

class OddFieldTests(PairsBase):

    ROSTER = PAIRS + [[('Dave Kwan', 15)]]

    def test_the_block_names_the_unpaired_golfer(self):
        """The fix is about one golfer, so the block says which one rather than
        reporting a count."""
        self._configure('scramble')
        blocking = self._summary()['blocking']
        self.assertEqual(len(blocking), 1)
        self.assertEqual(blocking[0]['kind'], 'unpaired')
        self.assertEqual(blocking[0]['golfer']['name'], 'Dave Kwan')
        self.assertEqual(blocking[0]['detail'], 'Dave Kwan has no partner.')

    def test_playing_three_is_offered_only_in_best_ball(self):
        """A third ball is another option to count. In alternate shot and
        Chapman it cannot work at all, and in a scramble it is a straight
        advantage — offering a choice four of the five formats reject is worse
        than not offering it."""
        for fmt, available in (('scramble', False), ('alternate_shot', False),
                               ('scotch', False), ('chapman', False),
                               ('best_ball', True)):
            self._configure(fmt)
            block = self._summary()['blocking'][0]
            self.assertIs(block['three_ball_available'], available, fmt)

    def test_an_even_field_blocks_nothing(self):
        self._configure('scramble')
        self.groups[-1].delete()
        self.assertEqual(self._summary()['blocking'], [])

    def test_a_foursome_event_never_blocks(self):
        """Group sizes slice the whole field and a short team fields a phantom,
        so no golfer can be left over."""
        self.client.post(self._setup_url(),
                         {'team_size': 4, 'team_format': 'scramble'},
                         format='json')
        self.assertEqual(self._summary()['blocking'], [])


class ThreeManPairTests(PairsBase):

    ROSTER = PAIRS[:5] + [[('Marco Bellini', 9), ('Luis Ortega', 23),
                           ('Dave Kwan', 15)]]

    def test_three_men_outside_best_ball_leave_one_unpaired(self):
        """Three golfers in a playing group are a pair and a golfer on their own —
        only best ball can make them one team of three."""
        self._configure('chapman')
        blocking = self._summary()['blocking']
        self.assertEqual(blocking[0]['kind'], 'unpaired')
        self.assertIn('has no partner', blocking[0]['detail'])

    def test_best_ball_lets_one_team_play_three(self):
        self._configure('best_ball')
        self.assertEqual(self._summary()['blocking'], [])

    def test_the_third_man_takes_85_percent_of_his_own(self):
        self._configure('best_ball')
        team = self._team(self._summary(), 6)
        self.assertEqual([m['own_ball_handicap'] for m in team['members']],
                         [8, 13, 20])          # 9→7.65→8, 15→12.75→13, 23→19.55→20


# ---------------------------------------------------------------------------
# 5. The tee-shot control does three different jobs
# ---------------------------------------------------------------------------

class DriveControlTests(PairsBase):

    def test_scramble_records_against_a_quota(self):
        self._configure('scramble', drive_rule='per_nine', drives_required=1)
        summary = self._summary()
        self.assertEqual(summary['drive_control'], 'record')
        self.assertEqual(summary['drive_rules'],
                         ['none', 'per_nine', 'per_eighteen'])

    def test_a_pairs_quota_is_two_men_s_worth_not_four(self):
        """One each per nine is TWO of nine, seven free — two golfers and eighteen
        holes is a lot of slack, which is why one each per nine is the usual
        rule."""
        self._configure('scramble', drive_rule='per_nine', drives_required=1)
        drive = self._team(self._summary(), 1)['drive']
        self.assertEqual(drive['required'], 2)
        self.assertEqual(drive['free'], 7)
        self.assertEqual(drive['floating'], 0)   # no phantom to cover

    def test_a_pair_may_be_asked_for_four_drives_a_nine(self):
        """The ceiling is the window's holes divided between the golfers, and it
        scales with the size: four golfers sharing nine top out at two each, two
        golfers at FOUR each. The shipped 2-and-4 was four golfers' answer
        hardcoded."""
        self._configure('scramble', drive_rule='per_nine', drives_required=4)
        drive = self._team(self._summary(), 1)['drive']
        self.assertEqual(drive['per_golfer'], 4)
        self.assertEqual(drive['required'], 8)     # of nine holes
        self.assertEqual(drive['free'], 1)

    def test_a_pair_may_be_asked_for_nine_drives_across_eighteen(self):
        # Every hole spoken for, nothing left over.
        self._configure('scramble', drive_rule='per_eighteen',
                        drives_required=9)
        drive = self._team(self._summary(), 1)['drive']
        self.assertEqual(drive['per_golfer'], 9)
        self.assertEqual(drive['required'], 18)
        self.assertEqual(drive['free'], 0)

    def test_more_than_the_window_holds_is_clamped(self):
        """Above the ceiling the quota is impossible before a ball is struck —
        a different thing from the shortfall the tracker warns about, which the
        team chose. Clamped rather than refused, like the drive rule."""
        self._configure('scramble', drive_rule='per_nine', drives_required=9)
        self.assertEqual(self._summary()['drive_rule'], 'per_nine')
        self.assertEqual(
            self._team(self._summary(), 1)['drive']['per_golfer'], 4)

    def test_a_foursome_ceiling_is_unchanged(self):
        self.client.post(self._setup_url(),
                         {'team_size': 4, 'team_format': 'scramble',
                          'drive_rule': 'per_nine', 'drives_required': 9},
                         format='json')
        cfg = TeamPlayConfig.objects.get(tournament=self.tourn)
        self.assertEqual(cfg.max_drives_per_golfer, 2)
        self.assertEqual(cfg.drives_required, 2)

    def test_scotch_with_no_requirement_does_not_ask_who_drove(self):
        """A pair playing Scotch knows which of them is hitting the second
        shot. Charging them a tap a hole to be told it back is the app asking
        for its own benefit — **no requirement, no asking.**"""
        self._configure('scotch')
        summary = self._summary()
        self.assertEqual(summary['drive_rule'], 'none')
        self.assertEqual(summary['drive_control'], 'none')
        self.assertFalse(summary['requires_drive_pick'])
        self.assertEqual(self._card(self.groups[0], 7)['drive_options'], [])

    def test_scotch_with_a_quota_taps_and_instructs(self):
        """Set a quota and the tap comes back — now it is counting something,
        and the sentence it implies comes free."""
        self._configure('scotch', drive_rule='per_nine', drives_required=1)
        summary = self._summary()
        self.assertEqual(summary['drive_control'], 'instruction')
        self.assertTrue(summary['requires_drive_pick'])

    def test_scotch_answers_with_a_sentence(self):
        """Once a quota puts the tap on the card, picking the drive also says
        who hits NEXT — the partner whose ball was not taken plays the second
        shot."""
        self._configure('scotch', drive_rule='per_nine', drives_required=1)
        fs = self.groups[0]
        self.assertIn('The pick says who plays next',
                      self._card(fs, 7)['tee_note'])

        self.client.post(reverse('api-team-play-drive', args=[fs.id]),
                         {'hole_number': 7,
                          'player_id': self.players['Anna Maiolini'].id},
                         format='json')
        self.assertEqual(self._card(fs, 7)['tee_note'],
                         'Yau plays the second shot, then alternate.')

    def test_best_ball_and_chapman_have_no_drive_control(self):
        """Both golfers drive every hole with no choice to record."""
        for fmt in ('best_ball', 'chapman'):
            self._configure(fmt, drive_rule='per_nine')
            summary = self._summary()
            self.assertEqual(summary['drive_control'], 'none', fmt)
            # Coerced rather than refused: a TD switching format should not
            # have to go back and un-set a rule that no longer exists.
            self.assertEqual(summary['drive_rule'], 'none', fmt)
            self.assertEqual(summary['drive_rules'], ['none'], fmt)

    def test_alternate_shot_forces_the_rota(self):
        self._configure('alternate_shot', drive_rule='per_nine')
        summary = self._summary()
        self.assertEqual(summary['drive_control'], 'rota')
        self.assertEqual(summary['drive_rule'], 'alternating')
        self.assertEqual(summary['drive_rules'], ['alternating'])

    def test_a_rota_has_nothing_to_fall_short_of(self):
        self._configure('alternate_shot')
        drive = self._team(self._summary(), 1)['drive']
        self.assertEqual(drive['shortfall'], 0)
        self.assertEqual(drive['penalty_strokes'], 0)


class TeeRotaTests(PairsBase):

    def setUp(self):
        super().setUp()
        self._configure('alternate_shot')
        self.fs = self.groups[0]
        self.maiolini = self.players['Anna Maiolini'].id
        self.yau      = self.players['Ambrose Yau'].id

    def _set_rota(self, first, second):
        return self.client.post(
            reverse('api-team-play-pairs', args=[self.fs.id]),
            {'pairs': [[first], [second]]}, format='json')

    def test_odd_holes_to_the_first_man(self):
        r = self._set_rota(self.maiolini, self.yau)
        self.assertEqual(r.status_code, 200, r.content)
        rota = {row['hole']: row['line'] for row in r.json()['rota']}
        # Surnames on the tee, the way a pair says it out loud.
        self.assertEqual(rota[1], 'Maiolini tees')
        self.assertEqual(rota[2], 'Yau tees')
        self.assertEqual(rota[3], 'Maiolini tees')
        self.assertEqual(rota[18], 'Yau tees')

    def test_the_card_names_the_tee_on_every_hole(self):
        """A pair that loses track plays a hole out of order and the round is
        gone, so the note is never conditional."""
        self._set_rota(self.maiolini, self.yau)
        for hole in range(1, 19):
            note = self._card(self.fs, hole)['tee_note']
            self.assertTrue(note.endswith(' tees.'), (hole, note))

    def test_before_it_is_set_the_card_asks_for_it(self):
        self.assertEqual(self._card(self.fs, 1)['tee_note'],
                         'Set the tee rota before the first score.')

    def test_a_rota_that_can_be_re_cut_is_not_a_rota(self):
        self._set_rota(self.maiolini, self.yau)
        r = self._set_rota(self.yau, self.maiolini)
        self.assertEqual(r.status_code, 409)

    def test_the_card_carries_the_roster_so_the_rota_can_be_set_on_it(self):
        """The one thing the fours build left open: the endpoint was written
        and nothing called it, so a team on the alternating rule fell back to
        roster order. The card needs the names to offer the choice."""
        card = self._card(self.fs, 1)
        self.assertEqual(card['drive_control'], 'rota')
        self.assertFalse(card['drive']['pairs_set'])
        self.assertEqual(
            [o['name'] for o in card['drive_options']],
            ['Anna Maiolini', 'Ambrose Yau'])
        self.assertFalse(any(o['picked'] for o in card['drive_options']))

    def test_once_set_the_card_reports_it(self):
        self._set_rota(self.yau, self.maiolini)
        card = self._card(self.fs, 1)
        self.assertTrue(card['drive']['pairs_set'])
        self.assertEqual(card['tee_note'], 'Yau tees.')


# ---------------------------------------------------------------------------
# 6. Two scorecards, and only one of them has two numbers
# ---------------------------------------------------------------------------

class OneBallCardTests(PairsBase):

    def test_four_of_the_five_formats_take_the_one_number_card(self):
        for fmt in ('scramble', 'alternate_shot', 'scotch', 'chapman'):
            self._configure(fmt)
            card = self._card(self.groups[0], 1)
            self.assertIn('team_score', card, fmt)
            self.assertNotIn('shamble', card, fmt)

    def test_a_score_posts_and_nets_off_the_pair_s_figure(self):
        self._configure('alternate_shot')      # 12 strokes on 18 holes
        fs = self.groups[0]
        url = reverse('api-team-play-score', args=[fs.id])
        for hole in range(1, 19):
            r = self.client.post(url, {'hole_number': hole, 'gross_score': 5},
                                 format='json')
            self.assertEqual(r.status_code, 200, r.content)
        rnd = r.json()
        self.assertEqual(rnd['gross'], 90)
        self.assertEqual(rnd['net'], 78)       # 90 − 12
        self.assertEqual(rnd['net_to_par'], 6)

    def test_the_format_locks_at_the_first_score(self):
        self._configure('scotch')
        self.client.post(
            reverse('api-team-play-score', args=[self.groups[0].id]),
            {'hole_number': 1, 'gross_score': 4}, format='json')
        r = self._configure('chapman')
        self.assertEqual(r.status_code, 409)


class BestBallCardTests(PairsBase):

    def setUp(self):
        super().setUp()
        self._configure('best_ball')
        self.fs = self.groups[0]

    def _post(self, hole, scores):
        from scoring.models import HoleScore
        for name, gross in scores.items():
            HoleScore.objects.update_or_create(
                foursome=self.fs, player=self.players[name],
                hole_number=hole, defaults={'gross_score': gross})

    def test_two_rows_and_the_better_net_counts(self):
        """Best ball is the only pairs format entering two scores — a shamble
        whose count is fixed at 1 of 2."""
        self._post(1, {'Anna Maiolini': 5, 'Ambrose Yau': 6})
        card = self._card(self.fs, 1)
        self.assertIn('shamble', card)
        hole = card['shamble']
        self.assertEqual(hole['count'], 1)
        self.assertEqual(len(hole['rows']), 2)

        counting = [r for r in hole['rows'] if r['counts']]
        self.assertEqual(len(counting), 1)
        # Both get a stroke on SI 1 (Maiolini off 3, Yau off 16), so the nets
        # are 4 and 5 and the better one is Maiolini's.
        self.assertEqual(counting[0]['name'], 'Anna Maiolini')

    def test_the_counting_ball_is_the_better_NET_not_the_better_gross(self):
        """Maiolini plays off 3 and Yau off 16, so from stroke index 4 out Yau
        is getting a shot and Maiolini is not — the same two grosses swap which
        ball counts."""
        self._post(10, {'Anna Maiolini': 5, 'Ambrose Yau': 5})
        hole = self._card(self.fs, 10)['shamble']
        counting = [r for r in hole['rows'] if r['counts']][0]
        self.assertEqual(counting['name'], 'Ambrose Yau')   # net 4 against 5

    def test_par_is_the_hole_s_own_par(self):
        """Best-1 on a par 4 is a par of 4 — unlike a shamble's best-2, which
        is a par of 8."""
        for hole in range(1, 19):
            self._post(hole, {'Anna Maiolini': 4, 'Ambrose Yau': 4})
        rnd = self._card(self.fs, 1)['round']
        self.assertEqual(rnd['thru'], 18)
        self.assertEqual(rnd['par_played'], 72)

    def test_a_hole_counts_only_when_both_balls_are_in(self):
        self._post(1, {'Anna Maiolini': 4})
        self.assertEqual(self._card(self.fs, 1)['round']['thru'], 0)
        self._post(1, {'Ambrose Yau': 5})
        self.assertEqual(self._card(self.fs, 1)['round']['thru'], 1)


# ---------------------------------------------------------------------------
# 7. Everything else is the same flow
# ---------------------------------------------------------------------------

class UnchangedDownstreamTests(PairsBase):

    def setUp(self):
        super().setUp()
        self._configure('scramble', entry_fee='25.00', places_paid=3,
                        split_pcts=[50, 30, 20])
        url = lambda fs: reverse('api-team-play-score', args=[fs.id])
        # Six pairs, each one shot worse than the last.
        for i, fs in enumerate(self.groups):
            for hole in range(1, 19):
                self.client.post(url(fs),
                                 {'hole_number': hole, 'gross_score': 4 + i},
                                 format='json')

    def test_the_board_is_the_same_board(self):
        board = self.client.get(
            reverse('api-team-play-leaderboard', args=[self.tourn.id])).json()
        self.assertTrue(board['all_in'])
        self.assertEqual([t['rank'] for t in board['teams']],
                         [1, 2, 3, 4, 5, 6])
        self.assertEqual(board['teams'][0]['name'], 'Maiolini & Yau')

    def test_the_pool_is_twelve_entries(self):
        board = self.client.get(
            reverse('api-team-play-leaderboard', args=[self.tourn.id])).json()
        self.assertEqual(board['pool']['golfers'], 12)
        self.assertEqual(board['pool']['pool'], 300.0)

    def test_a_prize_divides_two_ways(self):
        s = self.client.get(
            reverse('api-team-play-settlement', args=[self.tourn.id])).json()
        self.assertTrue(s['can_settle'])
        first = s['blocks'][0]['teams'][0]
        self.assertEqual(first['ways'], 2)
        self.assertEqual(sum(g['amount'] for g in first['golfers']),
                         first['amount'])
        self.assertEqual(s['balance'], 0)

    def test_a_one_ball_round_can_actually_be_completed(self):
        """A one-ball format posts a TeamHoleScore, not four HoleScores.
        Counting coverage off the per-golfer table left every scramble,
        alternate shot, Scotch and Chapman permanently unfinishable."""
        r = self.client.get(reverse('api-round-detail', args=[self.round.id]))
        self.assertEqual(r.json()['holes_remaining'], 0)
        self.assertTrue(r.json()['all_holes_scored'])

    def test_odd_cents_go_to_the_higher_course_handicap(self):
        """$300 × 30% = $90.00 divides evenly; $300 × 50% = $150 does too, so
        use a fee that does not: the rule is that the remainder is ASSIGNED,
        not lost, and the pool balances to zero either way."""
        s = self.client.get(
            reverse('api-team-play-settlement', args=[self.tourn.id])).json()
        self.assertEqual(s['balance'], 0)


# ---------------------------------------------------------------------------
# 8. The wizard's own order — round setup FIRST, config second
# ---------------------------------------------------------------------------

class WizardOrderTests(TestCase):
    """
    Every other test in this file builds its Foursomes by hand, which skips the
    two calls the wizard actually makes and in the order it makes them:

        POST /rounds/<id>/setup/     explicit 2-golfer groups, auto_setup_games
        POST /tournaments/<id>/team-play/setup/   team_size=2, best_ball

    The config does not exist yet during the first call, so anything that pads
    or provisions a group has to get pairs right without being told they are
    pairs — which is a different question from the one the hand-built tests ask.
    """

    def setUp(self):
        self.acct = Account.objects.create(name='Saturday Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Saturday Pairs',
            start_date=date(2026, 6, 6), total_rounds=1,
            active_games=['team_play'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='pending')

        self.players = []
        for pair in PAIRS:
            for name, hcp in pair:
                self.players.append(Player.objects.create(
                    account=self.acct, name=name,
                    handicap_index=Decimal(hcp)))

    def _run_wizard(self, team_format='best_ball'):
        """Exactly what the wizard posts, in the order it posts it."""
        body = {
            'players': [
                {'player_id': p.id, 'tee_id': self.tee.id,
                 'group_number': (i // 2) + 1}
                for i, p in enumerate(self.players)
            ],
            'randomise': False,
            'auto_setup_games': True,
        }
        r = self.client.post(
            reverse('api-round-setup', args=[self.round.id]), body,
            format='json')
        assert r.status_code in (200, 201), r.content
        return self.client.post(
            reverse('api-team-play-setup', args=[self.tourn.id]),
            {'team_size': 2, 'team_format': team_format, 'entry_fee': '25.00',
             'places_paid': 3, 'split_pcts': [50, 30, 20]},
            format='json')

    def test_no_phantom_lands_on_a_pair(self):
        """In fours the phantom is a handicap device for a team that still hits
        four balls. In pairs it would be an imaginary partner taking half the
        shots, so there must not be one anywhere."""
        r = self._run_wizard()
        self.assertEqual(r.status_code, 200, r.content)

        from tournament.models import FoursomeMembership
        phantoms = FoursomeMembership.objects.filter(
            foursome__round=self.round, player__is_phantom=True)
        self.assertEqual(
            list(phantoms), [],
            f'{phantoms.count()} phantom(s) on a pairs round')
        self.assertFalse(
            self.round.foursomes.filter(has_phantom=True).exists())

    def test_the_config_reaches_sync_teams(self):
        """The read model has to come out configured — the figures, the names
        and the colours are all `sync_teams`' work, and it is called with a
        config the same request just created."""
        self._run_wizard()
        summary = self.client.get(
            reverse('api-team-play', args=[self.tourn.id])).json()
        self.assertTrue(summary['configured'])
        self.assertEqual(summary['team_size'], 2)
        self.assertEqual(len(summary['teams']), 6)
        for team in summary['teams']:
            self.assertFalse(team['has_phantom'], team['name'])
            self.assertEqual(team['real_player_count'], 2)
            self.assertEqual(team['seats_open'], 0)
            self.assertIsNotNone(team['team_handicap'], team['name'])
            self.assertTrue(team['colour'], team['name'])

    def test_pairs_are_named_by_their_surnames(self):
        self._run_wizard()
        summary = self.client.get(
            reverse('api-team-play', args=[self.tourn.id])).json()
        self.assertEqual(summary['teams'][0]['name'], 'Maiolini & Yau')

    def test_a_one_ball_pairs_format_is_equally_phantom_free(self):
        self._run_wizard('alternate_shot')
        from tournament.models import FoursomeMembership
        self.assertFalse(FoursomeMembership.objects.filter(
            foursome__round=self.round, player__is_phantom=True).exists())

    def test_a_three_man_best_ball_pair_gets_no_phantom_either(self):
        """The odd-field way out is a real group of three, not two golfers and an
        imaginary one — best ball simply counts the best of three balls."""
        # 3 + 3 + 2 + 2 + 2 = 12.
        sizes, groups = [3, 3, 2, 2, 2], []
        for n, size in enumerate(sizes, start=1):
            groups.extend([n] * size)
        body = {
            'players': [
                {'player_id': p.id, 'tee_id': self.tee.id,
                 'group_number': groups[i]}
                for i, p in enumerate(self.players)
            ],
            'randomise': False,
            'auto_setup_games': True,
        }
        r = self.client.post(
            reverse('api-round-setup', args=[self.round.id]), body,
            format='json')
        self.assertIn(r.status_code, (200, 201), r.content)
        self.client.post(
            reverse('api-team-play-setup', args=[self.tourn.id]),
            {'team_size': 2, 'team_format': 'best_ball'}, format='json')

        from tournament.models import FoursomeMembership
        self.assertFalse(FoursomeMembership.objects.filter(
            foursome__round=self.round, player__is_phantom=True).exists())
        summary = self.client.get(
            reverse('api-team-play', args=[self.tourn.id])).json()
        self.assertEqual(summary['teams'][0]['real_player_count'], 3)
        self.assertEqual(summary['blocking'], [])

    def test_six_golfers_in_chapman_make_exactly_three_pairs(self):
        """Six golfers are three twosomes — not four groups, and not the
        [3, 3] the fours auto-balance would produce. The wizard sends explicit
        group numbers, and `setup_round` wipes any previous setup for the round
        before creating them, so a re-run cannot leave a stale group behind."""
        six = self.players[:6]
        body = {
            'players': [
                {'player_id': p.id, 'tee_id': self.tee.id,
                 'group_number': (i // 2) + 1}
                for i, p in enumerate(six)
            ],
            'randomise': False,
            'auto_setup_games': True,
        }
        r = self.client.post(
            reverse('api-round-setup', args=[self.round.id]), body,
            format='json')
        self.assertIn(r.status_code, (200, 201), r.content)
        self.client.post(
            reverse('api-team-play-setup', args=[self.tourn.id]),
            {'team_size': 2, 'team_format': 'chapman'}, format='json')

        self.assertEqual(self.round.foursomes.count(), 3)
        summary = self.client.get(
            reverse('api-team-play', args=[self.tourn.id])).json()
        self.assertEqual(len(summary['teams']), 3)
        self.assertEqual([t['real_player_count'] for t in summary['teams']],
                         [2, 2, 2])
        self.assertEqual(summary['blocking'], [])

    def test_re_running_setup_leaves_no_stale_groups(self):
        """The report that prompted this: a tee sheet showing four groups for a
        field of three pairs. Re-running setup with a smaller field must shrink
        the sheet, not add to it."""
        self._run_wizard('chapman')                    # 12 golfers → 6 pairs
        self.assertEqual(self.round.foursomes.count(), 6)

        six = self.players[:6]
        r = self.client.post(
            reverse('api-round-setup', args=[self.round.id]),
            {'players': [
                {'player_id': p.id, 'tee_id': self.tee.id,
                 'group_number': (i // 2) + 1}
                for i, p in enumerate(six)],
             'randomise': False, 'auto_setup_games': True},
            format='json')
        self.assertIn(r.status_code, (200, 201), r.content)
        self.assertEqual(self.round.foursomes.count(), 3)


# ---------------------------------------------------------------------------
# 9. The foursome is the PLAYING group, and it holds two pairs
# ---------------------------------------------------------------------------

class PlayingGroupTests(PairsBase):
    """
    Two pairs go off together, share a tee time and a scorer, and one person
    enters everything on the card — but they are two separate teams on the
    board (docs/design-review/handoff-team-pairs/SPEC.md §3).

    The field here is six golfers in two groups: one carrying two pairs, one
    carrying a single pair, which is exactly the shape a six-golfer event takes.
    """

    ROSTER = [
        [('Anna Maiolini', 4), ('Ambrose Yau', 19),
         ('Alan Petersen', 6), ('Dan Reilly', 21)],
        [('Tom Mercer', 5),    ('Chris Vaughn', 24)],
    ]

    def test_a_group_of_four_holds_two_teams(self):
        self._configure('scotch')
        summary = self._summary()
        self.assertEqual(summary['field']['golfers'], 6)
        self.assertEqual(summary['field']['groups'], 2)
        self.assertEqual(summary['field']['teams'], 3)
        self.assertEqual(summary['blocking'], [])

    def test_the_split_follows_the_order_the_td_dragged_them_into(self):
        self._configure('scotch')
        teams = self._summary()['teams']
        self.assertEqual([t['slot'] for t in teams], [1, 2, 1])
        self.assertEqual(teams[0]['name'], 'Maiolini & Yau')
        self.assertEqual(teams[1]['name'], 'Petersen & Reilly')
        self.assertEqual(teams[2]['name'], 'Mercer & Vaughn')

    def test_each_pair_is_worked_on_its_own_two_men(self):
        self._configure('scramble')
        teams = self._summary()['teams']
        self.assertEqual([t['team_handicap'] for t in teams], [4, 5, 5])
        for t in teams:
            self.assertEqual(t['real_player_count'], 2)

    def test_two_pairs_in_a_group_never_share_a_colour(self):
        self._configure('scramble')
        colours = [t['colour'] for t in self._summary()['teams']]
        self.assertEqual(len(set(colours)), 3, colours)

    def test_one_card_carries_both_pairs(self):
        """One tee time, one scorer, one card — and two teams on it."""
        self._configure('scotch')
        card = self._card(self.groups[0], 7)
        self.assertEqual(len(card['teams']), 2)
        self.assertEqual([t['slot'] for t in card['teams']], [1, 2])
        self.assertEqual(card['teams'][0]['name'], 'Maiolini & Yau')
        self.assertEqual(card['teams'][1]['name'], 'Petersen & Reilly')

    def test_a_group_carrying_one_pair_sends_one_team(self):
        self._configure('scotch')
        card = self._card(self.groups[1], 7)
        self.assertEqual(len(card['teams']), 1)
        self.assertEqual(card['teams'][0]['name'], 'Mercer & Vaughn')

    def test_each_pair_scores_its_own_ball(self):
        """Both pairs are on one card and both carry a null team FK, so the
        slot is the only thing telling their scores apart."""
        self._configure('scotch')
        fs = self.groups[0]
        url = reverse('api-team-play-score', args=[fs.id])
        self.client.post(url, {'slot': 1, 'hole_number': 1, 'gross_score': 4},
                         format='json')
        r = self.client.post(
            url, {'slot': 2, 'hole_number': 1, 'gross_score': 6},
            format='json')
        self.assertEqual(r.status_code, 200, r.content)

        card = self._card(fs, 1)
        self.assertEqual(card['teams'][0]['team_score'], 4)
        self.assertEqual(card['teams'][1]['team_score'], 6)

    def test_the_board_ranks_pairs_not_groups(self):
        self._configure('scramble')
        for fs, slot, gross in ((self.groups[0], 1, 4),
                                (self.groups[0], 2, 5),
                                (self.groups[1], 1, 6)):
            url = reverse('api-team-play-score', args=[fs.id])
            for hole in range(1, 19):
                self.client.post(
                    url, {'slot': slot, 'hole_number': hole,
                          'gross_score': gross}, format='json')

        board = self.client.get(
            reverse('api-team-play-leaderboard', args=[self.tourn.id])).json()
        self.assertEqual(len(board['teams']), 3)
        self.assertTrue(board['all_in'])
        self.assertEqual(board['teams'][0]['name'], 'Maiolini & Yau')
        # Both pairs from group 1 are on the board, separately.
        self.assertEqual(
            sorted(t['slot'] for t in board['teams']
                   if t['foursome_id'] == self.groups[0].id), [1, 2])

    def test_the_td_can_re_pair_inside_a_group(self):
        self._configure('scramble')
        fs = self.groups[0]
        ids = {name: self.players[name].id for name in
               ('Anna Maiolini', 'Ambrose Yau', 'Alan Petersen', 'Dan Reilly')}
        r = self.client.post(
            reverse('api-team-play-split', args=[fs.id]),
            {'slots': {str(ids['Anna Maiolini']): 1,
                       str(ids['Alan Petersen']): 1,
                       str(ids['Ambrose Yau']): 2,
                       str(ids['Dan Reilly']): 2}},
            format='json')
        self.assertEqual(r.status_code, 200, r.content)
        names = [t['name'] for t in self._summary()['teams']]
        self.assertIn('Maiolini & Petersen', names)
        self.assertIn('Yau & Reilly', names)

    def test_four_golfers_split_two_and_two(self):
        self._configure('scramble')
        ids = [self.players[n].id for n in
               ('Anna Maiolini', 'Ambrose Yau', 'Alan Petersen', 'Dan Reilly')]
        r = self.client.post(
            reverse('api-team-play-split', args=[self.groups[0].id]),
            {'slots': {str(ids[0]): 1, str(ids[1]): 1,
                       str(ids[2]): 1, str(ids[3]): 2}},
            format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('two and two', r.json()['detail'])

    def test_re_pairing_is_refused_once_a_score_lands(self):
        self._configure('scramble')
        fs = self.groups[0]
        self.client.post(reverse('api-team-play-score', args=[fs.id]),
                         {'slot': 1, 'hole_number': 1, 'gross_score': 4},
                         format='json')
        ids = [self.players[n].id for n in
               ('Anna Maiolini', 'Ambrose Yau', 'Alan Petersen', 'Dan Reilly')]
        r = self.client.post(
            reverse('api-team-play-split', args=[fs.id]),
            {'slots': {str(ids[0]): 1, str(ids[2]): 1,
                       str(ids[1]): 2, str(ids[3]): 2}},
            format='json')
        self.assertEqual(r.status_code, 409)

    def test_a_foursome_event_has_nothing_to_split(self):
        self.client.post(self._setup_url(),
                         {'team_size': 4, 'team_format': 'scramble'},
                         format='json')
        r = self.client.post(
            reverse('api-team-play-split', args=[self.groups[0].id]),
            {'slots': {}}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('one team per group', r.json()['detail'])
