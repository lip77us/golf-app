"""
api/test_one_pool_games.py
--------------------------
**One group game per round** (Paul, 15 Oct 2026).

Irish Rumble, Better Ball, Hot Seat and 40 Balls rank a field of foursomes
into ONE pool paid to the winning group. Rumble and Better Ball are the same
competition scored two ways; Hot Seat and 40 Balls are genuinely different
games, and each config carries its own entry fee and payout table, so two
pools COULD have been collected separately. The call is that a group plays one
of them, so there is one board to read and one pot to settle.

Guarded in `services.group_field` and called from every path that writes one
of their configs — two services and two views, because Irish Rumble and 40
Balls have no service-level setup. Before this, only Rumble <-> Better Ball
was guarded anywhere below the pickers: four of the six pairs could be written
by any client that asked.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]

#: slug -> (url name, a body its serializer accepts)
SETUPS = {
    'irish_rumble': ('api-irish-rumble-setup', {
        'variant': 'classic', 'handicap_mode': 'gross', 'net_percent': 100,
        'entry_fee': '10.00', 'payouts': []}),
    'better_ball': ('api-better-ball-setup', {
        'balls_to_count': 2, 'handicap_mode': 'gross',
        'entry_fee': '10.00', 'payouts': []}),
    'hot_spot': ('api-hot-spot-setup', {
        'scoring': 'to_par', 'handicap_mode': 'gross', 'net_percent': 85,
        'finish_rule': 'keep_rotating', 'entry_fee': '10.00', 'payouts': []}),
    'forty_balls': ('api-forty-balls-setup', {
        'handicap_mode': 'gross', 'net_percent': 100,
        'entry_fee': '10.00', 'payouts': []}),
}


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='One Pool Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=[], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        for n in ('A', 'B', 'C', 'D'):
            FoursomeMembership.objects.create(
                foursome=self.fs,
                player=Player.objects.create(account=self.acct, name=n,
                                             handicap_index=Decimal('0')),
                tee=self.tee, course_handicap=0, playing_handicap=0)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def playing(self, *slugs):
        self.round.active_games = list(slugs)
        self.round.save(update_fields=['active_games'])

    def configure(self, slug):
        name, body = SETUPS[slug]
        return self.client.post(reverse(name, args=[self.round.id]),
                                body, format='json')


class TheRuleTests(_Base):

    def test_the_helper_refuses_every_pair_in_both_directions(self):
        """Six pairs, twelve directions. Only one was guarded before."""
        from services.group_field import (ONE_POOL_GAMES, GroupGameExcluded,
                                          refuse_if_another_one_pool_game)
        for a in ONE_POOL_GAMES:
            for b in ONE_POOL_GAMES:
                if a == b:
                    continue
                with self.subTest(playing=a, configuring=b):
                    self.playing(a)
                    with self.assertRaises(GroupGameExcluded):
                        refuse_if_another_one_pool_game(self.round, b)

    def test_a_game_never_excludes_itself(self):
        """Re-opening a game's own setup to change the stake is routine."""
        from services.group_field import (ONE_POOL_GAMES,
                                          refuse_if_another_one_pool_game)
        for g in ONE_POOL_GAMES:
            with self.subTest(game=g):
                self.playing(g)
                refuse_if_another_one_pool_game(self.round, g)   # no raise

    def test_a_group_s_own_games_are_not_in_the_family(self):
        """Skins and Nassau are the group's, settled by the group. Stroke Play
        is an overlay the board emits for every individual-ball round."""
        from services.group_field import refuse_if_another_one_pool_game
        self.playing('skins', 'nassau', 'low_net_round')
        for g in ('irish_rumble', 'hot_spot'):
            with self.subTest(game=g):
                refuse_if_another_one_pool_game(self.round, g)   # no raise

    def test_the_refusal_NAMES_the_game_already_there(self):
        """The fix is to turn that one off, and the TD should not have to go
        looking for it. It uses the DISPLAY name, so Hot Seat reads as Hot
        Seat and not as `hot_spot`."""
        from services.group_field import (GroupGameExcluded,
                                          refuse_if_another_one_pool_game)
        self.playing('hot_spot')
        with self.assertRaises(GroupGameExcluded) as cm:
            refuse_if_another_one_pool_game(self.round, 'irish_rumble')
        msg = str(cm.exception)
        self.assertIn('Hot Seat', msg)
        self.assertIn('Irish Rumble', msg)
        self.assertNotIn('hot_spot', msg)


