"""The TD types in a paper scorecard.

Paul, 3 Nov 2026, of a 60-player event run in Golf Genius: *"some players
choose not to use halved. We have to allow the TD to enter scorecards at the
end of the round for those that are paper only… In the Ryder Cup, there were
a number of groups not using the app and it would have been nice to enter the
scores as they came in so the group on the course had an accurate
leaderboard."*

He could already do it — `foursome_for_scorer` gives him every foursome in his
own round and the hub has always drawn him an Enter Scores button on each one.
What he could not do is do it QUICKLY: the per-hole endpoint is eighteen
requests a card, each recalculating every game in the round.

So two things are under test here, plus the one trap:

* `/card/` writes a whole card in one request through the SAME writer, and
  recalculates once;
* `paper_card` says a group will never enter its own scores, and
  `field_progress` tells a reader what the board is missing;
* **a partial card is honest but costly in a skins pool** — a hole counts only
  once every participant has a score, so a pool member left blank removes that
  hole for everybody.
"""
from decimal import Decimal
from datetime import date

from django.db import connection
from django.test import TestCase
from django.test.utils import CaptureQueriesContext
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round, Tournament

HOLES = [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
         for n in range(1, 19)]


class _Base(TestCase):
    """Three groups of four in one tournament round, TD signed in."""

    def setUp(self):
        self.acct = Account.objects.create(name='TPSGC paper')
        self.user = User.objects.create_user(
            username='td', account=self.acct, is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Castlewood')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Ryder', start_date=date(2026, 11, 1),
            total_rounds=1, active_games=['low_net'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress',
            active_games=['low_net_round'], bet_unit=Decimal('20.00'))

        self.groups = []
        self.players = []
        for g in range(3):
            fs = Foursome.objects.create(round=self.round, group_number=g + 1)
            self.groups.append(fs)
            for i in range(4):
                # A real index, so the handicap allocation has something to
                # get wrong: off 9 he strokes on SI 1..9.
                p = Player.objects.create(
                    account=self.acct, name=f'G{g + 1}P{i + 1}',
                    handicap_index=Decimal('9'))
                FoursomeMembership.objects.create(
                    foursome=fs, player=p, tee=self.tee,
                    course_handicap=9, playing_handicap=9)
                self.players.append(p)

    def _card(self, fs, rows):
        return self.client.post(reverse('api-foursome-card', args=[fs.id]),
                                {'scores': rows}, format='json')

    def _full_card(self, fs, players, start=4):
        return [{'player_id': p.id, 'hole_number': h,
                 'gross_score': start + (h % 3)}
                for p in players for h in range(1, 19)]


class WholeCardTests(_Base):

    def test_one_request_writes_the_whole_group(self):
        fs = self.groups[0]
        players = [m.player for m in fs.memberships.all()]
        r = self._card(fs, self._full_card(fs, players))
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.data['holes_written'], 72)
        self.assertEqual(
            HoleScore.objects.filter(foursome=fs).count(), 72)

    def test_a_partial_card_is_the_normal_case(self):
        """Transcribing for a skins pool means entering the pool's golfers and
        leaving their partners alone."""
        fs = self.groups[0]
        one = [m.player for m in fs.memberships.all()][0]
        r = self._card(fs, self._full_card(fs, [one]))
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(HoleScore.objects.filter(foursome=fs).count(), 18)

    def test_a_few_holes_is_accepted_too(self):
        fs = self.groups[0]
        one = [m.player for m in fs.memberships.all()][0]
        r = self._card(fs, [
            {'player_id': one.id, 'hole_number': 7,  'gross_score': 3},
            {'player_id': one.id, 'hole_number': 12, 'gross_score': 5},
        ])
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(
            sorted(HoleScore.objects.filter(foursome=fs)
                   .values_list('hole_number', flat=True)), [7, 12])

    def test_the_strokes_are_what_the_allocator_says(self):
        """**An independent oracle, not the other endpoint.**

        The first version of this wrote the card, re-posted every hole through
        `/scores/` and asserted nothing moved — which cannot fail, because
        both paths call the same writer. A test that passes by construction is
        worse than none.

        So the expectation comes from `handicap_strokes_on_hole` directly: a
        per-player stroke index off that golfer's OWN tee, scaled for a
        partial round. Off 9 he strokes on SI 1..9 and not on 10..18, so a
        writer that lost the per-player tee or the hole number fails here.
        """
        fs = self.groups[0]
        players = [m.player for m in fs.memberships.all()]
        self._card(fs, self._full_card(fs, players))

        mship = {m.player_id: m for m in fs.memberships.select_related('tee')}
        for r in HoleScore.objects.filter(foursome=fs):
            m  = mship[r.player_id]
            si = m.tee.hole(r.hole_number).get('stroke_index', 18)
            self.assertEqual(
                r.handicap_strokes,
                m.handicap_strokes_on_hole(si, r.hole_number),
                f'player {r.player_id} hole {r.hole_number}')

        # And the fixture really does separate the two halves of the card, so
        # an all-zeros or all-ones bug could not slip through.
        strokes = {r.hole_number: r.handicap_strokes
                   for r in HoleScore.objects.filter(
                       foursome=fs, player=players[0])}
        self.assertEqual(sorted(h for h, v in strokes.items() if v), 
                         list(range(1, 10)))

    def test_the_card_view_has_no_writer_of_its_own(self):
        """One writer, asserted at the source.

        A second copy of the write would be a second copy of the handicap
        allocation, and this codebase has the scars from exactly that shape —
        `record_hole`'s rotation, the four `gross_total` traversals, the three
        `gross_to_par`s one of which failed invisibly.
        """
        import inspect

        from api.views import FoursomeCardView
        src = inspect.getsource(FoursomeCardView)
        self.assertIn('_write_hole_scores(', src)
        for forbidden in ('handicap_strokes_on_hole',
                          'HoleScore.objects.get_or_create',
                          'hs.save()'):
            self.assertNotIn(forbidden, src,
                             f'{forbidden} is a second writer')

    def test_one_request_beats_eighteen(self):
        """The whole reason the endpoint exists.

        The per-hole path recalculates every game in the round on every hole,
        so a card costs eighteen of those. This is not a tuned ceiling — it
        asserts the shape, that one request is cheaper than the eighteen it
        replaces.
        """
        # **The round needs a game whose recalculation costs something**, or
        # this cannot see the difference: with only Stroke Play active the
        # recalc is nearly free, and an earlier version of this test passed
        # against a mutant that recalculated on every hole. A skins pool is
        # about 40 queries a recalculation, which is what the endpoint exists
        # to pay once instead of eighteen times.
        from services.multi_skins import setup_multi_skins
        setup_multi_skins(
            self.round,
            participant_ids=[m.player_id
                             for fs in self.groups
                             for m in fs.memberships.all()],
            handicap_mode='net', bet_unit=20.00)

        players = [m.player for m in self.groups[0].memberships.all()]
        with CaptureQueriesContext(connection) as bulk:
            self._card(self.groups[0], self._full_card(self.groups[0], players))

        other = [m.player for m in self.groups[1].memberships.all()]
        with CaptureQueriesContext(connection) as per_hole:
            for h in range(1, 19):
                self.client.post(
                    reverse('api-score-submit', args=[self.groups[1].id]),
                    {'hole_number': h,
                     'scores': [{'player_id': p.id, 'gross_score': 4}
                                for p in other]},
                    format='json')

        # Three queries per score are irreducible — SELECT, INSERT and the
        # UPDATE `HoleScore.save()` needs to derive the net and the Stableford
        # points — so 216 of a four-man card is the write itself and the rest
        # is ONE recalculation plus the scorecard.
        #
        # Asserted as a FACTOR rather than a ceiling, because the ceiling
        # moves with the games a round is playing while the factor is the
        # claim. Recalculating per hole instead of once fails here.
        self.assertLess(len(bulk.captured_queries) * 2,
                        len(per_hole.captured_queries),
                        f'{len(bulk.captured_queries)} vs '
                        f'{len(per_hole.captured_queries)}')

    def test_a_stranger_is_refused(self):
        outsider = [m.player for m in self.groups[1].memberships.all()][0]
        r = self._card(self.groups[0], [
            {'player_id': outsider.id, 'hole_number': 1, 'gross_score': 4},
        ])
        self.assertEqual(r.status_code, 400, r.content)
        self.assertIn('not in this foursome', str(r.data['detail']))

    def test_the_same_hole_twice_is_refused(self):
        one = [m.player for m in self.groups[0].memberships.all()][0]
        r = self._card(self.groups[0], [
            {'player_id': one.id, 'hole_number': 3, 'gross_score': 4},
            {'player_id': one.id, 'hole_number': 3, 'gross_score': 5},
        ])
        self.assertEqual(r.status_code, 400, r.content)

    def test_another_account_cannot_type_a_card(self):
        other = Account.objects.create(name='Somebody else')
        stranger = User.objects.create_user(username='nosy', account=other)
        c = APIClient()
        c.force_authenticate(stranger)
        one = [m.player for m in self.groups[0].memberships.all()][0]
        r = c.post(reverse('api-foursome-card', args=[self.groups[0].id]),
                   {'scores': [{'player_id': one.id, 'hole_number': 1,
                                'gross_score': 4}]}, format='json')
        self.assertEqual(r.status_code, 404)


