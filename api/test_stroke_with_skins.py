"""
api/test_stroke_with_skins.py
-----------------------------
**A tournament round is scored on the tournament's method, and its own
`active_games` does not say so.**

An individual-play tournament sets `scoring_method` once. The ROUND carries
only its side games — so a stroke-play round with a Multi-Group Skins pool
stores `['multi_skins']`, and anything that asks the round what it is playing
is told "a skins pool".

The LEADERBOARD never had this problem: it emits the Stroke Play block for
every individual-ball round whatever `active_games` says. **Score entry did**,
which is how a tournament called "Stroke With Skins" got the pool's standings
card, the pool as its primary game, and no stroke-play entry at all — no
keypad, no hole tray, no ribbon (Paul, 4 Nov 2026).
"""
from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import User
from games.models import MultiSkinsGame
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee,
    make_tournament, submit_hole,
)
from services.low_net_round import (
    plays_low_net_round, stroke_play_hole_card, unstated_scoring_game,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}


class _Base(TestCase):
    def setUp(self):
        self.course = make_course()
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)

    def tourn_round(self, *, games=None, scoring='stroke',
                    tourn_games=None, groups=2):
        t = make_tournament(name='Stroke With Skins', total_rounds=1,
                            scoring_method=scoring,
                            active_games=tourn_games or ['low_net'])
        r = make_round(course=self.course, tournament=t,
                       active_games=games if games is not None
                       else ['multi_skins'])
        names = [('Ann', 8), ('Bea', 12), ('Cal', 16), ('Dee', 20)]
        self.groups = [
            make_foursome(r, [(f'{n}{i}', h) for n, h in names],
                          tee=self.tee, group_number=i + 1)
            for i in range(groups)
        ]
        return r

    def casual_round(self, games):
        return make_round(course=self.course, active_games=games)

    def play(self, fs, holes):
        pids = [m.player_id for m in fs.memberships.order_by('id')]
        for h in holes:
            submit_hole(fs, h, [(p, PAR[h]) for p in pids])


class UnstatedScoringGameTests(_Base):
    def test_a_stroke_tournament_round_is_scored_on_stroke_play(self):
        r = self.tourn_round()
        self.assertEqual(unstated_scoring_game(r), 'low_net_round')

    def test_a_stableford_tournament_round_is_scored_on_stableford(self):
        r = self.tourn_round(scoring='stableford')
        self.assertEqual(unstated_scoring_game(r), 'stableford')

    def test_a_round_that_already_names_it_has_nothing_unstated(self):
        """The whole point of the name: it answers what is MISSING."""
        r = self.tourn_round(games=['low_net_round', 'multi_skins'])
        self.assertIsNone(unstated_scoring_game(r))

    def test_a_casual_round_is_left_alone(self):
        """A casual round that plays stroke play puts it in `active_games`,
        and that path works — this must not start answering for it."""
        self.assertIsNone(
            unstated_scoring_game(self.casual_round(['multi_skins'])))
        self.assertIsNone(
            unstated_scoring_game(self.casual_round(['low_net_round'])))

    def test_a_cup_keeps_its_own_per_round_scoring(self):
        r = self.tourn_round(tourn_games=['team_cup'])
        self.assertIsNone(unstated_scoring_game(r))

    def test_foursome_play_scores_a_team_not_a_golfer(self):
        r = self.tourn_round(tourn_games=['team_play'])
        self.assertIsNone(unstated_scoring_game(r))

    def test_a_team_ball_round_has_no_individual_score_to_be_scored_on(self):
        """The same exclusion the board's Stroke Play tab makes: in alt-shot
        or a scramble no golfer has a ball of his own."""
        for g in ('triple_cup', 'scramble'):
            self.assertIsNone(
                unstated_scoring_game(self.tourn_round(games=[g])), g)

    def test_plays_low_net_round_covers_both_routes(self):
        self.assertTrue(plays_low_net_round(self.tourn_round()))
        self.assertTrue(
            plays_low_net_round(self.casual_round(['low_net_round'])))
        self.assertFalse(
            plays_low_net_round(self.casual_round(['multi_skins'])))
        self.assertFalse(
            plays_low_net_round(self.tourn_round(scoring='stableford')))


