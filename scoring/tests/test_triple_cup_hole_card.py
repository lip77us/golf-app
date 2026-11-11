"""
scoring/tests/test_triple_cup_hole_card.py
------------------------------------------
`services.triple_cup.triple_cup_hole_card` — what the score-entry tray draws
for ONE hole (`~/Downloads/handoff-for-code 24/handoff-triple-cup-score-entry`).

The handoff's worked example is played through the real engine, in gross off
scratch so every result is arithmetic rather than a handicap calculation:

* Fourball   A, halved, B, A, halved, A      → Paul + Hal win 2 UP.   1–0
* Foursomes  halved, halved, A, B, A, B      → halved.                1½–½
* Singles    Paul v Pete  B, h, A, A, h, A   → Paul wins 2 UP
             Hal v Wendy  A, A, h, h, B, h   → Hal wins 1 UP.         3½–½

Set REGEN_TC_FIXTURES=1 to rewrite the JSON `mobile/test` draws, so the tray
is tested against what the server really sends.
"""
import json
import os
import pathlib

from django.test import TestCase

from services.triple_cup import (
    setup_triple_cup, calculate_triple_cup, triple_cup_hole_card,
    triple_cup_summary, _tc_pts, _tc_cup_line,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

NAMES = ('Paul Lipkin', 'Hal Hacker', 'Pete Player', 'Wendy Weekender')

# Who wins each hole, as the handoff writes it: A = Team 1, B = Team 2.
FOURBALL  = 'AhBAhA'
FOURSOMES = 'hhABAB'
SINGLES_1 = 'BhAAhA'      # Paul v Pete
SINGLES_2 = 'AAhhBh'      # Hal v Wendy


class _CardBase(TestCase):
    stake = 25

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.round.bet_unit = self.stake
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round, [(n, 0) for n in NAMES], tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_triple_cup(
            self.fs,
            team1_ids=[self.pid['Paul'], self.pid['Hal']],
            team2_ids=[self.pid['Pete'], self.pid['Wendy']],
            handicap_mode='gross',
        )

    # -- play ---------------------------------------------------------------

    def _par(self, hole):
        return self.tee.hole(hole)['par']

    def _pair(self, a, b, letter, par):
        """(score for a, score for b) so that `letter` describes the hole."""
        return {'A': (par, par + 1), 'B': (par + 1, par),
                'h': (par, par)}[letter]

    def _play(self, thru):
        """Post holes 1..thru of the worked example and recalculate."""
        p = self.pid
        for hole in range(1, thru + 1):
            par = self._par(hole)
            if hole <= 6:
                a, b = self._pair('t1', 't2', FOURBALL[hole - 1], par)
                scores = [(p['Paul'], a), (p['Hal'], a + 1),
                          (p['Pete'], b), (p['Wendy'], b + 1)]
            elif hole <= 12:
                # One ball a side: one partner posts it.
                a, b = self._pair('t1', 't2', FOURSOMES[hole - 7], par)
                scores = [(p['Paul'], a), (p['Pete'], b)]
            else:
                a, b = self._pair('paul', 'pete', SINGLES_1[hole - 13], par)
                c, d = self._pair('hal', 'wendy', SINGLES_2[hole - 13], par)
                scores = [(p['Paul'], a), (p['Pete'], b),
                          (p['Hal'], c), (p['Wendy'], d)]
            submit_hole(self.fs, hole, scores)
        calculate_triple_cup(self.fs)

    def _card(self, hole, thru=None):
        self._play(hole if thru is None else thru)
        return triple_cup_hole_card(self.fs, hole)


class ShapeTests(_CardBase):

    def test_no_game_no_card(self):
        other = make_foursome(self.round, [('X', 0), ('Y', 0)],
                              tee=self.tee, group_number=2)
        assert triple_cup_hole_card(other, 1) == {}

    def test_a_card_before_anything_is_scored(self):
        """Gated on the GAME, not its status: no card means no keypad."""
        card = triple_cup_hole_card(self.fs, 1)
        assert card['hole'] == 1
        assert card['hole_complete'] is False
        assert [r['first'] for r in card['players']] == \
            ['Paul', 'Hal', 'Pete', 'Wendy']
        line = card['lines'][0]
        assert line['played'] is False
        assert line['margin'] == 'AS'
        assert line['sub'] == 'holes 1–6'
        assert all(t['state'] == 'open' for t in line['tiles'])

    def test_a_hole_outside_the_round_has_no_card(self):
        assert triple_cup_hole_card(self.fs, 19) == {}

    def test_the_segment_names_itself(self):
        card = self._card(4)
        assert card['segment'] == 'fourball'
        assert card['segment_label'] == 'Fourball'
        assert card['span'] == 'holes 1–6'
        assert card['kind'] == 'best ball'
        assert (card['hole_in_segment'], card['segment_holes']) == (4, 6)
        assert card['tournament'] is False
        assert card['team_names'] == ['Team 1', 'Team 2']

    def test_one_line_in_the_fourball_and_two_in_the_singles(self):
        assert len(self._card(4)['lines']) == 1
        card = triple_cup_hole_card(self.fs, 13)
        assert len(card['lines']) == 2
        assert card['kind'] == 'singles'
        assert card['segment_label'] == 'Singles'
        # Six tiles a match would double the tray.
        assert card['show_tiles'] is False


class FourballTests(_CardBase):

    def test_the_hole_line(self):
        card = self._card(1)
        line = card['lines'][0]
        assert line['names'] == ['Paul + Hal', 'Pete + Wendy']
        assert line['played'] is True
        assert line['winner'] == 1
        par = self._par(1)
        assert line['reason'] == {'label': 'net', 'team1': par,
                                  'team2': par + 1}
        assert card['hole_complete'] is True

    def test_a_halved_hole_names_no_winner(self):
        line = self._card(2)['lines'][0]
        assert line['winner'] is None
        assert line['played'] is True
        assert line['head'] == 'Paul + Hal'       # still 1 UP from the 1st
        assert line['margin'] == '1 UP'
        assert line['sub'] == 'thru 2 of 6 · 4 to play'

    def test_all_square_after_the_third(self):
        line = self._card(3)['lines'][0]
        assert line['winner'] == 2
        assert (line['leader'], line['head'], line['margin']) == \
            (None, 'All square', 'AS')

    def test_the_tiles_follow_the_holes_won(self):
        line = self._card(4)['lines'][0]
        assert [t['state'] for t in line['tiles']] == \
            ['t1', 'halved', 't2', 't1', 'open', 'open']

    def test_the_fourball_ends_two_up(self):
        card = self._card(6)
        line = card['lines'][0]
        assert line['decided'] is True
        assert line['head'] == 'Paul + Hal win'
        assert line['margin'] == '2 UP'           # went the distance: no `&0`
        assert line['sub'] == '1 point to Team 1'
        assert (card['cup']['team1'], card['cup']['team2']) == ('1', '0')
        assert card['cup']['line'] == '3 points still out · 2½ wins'

    def test_the_next_segment_is_named_on_its_last_hole_only(self):
        assert self._card(5)['next'] is None
        nxt = triple_cup_hole_card(self.fs, 6)['next']
        self._play(6)
        nxt = triple_cup_hole_card(self.fs, 6)['next']
        assert nxt['label'] == 'Foursomes'
        assert nxt['span'] == 'holes 7–12'
        assert nxt['title'] == 'One ball a side from 7'
        assert nxt['button'] == 'Foursomes · hole 7'
        assert nxt['hole'] == 7

    def test_no_money_before_the_last_hole(self):
        assert self._card(6)['money'] is None


class FoursomesTests(_CardBase):

    def test_one_ball_a_side(self):
        card = self._card(8)
        assert card['kind'] == 'one ball a side'
        line = card['lines'][0]
        assert line['winner'] is None
        assert line['margin'] == 'AS'
        assert line['sub'] == 'thru 2 of 6 · 4 to play'
        # One partner posted the side's ball, and the hole is complete.
        assert card['hole_complete'] is True
        assert [t['state'] for t in line['tiles']] == \
            ['halved', 'halved', 'open', 'open', 'open', 'open']

    def test_a_halved_match_is_half_a_point_each(self):
        card = self._card(12)
        line = card['lines'][0]
        assert line['decided'] is True
        assert (line['head'], line['margin']) == ('Match halved', '½')
        assert line['sub'] == '½ point each'
        assert (card['cup']['team1'], card['cup']['team2']) == ('1½', '½')
        assert card['cup']['line'] == '2 points still out · 2½ wins'

    def test_into_the_singles(self):
        nxt = self._card(12)['next']
        assert nxt['label'] == 'Singles'
        assert nxt['title'] == 'Paul v Pete · Hal v Wendy'
        assert nxt['body'] == ('Two matches, 2 points, played together. '
                               '2½ wins the cup.')
        assert nxt['button'] == 'Singles · hole 13'


class SinglesTests(_CardBase):

    def test_hole_16(self):
        """Phone 4: Paul 1 UP, Hal 2 UP, two points out."""
        card = self._card(16)
        a, b = card['lines']
        assert a['names'] == ['Paul', 'Pete']
        assert (a['head'], a['margin']) == ('Paul', '1 UP')
        assert a['sub'] == 'thru 4 of 6 · 2 to play'
        assert b['names'] == ['Hal', 'Wendy']
        assert (b['head'], b['margin']) == ('Hal', '2 UP')
        assert card['cup']['line'] == '2 points still out · 2½ wins'

    def test_a_single_golfer_wins_in_the_singular(self):
        card = self._card(18)
        a, b = card['lines']
        assert (a['head'], a['margin']) == ('Paul wins', '2 UP')
        assert (b['head'], b['margin']) == ('Hal wins', '1 UP')

    def test_the_cup_is_won(self):
        card = self._card(18)
        assert (card['cup']['team1'], card['cup']['team2']) == ('3½', '½')
        assert card['cup']['line'] == 'Team 1 wins the cup'
        assert card['last_hole'] is True
        assert card['round_over'] is True
        assert card['next'] is None

    def test_the_money_is_one_stake_a_man(self):
        """Decided 11 Nov 2026: settled the way Fourball settles — each
        winner nets one stake, never the $50 share of the pot."""
        money = self._card(18)['money']
        assert money['label'] == 'Final · winners take all'
        assert money['stake'] == '$25 a man'
        assert money['winner'] == 1
        assert money['head'] == 'Paul & Hal'
        assert money['amount'] == '+$25 each'
        assert money['line'] == 'Pete and Wendy pay $25 each'

    def test_the_money_agrees_with_the_engine(self):
        self._play(18)
        by = {e['name']: e['amount']
              for e in triple_cup_summary(self.fs)['money']['by_player']}
        assert by == {'Paul Lipkin': 25.0, 'Hal Hacker': 25.0,
                      'Pete Player': -25.0, 'Wendy Weekender': -25.0}


class CloseOutTests(_CardBase):
    """A match closed early leaves dead holes — and the OTHER single plays
    on, which is the one place two lines on a hole disagree about it."""

    def _play_out(self):
        self._play(12)
        p = self.pid
        for hole in range(13, 19):
            par = self._par(hole)
            # Paul wins 13–16 (4&2). Hal and Wendy halve everything.
            paul = par - 1 if hole <= 16 else par
            submit_hole(self.fs, hole, [
                (p['Paul'], paul), (p['Pete'], par),
                (p['Hal'], par), (p['Wendy'], par)])
        calculate_triple_cup(self.fs)

    def test_the_close_out_is_the_engines(self):
        self._play_out()
        a, b = triple_cup_hole_card(self.fs, 16)['lines']
        assert (a['head'], a['margin']) == ('Paul wins', '4&2')
        assert a['sub'] == '1 point to Team 1 · 17–18 dead'
        assert [t['state'] for t in a['tiles']] == \
            ['t1', 't1', 't1', 't1', 'dead', 'dead']
        assert b['margin'] == 'AS'

    def test_a_dead_hole_still_completes(self):
        self._play_out()
        card = triple_cup_hole_card(self.fs, 17)
        a, b = card['lines']
        assert (a['played'], a['dead']) == (False, True)
        assert a['reason'] is None
        assert b['played'] is True
        assert card['hole_complete'] is True

    def test_the_point_counts_from_the_hole_it_was_won(self):
        self._play_out()
        assert triple_cup_hole_card(self.fs, 15)['cup']['team1'] == '1½'
        assert triple_cup_hole_card(self.fs, 16)['cup']['team1'] == '2½'
        assert triple_cup_hole_card(self.fs, 16)['cup']['line'] == \
            'Team 1 has won it · 1 still to play out'


class AsOfTheHoleTests(_CardBase):
    """A tray reopened on an early hole reports the round as it stood THERE
    — the Points tray's bug, where the 2nd showed the 18th's figures."""

    def test_the_cup_as_of_the_fourth(self):
        self._play(18)
        card = triple_cup_hole_card(self.fs, 4)
        assert (card['cup']['team1'], card['cup']['team2']) == ('0', '0')
        assert card['cup']['line'] == '4 points still out · 2½ wins'
        assert card['money'] is None
        assert card['round_over'] is False

    def test_the_match_as_of_the_fourth(self):
        self._play(18)
        line = triple_cup_hole_card(self.fs, 4)['lines'][0]
        assert line['decided'] is False
        assert (line['head'], line['margin']) == ('Paul + Hal', '1 UP')
        assert line['sub'] == 'thru 4 of 6 · 2 to play'
        # Holes played later are not on this tray.
        assert [t['state'] for t in line['tiles']] == \
            ['t1', 'halved', 't2', 't1', 'open', 'open']

    def test_the_last_card_agrees_with_the_summary(self):
        self._play(18)
        card = triple_cup_hole_card(self.fs, 18)
        overall = triple_cup_summary(self.fs)['overall']
        assert card['cup']['team1_points'] == overall['team1_points']
        assert card['cup']['team2_points'] == overall['team2_points']


class HalvedCupTests(_CardBase):

    def test_a_halved_cup_says_so(self):
        """Not `$0`: nothing changes hands and the tray has to say it."""
        p = self.pid
        for hole in range(1, 19):
            par = self._par(hole)
            if 7 <= hole <= 12:
                scores = [(p['Paul'], par), (p['Pete'], par)]
            else:
                scores = [(x, par) for x in p.values()]
            submit_hole(self.fs, hole, scores)
        calculate_triple_cup(self.fs)
        card = triple_cup_hole_card(self.fs, 18)
        assert card['cup']['line'] == \
            'Cup halved, 2–2 · nothing changes hands'
        assert card['money']['line'] == 'Cup halved · no money changes hands'
        assert card['money']['winner'] is None
        assert card['money']['amount'] == ''

    def test_played_for_nothing_has_no_money_block(self):
        self.round.bet_unit = 0
        self.round.save(update_fields=['bet_unit'])
        assert self._card(18)['money'] is None


class CupLineTests(TestCase):
    """The one line under the strip, as pure cases."""

    N = ['Team 1', 'Team 2']

    def test_points(self):
        assert [_tc_pts(x) for x in (0, 0.5, 1, 1.5, 12.5)] == \
            ['0', '½', '1', '1½', '12½']

    def test_still_out(self):
        assert _tc_cup_line(0, 0, 4, self.N, group=False) == \
            '4 points still out · 2½ wins'
        assert _tc_cup_line(1.5, 1.5, 4, self.N, group=False) == \
            '1 point still out · 2½ wins'

    def test_cannot_lose(self):
        assert _tc_cup_line(2, 1, 4, self.N, group=False) == \
            'Team 1 cannot lose · 2–2 halves it'
        assert _tc_cup_line(1, 2, 4, self.N, group=False) == \
            'Team 2 cannot lose · 2–2 halves it'

    def test_won_with_points_out(self):
        assert _tc_cup_line(2.5, 0.5, 4, self.N, group=False) == \
            'Team 1 has won it · 1 still to play out'

    def test_final(self):
        assert _tc_cup_line(3, 1, 4, self.N, group=False) == \
            'Team 1 wins the cup'
        assert _tc_cup_line(2, 2, 4, self.N, group=False) == \
            'Cup halved, 2–2 · nothing changes hands'

    def test_a_group_never_claims_the_cup(self):
        """In a team cup these four points are a share of twenty-four."""
        n = ['Blue Team', 'Red Team']
        assert _tc_cup_line(1, 0, 4, n, group=True) == \
            '3 points still out in this group'
        assert _tc_cup_line(2.5, 0.5, 4, n, group=True) == \
            '1 point still out in this group'
        assert _tc_cup_line(3.5, 0.5, 4, n, group=True) == \
            'Group final · Blue Team 3½, Red Team ½'


class TeamCupTests(TestCase):
    """The same card inside a tournament cup: no money, the group's own four
    points labelled as the group's, and the whole cup beside them."""

    def setUp(self):
        from .test_live_activity_triple_cup import _TeamCupBase
        self.base = _TeamCupBase('setUp')
        self.base.setUp()
        self.fs = self.base.fs

    def test_the_group_and_the_cup_are_two_cards(self):
        self.base._sweep(self.base.groups[0], range(1, 7))
        card = triple_cup_hole_card(self.fs, 6)
        assert card['tournament'] is True
        assert card['team_names'] == ['Blue', 'Orange']
        assert card['team_colours'] == ['blue', 'orange']
        assert card['cup']['label'] == 'This group'
        assert card['cup']['line'] == '3 points still out in this group'
        total = card['cup_total']
        assert total['name'] == 'Cup'
        assert (total['team1'], total['team2']) == ('1', '0')
        assert total['total'] == 8.0
        assert total['to_win'] == '4½ to win'
        assert total['line'].startswith('Blue need 3½ more, Orange 4½')
        assert 'still out' in total['line']

    def test_no_money_in_a_team_cup(self):
        self.base.round.bet_unit = 25
        self.base.round.save(update_fields=['bet_unit'])
        self.base._sweep(self.base.groups[0], range(1, 19))
        card = triple_cup_hole_card(self.fs, 18)
        assert card['money'] is None
        assert card['cup']['line'].startswith('Group final · Blue ')

    def test_a_casual_cup_has_no_cup_total(self):
        tee = make_tee()
        rnd = make_round(tee.course, handicap_mode='gross')
        fs = make_foursome(rnd, [(n, 0) for n in NAMES], tee=tee)
        ids = [m.player_id for m in fs.memberships.all()]
        setup_triple_cup(fs, team1_ids=ids[:2], team2_ids=ids[2:],
                         handicap_mode='gross')
        assert triple_cup_hole_card(fs, 1)['cup_total'] is None


class FoursomesStrokesTests(TestCase):
    """In the Foursomes the dots are the SIDE's strokes: one ball, one
    allocation, on both partners' rows."""

    def test_both_partners_carry_the_sides_strokes(self):
        tee = make_tee()
        rnd = make_round(tee.course)
        fs = make_foursome(
            rnd, [('Ann A', 0), ('Bob B', 0), ('Cat C', 10), ('Dan D', 30)],
            tee=tee)
        ids = [m.player_id for m in fs.memberships.all()]
        setup_triple_cup(fs, team1_ids=ids[:2], team2_ids=ids[2:],
                         handicap_mode='net',
                         alt_shot_low_pct=50, alt_shot_high_pct=50)
        summary = triple_cup_summary(fs)
        m = next(x for x in summary['matches'] if x['segment'] == 'foursomes')
        cat, dan = ids[2], ids[3]
        total = 0
        for h in m['holes']:
            card = triple_cup_hole_card(fs, h['hole'])
            by = {r['player_id']: r['strokes'] for r in card['players']}
            assert by[cat] == by[dan] == h['t2_team_strokes'], h['hole']
            total += by[cat]
        # 10 and 30 at 50/50 is twenty strokes a side over the round, so
        # the six holes carry some: a card of zeros would pass the line above.
        assert total > 0


class FixtureRegenTests(_CardBase):
    """Writes the JSON `mobile/test/triple_cup_entry_test.dart` draws."""

    OUT = pathlib.Path(__file__).resolve().parents[2] / 'mobile/test/fixtures'

    def _write(self, name, card):
        if os.environ.get('REGEN_TC_FIXTURES'):
            (self.OUT / name).write_text(
                json.dumps(card, indent=2, ensure_ascii=False) + '\n')
        assert card['lines']

    def test_fourball_ends(self):
        self._write('triple_cup_hole6_fourball_ends.json', self._card(6))

    def test_foursomes(self):
        self._write('triple_cup_hole8_foursomes.json', self._card(8))

    def test_singles(self):
        self._write('triple_cup_hole16_singles.json', self._card(16))

    def test_round_over(self):
        self._write('triple_cup_hole18_round_over.json', self._card(18))

    def test_empty(self):
        self._write('triple_cup_hole1_empty.json',
                    triple_cup_hole_card(self.fs, 1))


class BoardTests(_CardBase):
    """`triple_cup_board` — what the leaderboard's TripleCupBoard draws."""

    def _board(self, thru):
        from services.triple_cup import triple_cup_board
        self._play(thru)
        return triple_cup_board(self.fs)

    def test_nothing_played(self):
        b = self._board(0)
        assert b['thru'] == 0 and b['over'] is False
        assert b['cup']['label'] == 'The cup'
        assert b['cup']['right'] == '0 of 4 decided'
        assert [x['tag'] for x in b['blocks']] == ['to come'] * 3
        assert b['blocks'][2]['lines'][0]['sub'] == 'starts 13'

    def test_thru_nine(self):
        b = self._board(9)
        assert b['cup']['label'] == 'The cup · thru 9'
        assert b['cup']['right'] == '1 of 4 decided'
        assert (b['cup']['team1'], b['cup']['team2']) == ('1', '0')
        assert [x['label'] for x in b['blocks']] == \
            ['Fourball', 'Foursomes', 'Singles']
        assert [x['tag'] for x in b['blocks']] == \
            ['final', 'playing', 'to come']
        assert b['blocks'][0]['sub'] == 'holes 1–6 · better ball'
        assert b['blocks'][1]['sub'] == 'holes 7–12 · alternate shot'
        fb = b['blocks'][0]['lines'][0]
        assert (fb['head'], fb['margin']) == ('Paul + Hal win', '2 UP')
        fs = b['blocks'][1]['lines'][0]
        assert (fs['head'], fs['margin']) == ('Paul + Hal', '1 UP')
        assert fs['sub'] == 'thru 3 of 6 · 3 to play'

    def test_the_singles_block_carries_both_matches(self):
        b = self._board(16)
        singles = b['blocks'][2]
        assert singles['tag'] == 'playing'
        assert [l['names'] for l in singles['lines']] == \
            [['Paul', 'Pete'], ['Hal', 'Wendy']]
        assert all(len(l['tiles']) == 6 for l in singles['lines'])

    def test_money_is_one_line_while_live(self):
        m = self._board(9)['money']
        assert m['final'] is False
        assert m['line'] == ('Winners take all. $25 a man, settled on the '
                             'cup when the last match ends.')
        assert m['pot'] == '$100'
        assert m['amount'] == ''

    def test_the_finish(self):
        b = self._board(18)
        assert b['over'] is True
        assert b['cup']['right'] == 'Round over'
        assert b['cup']['label'] == 'The cup'
        assert b['cup']['line'] == 'Team 1 wins the cup'
        assert [x['tag'] for x in b['blocks']] == ['final'] * 3
        m = b['money']
        assert m['final'] is True
        assert (m['head'], m['amount']) == ('Paul & Hal', '+$25 each')

    def test_the_last_tray_and_the_board_agree(self):
        """One writer, so they cannot say one match two ways."""
        from services.triple_cup import triple_cup_board
        self._play(18)
        card = triple_cup_hole_card(self.fs, 18)
        board = triple_cup_board(self.fs)
        tray = {l['match_number']: (l['head'], l['margin'], l['sub'])
                for l in card['lines']}
        for block in board['blocks']:
            for l in block['lines']:
                if l['match_number'] in tray:
                    assert tray[l['match_number']] == \
                        (l['head'], l['margin'], l['sub'])
        assert card['cup']['team1'] == board['cup']['team1']
        assert card['cup']['line'] == board['cup']['line']

    def test_thru_counts_holes_played_not_the_hole_number(self):
        """The shotgun shape: thru is a count along the play order."""
        from services.triple_cup import triple_cup_board
        p = self.pid
        submit_hole(self.fs, 1, [(x, 4) for x in p.values()])
        calculate_triple_cup(self.fs)
        assert triple_cup_board(self.fs)['thru'] == 1


class WinningBallTests(_CardBase):
    """The summary marks the BALL that won a hole, so a scorecard tints one
    cell rather than a whole side."""

    def _scores(self, hole):
        self._play(18)
        s = triple_cup_summary(self.fs)
        m = next(x for x in s['matches']
                 if any(h['hole'] == hole for h in x['holes']))
        h = next(h for h in m['holes'] if h['hole'] == hole)
        name = {v: k for k, v in self.pid.items()}
        return {name[sc['player_id']]: sc['won'] for sc in h['scores']}

    def test_the_better_ball_of_the_side_that_won(self):
        # Hole 1: Team 1 wins on Paul's par; Hal is one worse.
        assert self._scores(1) == {'Paul': True, 'Hal': False,
                                   'Pete': False, 'Wendy': False}

    def test_a_halved_hole_marks_nobody(self):
        assert not any(self._scores(2).values())

    def test_side_two_winning_marks_its_ball(self):
        assert self._scores(3) == {'Paul': False, 'Hal': False,
                                   'Pete': True, 'Wendy': False}


class BoardOnTheLeaderboardTests(_CardBase):

    def test_each_group_carries_its_board(self):
        from api.views import _build_leaderboard
        self.round.active_games = ['triple_cup']
        self.round.save(update_fields=['active_games'])
        self._play(9)
        lb = _build_leaderboard(self.round)
        games = lb.get('games', lb)
        group = games['triple_cup']['by_group'][0]
        assert group['board']['cup']['right'] == '1 of 4 decided'
        assert group['summary']['matches']


class BoardFixtureRegenTests(_CardBase):
    """Writes the JSON `mobile/test/triple_cup_board_test.dart` draws: the
    leaderboard GROUP (summary + board), as the app receives it."""

    OUT = pathlib.Path(__file__).resolve().parents[2] / 'mobile/test/fixtures'

    def _write(self, name, thru):
        from services.triple_cup import triple_cup_board
        self._play(thru)
        summary = triple_cup_summary(self.fs)
        group = {'foursome_id': self.fs.id, 'group_number': 1,
                 'summary': summary,
                 'board': triple_cup_board(self.fs, summary)}
        # Player ids vary with the test database; pin them so the fixture
        # only changes when the payload does.
        text = json.dumps(group, indent=2, ensure_ascii=False, default=str)
        for i, pid in enumerate(self.pid.values(), start=1):
            text = text.replace(f'"player_id": {pid},',
                                f'"player_id": {100 + i},')
        if os.environ.get('REGEN_TC_FIXTURES'):
            (self.OUT / name).write_text(text + '\n')
        assert group['board']['blocks']

    def test_thru_9(self):
        self._write('triple_cup_group_thru9.json', 9)

    def test_thru_14(self):
        self._write('triple_cup_group_thru14.json', 14)

    def test_final(self):
        self._write('triple_cup_group_final.json', 18)
