"""
scoring/tests/test_wolf_scorecard_sides.py
------------------------------------------
The Wolf summary's `scorecard` block says which SIDE won each hole.

The scorecard moved from the play screen to the leaderboard on 10 Nov 2026
("keep the colors … add the gets"). On the play screen the phone decided the
tint, in `wolfWonTheHole`; the board draws through the shared scorecard, which
tints from two keys it already reads for Nassau and Fourball — `winner_team`
on the hole and `team` on the score. So the rule lives here now, and these are
its truth table.

`REGEN_WOLF_FIXTURES=1 manage.py test scoring.tests.test_wolf_scorecard_sides`
rewrites the JSON `mobile/test/wolf_scorecard_test.dart` draws.
"""
import json
import os

from services.wolf import wolf_hole_card, wolf_summary

from .test_wolf_hole_card import HOLE, _WolfCardBase


class _SidesBase(_WolfCardBase):

    def _hole(self, hole=HOLE):
        card = wolf_summary(self.fs)['scorecard']
        return next(h for h in card['holes'] if h['hole'] == hole)

    def _teams(self, hole=HOLE):
        names = {v: k for k, v in self.pid.items()}
        return {names[s['player_id']]: s['team']
                for s in self._hole(hole)['scores']}


class TheSideThatWonTests(_SidesBase):

    def test_the_wolf_s_side_wins(self):
        self._setup()
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        self._score(HOLE, paul=4, dave=5, sam=5, lee=6)
        self.assertEqual(self._hole()['winner_team'], 1)
        self.assertEqual(self._teams(),
                         {'Sam': 1, 'Paul': 1, 'Dave': 2, 'Lee': 2})

    def test_the_opponents_win(self):
        self._setup()
        self._decide(HOLE, 'lone')
        self._score(HOLE, paul=4, dave=5, sam=6, lee=6)
        self.assertEqual(self._hole()['winner_team'], 2)
        # A lone Wolf is a side of one.
        self.assertEqual(self._teams(),
                         {'Sam': 1, 'Paul': 2, 'Dave': 2, 'Lee': 2})

    def test_a_tie_marks_nobody(self):
        # Both sides drew it: tinting both would say two sides won.
        self._setup()
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        self._score(HOLE, paul=4, dave=4, sam=6, lee=6)
        self.assertIsNone(self._hole()['winner_team'])
        # The sides are still known — it is the WIN that is absent.
        self.assertEqual(self._teams()['Sam'], 1)

    def test_a_hole_with_no_result_marks_nobody_and_has_no_sides(self):
        self._setup()
        hole = self._hole()
        self.assertIsNone(hole['winner_team'])
        self.assertTrue(all(s['team'] is None for s in hole['scores']))

    def test_it_is_never_a_BALL_that_won(self):
        # Wolf marks a side, not a score — pointing at one cell would name a
        # man who may have been carried.
        self._setup()
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        self._score(HOLE, paul=4, dave=5, sam=5, lee=6)
        hole = self._hole()
        self.assertIsNone(hole['winner_id'])
        self.assertTrue(all('won' not in s for s in hole['scores']))


class TheSidesChangeEveryHoleTests(_SidesBase):

    def test_a_golfer_s_side_is_a_fact_about_the_hole(self):
        # Sam is the Wolf on the 9th and an opponent on the 10th, so `team`
        # is on the SCORE; on the golfer it could only be right for one.
        self._setup()
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        self._score(HOLE, paul=4, dave=5, sam=5, lee=6)
        self._decide(HOLE + 1, 'lone')            # Lee's hole
        self._score(HOLE + 1, paul=4, dave=4, sam=4, lee=9)
        self.assertEqual(self._teams(HOLE)['Sam'], 1)
        self.assertEqual(self._teams(HOLE + 1)['Sam'], 2)
        self.assertEqual(self._teams(HOLE + 1)['Lee'], 1)
        card = wolf_summary(self.fs)['scorecard']
        self.assertTrue(all('team' not in p for p in card['players']))


class TheWolfRowAndTheGetsTests(_SidesBase):

    def test_every_hole_names_its_wolf_before_it_is_played(self):
        # The rotation is known up front, and the hole in front of the group
        # is the one whose Wolf they are asking about.
        self._setup()
        card = wolf_summary(self.fs)['scorecard']
        self.assertTrue(all(h['wolf_short'] for h in card['holes'][:16]))
        self.assertEqual(self._hole()['wolf_short'],
                         self._hole()['wolf_short'].strip())

    def test_the_players_carry_what_they_get(self):
        # Off the low man: Paul 0, Dave 4, Sam 7, Lee 10.
        self._setup()
        names = {v: k for k, v in self.pid.items()}
        gets = {names[p['player_id']]: p['phcp_in_play']
                for p in wolf_summary(self.fs)['scorecard']['players']}
        self.assertEqual(gets, {'Paul': 0, 'Dave': 4, 'Sam': 7, 'Lee': 10})


class WolfFixtureRegenTests(_SidesBase):
    """Three holes — the Wolf's side wins, the opponents win, a tie."""

    def test_regenerate_the_board_summary(self):
        self._setup()
        # 1st: Sam's hole, takes Paul, wins by a street.
        self._decide(1, 'partner', partner=self.pid['Paul'])
        self._score(1, paul=3, dave=7, sam=3, lee=7)
        # 2nd: Lee's hole, goes alone, loses by a street.
        self._decide(2, 'lone')
        self._score(2, paul=4, dave=4, sam=4, lee=9)
        # 3rd: Paul's hole, takes Dave, and the best balls tie — built from
        # the engine's own strokes so it stays a tie whatever the card is.
        self._decide(3, 'partner', partner=self.pid['Dave'])
        strokes = {p['player_id']: p['strokes']
                   for p in wolf_hole_card(self.fs, 3)['players']}
        self._score(3, paul=4 + strokes[self.pid['Paul']], dave=9,
                    sam=4 + strokes[self.pid['Sam']], lee=9)

        summary = wolf_summary(self.fs)
        by = {h['hole']: h['winner_team']
              for h in summary['scorecard']['holes']}
        self.assertEqual((by[1], by[2], by[3], by[4]), (1, 2, None, None))

        if os.environ.get('REGEN_WOLF_FIXTURES') != '1':
            return
        path = os.path.join(os.path.dirname(__file__), '..', '..', 'mobile',
                            'test', 'fixtures', 'wolf_board_summary.json')
        with open(path, 'w') as f:
            json.dump(summary, f, indent=1, sort_keys=True, default=str)