class TheHoleCardShipsTests(_Base):
    """The tray's card, which was `{}` on exactly this round."""

    def test_the_card_is_built_for_a_stroke_tournament_round(self):
        r = self.tourn_round()
        fs = self.groups[0]
        self.play(fs, [1, 2])
        card = stroke_play_hole_card(fs, 2)
        self.assertTrue(card, 'the tray had nothing to draw')
        self.assertEqual(card['hole'], 2)
        self.assertEqual(len(card['players']), 4)
        # And the standing is the one thing the engine does not answer: where
        # this hole left each golfer.
        self.assertEqual(len(card['standing']), 4)

    def test_the_tray_ships_it_with_the_save(self):
        r = self.tourn_round()
        fs = self.groups[0]
        self.play(fs, [1, 2])
        from api.views import _hole_tray_summaries
        out = _hole_tray_summaries(fs, 2)
        self.assertIn('stroke_play_hole', out)

    def test_a_casual_skins_pool_round_still_gets_nothing(self):
        r = self.casual_round(['multi_skins'])
        fs = make_foursome(r, [('Ann', 8), ('Bea', 12)], tee=self.tee)
        self.play(fs, [1])
        self.assertEqual(stroke_play_hole_card(fs, 1), {})

    def test_the_field_is_the_whole_round_not_the_card(self):
        """A place is about everybody. Two groups, and the leader line names
        a golfer who is not on this card."""
        r = self.tourn_round()
        self.play(self.groups[0], [1])
        pids = [m.player_id for m in self.groups[1].memberships.order_by('id')]
        submit_hole(self.groups[1], 1, [(p, PAR[1] - 1) for p in pids])
        card = stroke_play_hole_card(self.groups[0], 1)
        self.assertGreater(card['field'], 4)
        self.assertTrue(card['leader'])


class ThePayloadSaysSoTests(_Base):
    def setUp(self):
        super().setUp()
        self.user = User.objects.create_user(
            username='td', password='x', account=self.course.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def test_the_round_payload_names_the_scoring_game(self):
        r = self.tourn_round()
        resp = self.client.get(f'/api/rounds/{r.id}/')
        self.assertEqual(resp.data['scoring_game'], 'low_net_round')
        # And the games it is PLAYING are untouched — this is a separate
        # question from what somebody chose.
        self.assertEqual(resp.data['active_games'], ['multi_skins'])

    def test_a_casual_round_sends_null(self):
        r = self.casual_round(['multi_skins'])
        make_foursome(r, [('Ann', 8)], tee=self.tee)
        resp = self.client.get(f'/api/rounds/{r.id}/')
        self.assertIsNone(resp.data['scoring_game'])

    def test_a_stableford_tournament_round_names_stableford(self):
        r = self.tourn_round(scoring='stableford')
        resp = self.client.get(f'/api/rounds/{r.id}/')
        self.assertEqual(resp.data['scoring_game'], 'stableford')


class ThePoolIsStillThePoolTests(_Base):
    """Nothing here takes the skins pool away — it just stops owning entry."""

    def test_the_pool_still_scores_from_the_round_s_cards(self):
        r = self.tourn_round()
        ids = [m.player_id for m in self.groups[0].memberships.order_by('id')]
        from services.multi_skins import (calculate_multi_skins,
                                          multi_skins_summary,
                                          setup_multi_skins)
        setup_multi_skins(r, participant_ids=ids, handicap_mode='gross',
                          bet_unit=5)
        pids = ids
        submit_hole(self.groups[0], 1,
                    [(pids[0], 3), (pids[1], 4), (pids[2], 4), (pids[3], 4)])
        calculate_multi_skins(r)
        s = multi_skins_summary(r)
        won = {p['player_id']: p['skins_won'] for p in s['players']}
        self.assertEqual(won[pids[0]], 1)
        self.assertTrue(MultiSkinsGame.objects.filter(round=r).exists())