class PaperFlagTests(_Base):

    def _mark(self, fs, on=True, client=None):
        return (client or self.client).post(
            reverse('api-foursome-paper-card', args=[fs.id]),
            {'paper_card': on}, format='json')

    def test_the_td_marks_a_group_as_paper(self):
        r = self._mark(self.groups[2])
        self.assertEqual(r.status_code, 200, r.content)
        self.groups[2].refresh_from_db()
        self.assertTrue(self.groups[2].paper_card)

    def test_it_is_reversible(self):
        self._mark(self.groups[2])
        self._mark(self.groups[2], on=False)
        self.groups[2].refresh_from_db()
        self.assertFalse(self.groups[2].paper_card)

    def test_only_the_td_s_own_account(self):
        other = Account.objects.create(name='Another club')
        c = APIClient()
        c.force_authenticate(
            User.objects.create_user(username='x', account=other))
        self.assertEqual(self._mark(self.groups[0], client=c).status_code, 404)

    def test_the_round_payload_carries_it(self):
        self._mark(self.groups[2])
        r = self.client.get(reverse('api-round-detail', args=[self.round.id]))
        flags = {f['group_number']: f['paper_card'] for f in r.data['foursomes']}
        self.assertEqual(flags, {1: False, 2: False, 3: True})


class FieldProgressTests(_Base):

    def _board(self):
        from api.views import _build_leaderboard
        return _build_leaderboard(self.round).get('field_progress')

    def _play(self, fs):
        players = [m.player for m in fs.memberships.all()]
        self._card(fs, self._full_card(fs, players))

    def test_it_says_what_the_board_is_missing(self):
        self._play(self.groups[0])
        p = self._board()
        self.assertEqual(p['groups'], 3)
        self.assertEqual(p['complete'], 1)
        self.assertEqual([r['group_number'] for r in p['awaiting']], [2, 3])

    def test_paper_and_merely_behind_are_told_apart(self):
        """Different facts: the first is the TD's job, the second sorts
        itself out."""
        self.groups[1].paper_card = True
        self.groups[1].save(update_fields=['paper_card'])
        p = self._board()
        self.assertEqual(p['paper'], 1)
        self.assertEqual(p['paper_awaiting'], 1)
        by_group = {r['group_number']: r for r in p['awaiting']}
        self.assertTrue(by_group[2]['paper_card'])
        self.assertFalse(by_group[3]['paper_card'])
        # Paper groups lead the list — they are the ones somebody has to act
        # on.
        self.assertEqual(p['awaiting'][0]['group_number'], 2)

    def test_a_paper_group_that_is_fully_in_needs_no_flag(self):
        """How its card reached the app stops mattering the moment it is
        there, so it is not in `awaiting` at all."""
        self.groups[1].paper_card = True
        self.groups[1].save(update_fields=['paper_card'])
        self._play(self.groups[1])
        p = self._board()
        self.assertEqual(p['paper'], 1)
        self.assertEqual(p['paper_awaiting'], 0)
        self.assertNotIn(2, [r['group_number'] for r in p['awaiting']])

    def test_it_carries_how_far_round_each_group_is(self):
        fs = self.groups[1]
        one = [m.player for m in fs.memberships.all()][0]
        self._card(fs, [{'player_id': one.id, 'hole_number': h,
                         'gross_score': 4} for h in range(1, 10)])
        row = {r['group_number']: r for r in self._board()['awaiting']}[2]
        self.assertEqual(row['thru'], 9)
        self.assertEqual(row['expected'], 18)

    def test_it_is_not_a_game_tab(self):
        """A fact about the round, not a competition — so a client that tabs
        off the key set must not draw it."""
        from api.views import _build_leaderboard, _leaderboard_active_games
        games = _build_leaderboard(self.round)
        self.assertIn('field_progress', games)
        self.assertNotIn('field_progress',
                         _leaderboard_active_games(self.round, games))

    def test_a_single_group_round_has_none(self):
        self.groups[1].delete()
        self.groups[2].delete()
        self.assertIsNone(self._board())


