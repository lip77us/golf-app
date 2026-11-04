"""
api/test_forty_balls_sparse.py
------------------------------
**Sparse 40 Balls: a subset of the GROUPS.**

A sixty-player tournament run in another system on paper can still have a
40 Balls side game between four of its fifteen groups, played on the draw the
event already has. 40 Balls ranks groups, so sparse here means a subset of the
groups — where the skins pool's subset is of the golfers.

The invariant the whole feature rests on: **an empty narrowing is the whole
field**, so every round played before this is on exactly the path it was
already on and the unflighted case cannot drift.
"""
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import User
from games.models import FortyBallsConfig
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
    make_tournament, submit_hole,
)
from services.forty_balls import FortyBallsNotPlaying, forty_balls_summary
from services.group_field import (plays_pool_game, pool_foursomes,
                                  not_in_round_group_ids)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}


class _Base(TestCase):
    """Four groups — enough that a subset is a real subset both ways."""

    def setUp(self):
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tourn = make_tournament(name='Autumn Cup')
        self.round = make_round(course=self.course, tournament=self.tourn,
                                active_games=[])
        names = [('Ann', 'Bea', 'Cal', 'Dee'), ('Eve', 'Fay', 'Gus', 'Hal'),
                 ('Ivy', 'Jon', 'Kay', 'Lee'), ('Mae', 'Ned', 'Oly', 'Pat')]
        self.groups = [
            make_foursome(self.round, [(n, 0) for n in four], tee=self.tee,
                          group_number=i + 1)
            for i, four in enumerate(names)
        ]
        self.account = self.course.account
        self.user = User.objects.create_user(
            username='td', password='x', account=self.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    # -- helpers ------------------------------------------------------------
    def setup_url(self):
        return f'/api/rounds/{self.round.id}/forty-balls/setup/'

    def count_url(self, fs):
        return f'/api/foursomes/{fs.id}/forty-balls/count/'

    def configure(self, **kw):
        body = {'handicap_mode': 'net', 'net_percent': 100,
                'net_max_double_bogey': True, 'entry_fee': '10.00',
                'payouts': [{'place': 1, 'amount': '100.00'}]}
        body.update(kw)
        return self.client.post(self.setup_url(), body, format='json')

    def par_hole(self, fs, hole, *deltas):
        pids = [m.player_id for m in fs.memberships.order_by('id')]
        submit_hole(fs, hole, [(p, PAR[hole] + d)
                               for p, d in zip(pids, deltas)])

    def cfg(self):
        return FortyBallsConfig.objects.get(round=self.round)


class EmptyMeansEveryGroupTests(_Base):
    """The degenerate case, which is every round that has ever been played."""

    def test_no_narrowing_is_the_whole_field(self):
        self.configure()
        self.assertEqual(
            [fs.pk for fs in pool_foursomes(self.round, self.cfg())],
            [fs.pk for fs in self.groups])

    def test_no_config_at_all_is_the_whole_field(self):
        self.assertEqual(
            [fs.pk for fs in pool_foursomes(self.round, None)],
            [fs.pk for fs in self.groups])

    def test_every_group_plays_when_nothing_is_narrowed(self):
        self.configure()
        for fs in self.groups:
            self.assertTrue(plays_pool_game(fs, self.cfg()), fs.group_number)

    def test_a_game_with_no_groups_relation_answers_the_whole_field(self):
        """Duck-typed, so Irish Rumble and the other two need no branch."""
        class _NoRelation:
            pass
        self.assertEqual(
            [fs.pk for fs in pool_foursomes(self.round, _NoRelation())],
            [fs.pk for fs in self.groups])
        self.assertTrue(plays_pool_game(self.groups[0], _NoRelation()))

    def test_an_absent_group_ids_leaves_the_pool_alone(self):
        """**The reason absent and `[]` are different.**

        Every shipped build sends no `group_ids`, so a TD editing the entry
        fee from an older phone must not silently widen a four-group pool
        back to all fifteen and charge eleven groups that are not playing.
        """
        self.configure(group_ids=[self.groups[0].pk, self.groups[1].pk])
        self.configure(entry_fee='20.00')            # no group_ids at all
        self.assertEqual(
            sorted(self.cfg().groups.values_list('pk', flat=True)),
            sorted([self.groups[0].pk, self.groups[1].pk]))

    def test_an_empty_list_widens_it_back_to_the_field(self):
        self.configure(group_ids=[self.groups[0].pk])
        self.configure(group_ids=[])
        self.assertEqual(
            [fs.pk for fs in pool_foursomes(self.round, self.cfg())],
            [fs.pk for fs in self.groups])


class TheBoardIsThePoolTests(_Base):
    def setUp(self):
        super().setUp()
        self.configure(group_ids=[self.groups[0].pk, self.groups[1].pk])

    def test_only_the_playing_groups_are_on_the_board(self):
        for fs in self.groups:
            self.par_hole(fs, 1, 0, 0, 0, 0)
        s = forty_balls_summary(self.round)
        self.assertEqual([r['group_number'] for r in s['results']], [1, 2])

    def test_it_says_four_of_fifteen(self):
        s = forty_balls_summary(self.round)
        self.assertEqual(s['n_groups'], 2)
        self.assertEqual(s['n_field_groups'], 4)
        self.assertTrue(s['sparse'])

    def test_a_full_field_is_not_called_sparse(self):
        self.configure(group_ids=[])
        s = forty_balls_summary(self.round)
        self.assertEqual(s['n_groups'], 4)
        self.assertFalse(s['sparse'])

    def test_the_pool_is_the_golfers_in_it(self):
        """$10 × the eight golfers playing, not × the sixteen in the round."""
        s = forty_balls_summary(self.round)
        self.assertEqual(s['pool'], 80.0)
        self.configure(group_ids=[])
        self.assertEqual(forty_balls_summary(self.round)['pool'], 160.0)

    def test_a_left_out_group_s_scores_still_stand(self):
        """It is out of 40 Balls, not out of the round."""
        self.par_hole(self.groups[3], 1, 0, 0, 0, 0)
        from scoring.models import HoleScore
        self.assertEqual(
            HoleScore.objects.filter(foursome=self.groups[3]).count(), 4)


class ALeftOutGroupCannotCountBallsTests(_Base):
    def setUp(self):
        super().setUp()
        self.configure(group_ids=[self.groups[0].pk])

    def test_the_service_refuses_it(self):
        from services.forty_balls import set_count
        self.par_hole(self.groups[1], 1, 0, 0, 0, 0)
        with self.assertRaises(FortyBallsNotPlaying):
            set_count(self.groups[1], 1, 2)

    def test_the_endpoint_refuses_it_and_says_why(self):
        self.par_hole(self.groups[1], 1, 0, 0, 0, 0)
        r = self.client.post(self.count_url(self.groups[1]),
                             {'hole_number': 1, 'count': 2}, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('not in the 40 Balls pool', r.data['detail'])

    def test_a_playing_group_still_counts_normally(self):
        self.par_hole(self.groups[0], 1, 0, 0, 0, 0)
        r = self.client.post(self.count_url(self.groups[0]),
                             {'hole_number': 1, 'count': 2}, format='json')
        self.assertEqual(r.status_code, 200)

    def test_the_two_refusals_do_not_catch_each_other(self):
        """`except` on a subclass does not catch the base, and vice versa."""
        from services.forty_balls import FortyBallsLocked
        self.assertFalse(issubclass(FortyBallsNotPlaying, FortyBallsLocked))
        self.assertFalse(issubclass(FortyBallsLocked, FortyBallsNotPlaying))


class TheClientIsToldTests(_Base):
    """The ball picker must not come up for a group that is not playing."""

    def test_the_foursome_payload_carries_it(self):
        self.configure(group_ids=[self.groups[0].pk])
        r = self.client.get(f'/api/rounds/{self.round.id}/')
        by_num = {f['group_number']: f for f in r.data['foursomes']}
        self.assertTrue(by_num[1]['plays_forty_balls'])
        self.assertFalse(by_num[2]['plays_forty_balls'])

    def test_every_group_plays_on_a_round_with_no_narrowing(self):
        self.configure()
        r = self.client.get(f'/api/rounds/{self.round.id}/')
        self.assertTrue(all(f['plays_forty_balls']
                            for f in r.data['foursomes']))

    def test_an_unconfigured_round_still_offers_it(self):
        """40 Balls can be active before it is set up, and the picker showed
        then — so the flag has to answer True there or turning the game on
        would hide the control that configures it."""
        r = self.client.get(f'/api/rounds/{self.round.id}/')
        self.assertTrue(all(f['plays_forty_balls']
                            for f in r.data['foursomes']))


class JoiningAndLeavingTests(_Base):
    def test_a_stray_group_is_refused_by_name(self):
        other = make_round(course=self.course, tournament=self.tourn,
                           active_games=[], round_number=2)
        theirs = make_foursome(other, [('Zed', 0), ('Yan', 0)], tee=self.tee)
        r = self.configure(group_ids=[self.groups[0].pk, theirs.pk])
        self.assertEqual(r.status_code, 400)
        self.assertIn('not in this round', r.data['detail'])
        self.assertEqual(r.data['group_ids'], [theirs.pk])
        self.assertFalse(FortyBallsConfig.objects.filter(
            round=self.round).exists())

    def test_not_in_round_group_ids_names_only_the_strays(self):
        other = make_round(course=self.course, tournament=self.tourn,
                           active_games=[], round_number=2)
        theirs = make_foursome(other, [('Zed', 0), ('Yan', 0)], tee=self.tee)
        self.assertEqual(
            not_in_round_group_ids(self.round,
                                   [self.groups[0].pk, theirs.pk, theirs.pk]),
            [theirs.pk])

    def test_a_group_may_join_before_the_round_starts(self):
        self.configure(group_ids=[self.groups[0].pk])
        r = self.configure(group_ids=[self.groups[0].pk, self.groups[1].pk])
        self.assertEqual(r.status_code, 201)
        self.assertEqual(len(pool_foursomes(self.round, self.cfg())), 2)

    def test_a_group_may_LEAVE_at_any_time(self):
        """Removing one is clean: the pool is derived on every read, so it
        stops being ranked and stops being charged."""
        self.configure(group_ids=[])
        for h in range(1, 15):
            for fs in self.groups:
                self.par_hole(fs, h, 0, 0, 0, 0)
        r = self.configure(group_ids=[self.groups[0].pk, self.groups[1].pk])
        self.assertEqual(r.status_code, 201)
        self.assertEqual(forty_balls_summary(self.round)['pool'], 80.0)

    def test_a_group_cannot_join_with_no_room_for_its_balls(self):
        """Forty balls into room for sixteen is the DQ state, and a TD who
        ticked a box and watched the group appear already out would have
        nothing to read."""
        self.configure(group_ids=[self.groups[0].pk])
        for h in range(1, 15):
            self.par_hole(self.groups[1], h, 0, 0, 0, 0)
        r = self.configure(group_ids=[self.groups[0].pk, self.groups[1].pk])
        self.assertEqual(r.status_code, 409)
        self.assertIn('Added too late', r.data['detail'])
        self.assertIn('Group 2', r.data['detail'])
        # And nothing landed — not the groups, and not the entry fee either.
        self.assertEqual(
            sorted(self.cfg().groups.values_list('pk', flat=True)),
            [self.groups[0].pk])

    def test_the_refused_join_does_not_write_the_other_settings(self):
        self.configure(group_ids=[self.groups[0].pk], entry_fee='10.00')
        for h in range(1, 15):
            self.par_hole(self.groups[1], h, 0, 0, 0, 0)
        r = self.configure(group_ids=[self.groups[0].pk, self.groups[1].pk],
                           entry_fee='99.00')
        self.assertEqual(r.status_code, 409)
        self.assertEqual(float(self.cfg().entry_fee), 10.00)

    def test_a_group_already_in_is_not_re_tested_when_it_is_too_late(self):
        """It is a JOIN that is refused, not a save. A TD editing the fee of a
        pool whose groups are past the point of joining must still be able to
        save — otherwise the money is frozen along with the field."""
        self.configure(group_ids=[self.groups[0].pk])
        for h in range(1, 15):
            self.par_hole(self.groups[0], h, 0, 0, 0, 0)
        r = self.configure(group_ids=[self.groups[0].pk], entry_fee='20.00')
        self.assertEqual(r.status_code, 201)


class TheSetupScreenSeesTheFieldTests(_Base):
    def test_the_GET_flags_each_group(self):
        self.configure(group_ids=[self.groups[0].pk, self.groups[2].pk])
        r = self.client.get(self.setup_url())
        self.assertEqual([g['in_pool'] for g in r.data['groups']],
                         [True, False, True, False])
        self.assertTrue(r.data['sparse'])
        self.assertEqual(r.data['n_in_pool'], 2)

    def test_it_names_the_golfers_so_the_TD_knows_which_group(self):
        """A row reading `Group 2` tells a TD nothing about who is in it."""
        r = self.client.get(self.setup_url())
        self.assertIn('Ann', r.data['groups'][0]['players'])
        self.assertIn('Dee', r.data['groups'][0]['players'])

    def test_an_unconfigured_round_shows_every_group_in(self):
        """What the screen shows has to be what the server will do, and on an
        unconfigured round that is the whole field."""
        r = self.client.get(self.setup_url())
        self.assertTrue(all(g['in_pool'] for g in r.data['groups']))
        self.assertFalse(r.data['sparse'])