class EverySetupPathTests(_Base):
    """The rule holds whichever of the four the TD reaches, and whatever route
    the round was assembled by.

    Two of these write their config in the VIEW (Irish Rumble and 40 Balls
    have no service-level setup) and two in a service, so there is no single
    layer to put it in — which is exactly why the guard is shared.
    """

    def test_each_setup_endpoint_refuses_while_another_is_being_played(self):
        for playing in SETUPS:
            for configuring in SETUPS:
                if playing == configuring:
                    continue
                with self.subTest(playing=playing, configuring=configuring):
                    self.playing(playing)
                    r = self.configure(configuring)
                    self.assertEqual(r.status_code, 400, r.data)
                    self.assertIn('one of them', r.data['detail'])

    def test_each_setup_endpoint_accepts_when_it_is_the_only_one(self):
        for slug in SETUPS:
            with self.subTest(game=slug):
                self.playing(slug)
                r = self.configure(slug)
                self.assertIn(r.status_code, (200, 201), r.data)

    def test_the_refusal_writes_nothing(self):
        """Refused means refused, not written-then-rejected."""
        from games.models import HotSpotConfig
        self.playing('irish_rumble')
        self.assertEqual(self.configure('hot_spot').status_code, 400)
        self.assertFalse(HotSpotConfig.objects.filter(round=self.round)
                         .exists())


class TurningOneOffIsNotStillPlayingItTests(_Base):
    """The dead end the old guards had, and the reason the shared one keys on
    `active_games` instead of on a config row.

    `RoundFieldGamesView` drops a game's slug from `active_games` and LEAVES
    its config row, deliberately, so the stake and the payout table come back
    if the TD turns it on again. Both old guards asked whether the row
    EXISTED, so a TD who configured Better Ball, turned it off and picked
    Irish Rumble was told "This round is already running Better Ball — turn
    Better Ball off first", which he had already done.
    """

    def test_a_config_row_left_behind_does_not_block_the_next_game(self):
        self.playing('better_ball')
        self.assertIn(self.configure('better_ball').status_code, (200, 201))

        from games.models import BetterBallConfig
        self.assertTrue(BetterBallConfig.objects.filter(round=self.round)
                        .exists())

        # The TD turns Better Ball off and picks Irish Rumble.
        self.playing('irish_rumble')
        self.assertTrue(BetterBallConfig.objects.filter(round=self.round)
                        .exists(), 'the row is meant to survive the toggle')

        r = self.configure('irish_rumble')
        self.assertIn(r.status_code, (200, 201), r.data)

    def test_and_it_still_refuses_while_the_other_is_ACTUALLY_on(self):
        """The other half: the fix must not have turned the rule off."""
        self.playing('better_ball')
        self.assertIn(self.configure('better_ball').status_code, (200, 201))
        self.playing('better_ball', 'irish_rumble')
        self.assertEqual(self.configure('irish_rumble').status_code, 400)


class TheOldNamesAreVestigialTests(_Base):
    """`IrishRumbleExcluded` and `BetterBallExcluded` survive as subclasses so
    an outside importer still resolves them. **Nothing raises them**, and that
    is the part worth pinning: `except BetterBallExcluded` does NOT catch a
    `GroupGameExcluded`, because subclassing only helps the other way round.
    The Better Ball view caught the old name and 500ed on the shared guard
    until it was changed — found by these tests, not by reading.
    """

    def test_both_old_exceptions_are_the_shared_one(self):
        from services.better_ball import BetterBallExcluded
        from services.group_field import GroupGameExcluded
        from services.irish_rumble import IrishRumbleExcluded
        self.assertTrue(issubclass(IrishRumbleExcluded, GroupGameExcluded))
        self.assertTrue(issubclass(BetterBallExcluded, GroupGameExcluded))

    def test_the_old_helpers_now_cover_the_whole_family(self):
        """`refuse_if_better_ball` is a shim, so it no longer means what its
        name says — it refuses Hot Seat and 40 Balls too."""
        from services.group_field import GroupGameExcluded
        from services.irish_rumble import refuse_if_better_ball
        self.playing('hot_spot')
        with self.assertRaises(GroupGameExcluded):
            refuse_if_better_ball(self.round)