class ThePoolCostOfAPartialCardTests(_Base):
    """The trap worth stating out loud.

    A skins hole counts only once EVERY participant has a score on it — which
    is right for a live pool, and means a pool member left blank removes that
    hole from the pool for everybody, including the golfers who entered it
    themselves. So "just the holes that matter" does not work: enter a pool
    member's card in full or not at all.
    """

    def _pool(self, players):
        from services.multi_skins import setup_multi_skins
        setup_multi_skins(self.round,
                          participant_ids=[p.id for p in players],
                          handicap_mode='gross', bet_unit=20.00)

    def test_a_blank_pool_member_removes_the_hole_for_everybody(self):
        from services.multi_skins import (
            multi_skins_summary, recalc_pools_for_round,
        )
        app_golfer   = [m.player for m in self.groups[0].memberships.all()][0]
        paper_golfer = [m.player for m in self.groups[1].memberships.all()][0]
        self._pool([app_golfer, paper_golfer])

        # The app group enters its whole card; the paper golfer gets ONE hole.
        self._card(self.groups[0], [
            {'player_id': app_golfer.id, 'hole_number': h, 'gross_score': 4}
            for h in range(1, 19)])
        self._card(self.groups[1], [
            {'player_id': paper_golfer.id, 'hole_number': 7, 'gross_score': 5},
        ])
        recalc_pools_for_round(self.round)
        s = multi_skins_summary(self.round)

        # ONE hole resolved — the one the paper golfer has. Seventeen holes
        # the app golfer entered himself count for nothing.
        self.assertEqual(sum(p['skins_won'] for p in s['players']), 1)
        won = {p['player_id']: p['skins_won'] for p in s['players']}
        self.assertEqual(won[app_golfer.id], 1)

    def test_the_full_card_is_what_works(self):
        from services.multi_skins import (
            multi_skins_summary, recalc_pools_for_round,
        )
        app_golfer   = [m.player for m in self.groups[0].memberships.all()][0]
        paper_golfer = [m.player for m in self.groups[1].memberships.all()][0]
        self._pool([app_golfer, paper_golfer])

        self._card(self.groups[0], [
            {'player_id': app_golfer.id, 'hole_number': h, 'gross_score': 4}
            for h in range(1, 19)])
        self._card(self.groups[1], [
            # Loses every hole but the 7th.
            {'player_id': paper_golfer.id, 'hole_number': h,
             'gross_score': 3 if h == 7 else 5}
            for h in range(1, 19)])
        recalc_pools_for_round(self.round)
        s = multi_skins_summary(self.round)

        won = {p['player_id']: p['skins_won'] for p in s['players']}
        self.assertEqual(won[app_golfer.id], 17)
        self.assertEqual(won[paper_golfer.id], 1)
