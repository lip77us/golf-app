"""
api/test_pink_ball_lost.py
--------------------------
The ball-lost flag rides on the score POST, and that path used to hand-roll
the `PinkBallHoleResult` row with ``pink_order[hole_number - 1]`` — indexing
the rotation by hole NUMBER where the rule is the hole's POSITION in the
group's own play order.

`services/red_ball.record_hole` is "the ONE place the rotation rule lives" and
has been right since the shotgun sweep; `scoring/tests/test_red_ball.py
::RotationDivergenceTests` documents the divergence at length. This file is
the endpoint half, which was a SECOND writer of the same row and therefore
still carried the bug the service had fixed.

A start of **8** is the configuration where nothing cancels, for the two
reasons that test class sets out: ``(8 - 1) % 3 != 0``, so the offset does not
cancel at the first tee, and ``18 % 3 == 0`` is irrelevant once it does not.
Off the 13th with three golfers the two formulas agree on every hole, which is
why a shotgun test has to pick its start deliberately.
"""
from django.contrib.auth import get_user_model
from django.test import TestCase
from rest_framework.test import APIClient

from games.models import PinkBallConfig, PinkBallHoleResult
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
)
from services.red_ball import carrier_on_hole

User = get_user_model()

START = 8


class _Base(TestCase):
    def setUp(self):
        course     = make_course()
        self.tee   = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, active_games=['pink_ball'])
        self.round.starting_hole = START
        self.round.save(update_fields=['starting_hole'])
        PinkBallConfig.objects.create(
            round=self.round, game_name='Devil Ball', entry_fee=10,
            payouts=[{'place': 1, 'amount': 30}])

        self.fs = make_foursome(
            self.round, [('Ann', 0), ('Bea', 0), ('Cal', 0)],
            tee=self.tee, group_number=1)
        self.fs.pink_ball_order = [
            m.player_id for m in self.fs.memberships.order_by('id')]
        self.fs.save(update_fields=['pink_ball_order'])

        self.user = User.objects.create_user(
            username='td', account=self.round.account)
        self.api = APIClient()
        self.api.force_authenticate(self.user)

    # -- helpers ------------------------------------------------------------
    @property
    def order(self):
        return self.fs.pink_ball_order

    @property
    def holes(self):
        return [((START - 1 + i) % 18) + 1 for i in range(18)]

    def post_hole(self, hole, *, lost=False, grosses=None):
        """`grosses` maps player id -> gross, so a test can make the golfers'
        nets DIFFER. Without that the stored net is the same number whichever
        golfer the row was filed against, and a test cannot tell them apart."""
        return self.api.post(
            f'/api/foursomes/{self.fs.id}/scores/',
            {
                'hole_number': hole,
                'scores': [
                    {'player_id': m.player_id,
                     'gross_score': (grosses or {}).get(m.player_id, 4)}
                    for m in self.fs.memberships.all()],
                'pink_ball_lost': lost,
            },
            format='json')

    def row(self, hole):
        return PinkBallHoleResult.objects.filter(
            foursome=self.fs, hole_number=hole).first()


class TheLossIsFiledAgainstTheRealCarrierTests(_Base):
    def test_the_first_tee_belongs_to_the_first_name(self):
        """Hole 8 is this group's FIRST hole, so the ball is the #1 name's."""
        r = self.post_hole(8, lost=True)
        self.assertIn(r.status_code, (200, 201), r.data)
        row = self.row(8)
        self.assertIsNotNone(row, 'no ball-lost row was written')
        self.assertEqual(row.pink_ball_player_id, self.order[0])

    def test_it_is_not_what_the_old_arithmetic_said(self):
        """The guard: a start where the two formulas actually differ.

        `(8 - 1) % 3 == 1`, so the old rule named the SECOND golfer. Without
        this assertion the test above would pass against the bug on any start
        congruent to 1.
        """
        self.post_hole(8, lost=True)
        self.assertNotEqual(self.row(8).pink_ball_player_id,
                            self.order[(8 - 1) % 3],
                            'the old rule agreed, so this start proves nothing')

    def test_it_agrees_with_the_service_on_every_hole_of_the_round(self):
        for pos, hole in enumerate(self.holes):
            self.post_hole(hole, lost=True)
            self.assertEqual(
                self.row(hole).pink_ball_player_id,
                carrier_on_hole(self.order, self.holes, hole),
                msg=f"hole {hole} is the group's #{pos + 1}")

    def test_the_carrier_s_own_net_is_stored(self):
        """Not the net of whoever the old index happened to land on."""
        self.post_hole(8, lost=True)
        row = self.row(8)
        self.assertEqual(row.pink_ball_player_id, self.order[0])
        self.assertIsNotNone(row.net_score)


