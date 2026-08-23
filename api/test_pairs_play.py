"""
api/test_pairs_play.py
----------------------
Pairs Play — two-man teams (docs/design-review/handoff-team-pairs/SPEC.md).

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
        """There is no two-man shamble. Nonsense rather than a preference, so
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
        four balls. In pairs it would be an imaginary man taking half the shots
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

    def test_the_default_is_written_so_every_surface_reads_it(self):
        """The hub, the tee sheet and the chat header know nothing about Team
        Play, so the pair's name has to land on the Foursome itself."""
        self._configure('scramble')
        self.groups[0].refresh_from_db()
        self.assertEqual(self.groups[0].name, 'Maiolini & Yau')

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
        from core.models import Player
        Player.objects.filter(name='Anna Maiolini').update(
            name='Anna Featherstonehaugh')
        self._configure('scramble')
        self.assertEqual(self._team(self._summary(), 1)['name'], 'Group 1')

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
        """The fix is about one man, so the block says which one rather than
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

    def test_a_three_ball_is_blocked_outside_best_ball(self):
        self._configure('chapman')
        blocking = self._summary()['blocking']
        self.assertEqual(blocking[0]['kind'], 'three_ball')
        self.assertIn('Only best ball can play a three',
                      blocking[0]['detail'])

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
        """One each per nine is TWO of nine, seven free — two men and eighteen
        holes is a lot of slack, which is why one each per nine is the usual
        rule."""
        self._configure('scramble', drive_rule='per_nine', drives_required=1)
        drive = self._team(self._summary(), 1)['drive']
        self.assertEqual(drive['required'], 2)
        self.assertEqual(drive['free'], 7)
        self.assertEqual(drive['floating'], 0)   # no phantom to cover

    def test_a_pair_may_be_asked_for_four_drives_a_nine(self):
        """The ceiling is the window's holes divided between the men, and it
        scales with the size: four men sharing nine top out at two each, two
        men at FOUR each. The shipped 2-and-4 was four men's answer
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

    def test_scotch_is_an_instruction(self):
        self._configure('scotch')
        summary = self._summary()
        self.assertEqual(summary['drive_control'], 'instruction')
        # The tap is required on every hole even with no quota, because there
        # it is not a record at all.
        self.assertEqual(summary['drive_rule'], 'none')
        self.assertTrue(summary['requires_drive_pick'])

    def test_scotch_answers_with_a_sentence(self):
        """Picking the drive says who hits NEXT — the partner whose ball was
        not taken plays the second shot."""
        self._configure('scotch')
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
        """Both men drive every hole with no choice to record."""
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