class AnOrdinaryScorePostNeverTouchesTheBallTests(_Base):
    def test_a_plain_post_writes_no_row(self):
        self.post_hole(8)
        self.assertIsNone(self.row(8))

    def test_a_shipped_client_cannot_un_lose_the_ball(self):
        """Every build in the field sends `pink_ball_lost: false` on every
        post, so honouring a false would un-lose the ball the moment somebody
        corrected a score on that hole. The undo is its own route."""
        self.post_hole(8, lost=True)
        self.assertTrue(self.row(8).ball_lost)

        self.post_hole(8, lost=False)          # an edit from any shipped build
        self.assertTrue(self.row(8).ball_lost,
                        'a false on the score post must not clear the loss')


class TheStoredNetBelongsToTheRealCarrierTests(_Base):
    """The production shape: **18 entries, one per hole**, which is what the
    model docstring and `PinkBallFoursomeOrderView` ("exactly 18 entries")
    describe.

    **Why this class exists at all.** Routing the write through `record_hole`
    fixes the ATTRIBUTION by construction — that function resolves the carrier
    itself, so `pink_ball_player_id` is right whatever the view believes. What
    the view still decides is whose NET it looks up and hands over, and that is
    the only thing a test here can discriminate on.

    Found by mutation: an earlier version of this class asserted the stored
    player and passed with the old `pink_order[hole_number - 1]` put back,
    because `record_hole` was overruling the view either way. Four tests that
    proved nothing. Every golfer posts a DIFFERENT gross here so the nets
    differ and the wrong carrier is visible in the stored number.

    **The two readings of this field disagree** and the engine's is the ruling:
    `carrier_at` indexes by POSITION in the group's play order, settled by
    `RotationDivergenceTests` as "whoever is first in the order plays the ball
    off the group's first tee, whichever hole that is". The model's
    "[player_id_hole1, ...]" is the stale description.
    """

    def setUp(self):
        super().setUp()
        self.roster = [m.player_id for m in self.fs.memberships.order_by('id')]
        self.fs.pink_ball_order = [
            self.roster[i % len(self.roster)] for i in range(18)]
        self.fs.save(update_fields=['pink_ball_order'])
        # Distinct grosses: 3, 6, 9 — so every pair of nets differs by enough
        # that no cap or stroke allocation can collapse two of them together.
        self.grosses = {pid: 3 + 3 * i for i, pid in enumerate(self.roster)}

    def test_the_order_is_eighteen_long_like_production(self):
        self.assertEqual(len(self.order), 18, 'anchor: the production shape')

    def test_the_first_tee_s_net_is_stored_not_the_hole_index_s(self):
        """Hole 8 is this group's first. The old rule looked up `order[7]`,
        a different real golfer, and stored HIS net."""
        self.post_hole(8, lost=True, grosses=self.grosses)
        row = self.row(8)
        self.assertIsNotNone(row)

        from scoring.models import HoleScore
        want = HoleScore.objects.get(
            foursome=self.fs, player_id=self.order[0], hole_number=8).net_score
        wrong = HoleScore.objects.get(
            foursome=self.fs, player_id=self.order[7], hole_number=8).net_score

        self.assertNotEqual(want, wrong,
                            'the fixture must make the two nets differ, or '
                            'this test cannot tell the carriers apart')
        self.assertEqual(row.net_score, want)

    def test_every_hole_stores_its_own_carrier_s_net(self):
        for hole in self.holes:
            self.post_hole(hole, lost=True, grosses=self.grosses)
            from scoring.models import HoleScore
            carrier = carrier_on_hole(self.order, self.holes, hole)
            want = HoleScore.objects.get(
                foursome=self.fs, player_id=carrier,
                hole_number=hole).net_score
            self.assertEqual(self.row(hole).net_score, want,
                             msg=f'hole {hole}')
