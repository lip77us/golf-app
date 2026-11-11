"""
scoring/tests/test_stableford_hole_card.py
------------------------------------------
`services.stableford.stableford_hole_card` — what the Stableford score-entry
tray draws for ONE hole (`~/Downloads/handoff-stableford-score-entry`).

**Stableford score entry is Stroke Play score entry with points**, so the
card is the Stroke Play card's shape and the client draws it with the same
tray. These pin the points: the table, the pace, the places (higher first)
and the sentence that replaces the cap.

Set REGEN_STABLEFORD_FIXTURES=1 to rewrite the JSON `mobile/test` draws.
"""
import json
import os
import pathlib

from django.test import TestCase

from games.models import StablefordGame
from services.low_net_round import stroke_play_hole_card
from services.stableford import (
    stableford_hole_card, stableford_standings, _pts_text, _total_text,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

NAMES = ('Paul Lipkin', 'Dave Moran', 'Sam Reid', 'Mike Hale')
MODIFIED = dict(pts_albatross=8, pts_eagle=5, pts_birdie=2, pts_par=0,
                pts_bogey=-1, pts_double=-3)


class _Base(TestCase):
    mode = 'gross'
    table = {}
    handicaps = (0, 0, 0, 0)

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, active_games=['stableford'])
        self.fs = make_foursome(
            self.round, list(zip(NAMES, self.handicaps)), tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        StablefordGame.objects.create(
            round=self.round, handicap_mode=self.mode, net_percent=100,
            **self.table)

    def _par(self, hole):
        return self.tee.hole(hole)['par']

    def _hole(self, hole, over):
        """Post `over` strokes over par for Paul, Dave, Sam, Mike."""
        par = self._par(hole)
        submit_hole(self.fs, hole, [
            (self.pid[n.split()[0]], par + o) for n, o in zip(NAMES, over)])

    def _card(self, hole):
        return stableford_hole_card(self.fs, hole)

    @staticmethod
    def _row(card, first):
        return next(r for r in card['standing']
                    if r['name'].split()[0] == first)

    @staticmethod
    def _player(card, first):
        return next(p for p in card['players'] if p['first'] == first)


class ShapeTests(_Base):

    def test_the_card_is_the_stroke_play_shape(self):
        """One model and one tray on the client: a key the Stroke Play card
        carries and this does not would be read as missing."""
        self.round.active_games = ['stableford', 'low_net_round']
        self.round.save(update_fields=['active_games'])
        self._hole(1, (0, 0, 0, 0))
        sp = stroke_play_hole_card(self.fs, 1)
        st = self._card(1)
        assert set(sp) <= set(st)
        assert set(sp['players'][0]) <= set(st['players'][0])
        assert set(sp['standing'][0]) <= set(st['standing'][0])

    def test_a_card_before_anything_is_scored(self):
        card = self._card(1)
        assert card['points'] is True
        assert card['label'] == 'Stableford'
        assert card['table_label'] == 'standard points'
        assert card['cap'] is False
        assert len(card['players']) == 4
        assert all(p['points_text'] == '– pts' for p in card['players'])
        assert all(r['place'] is None for r in card['standing'])

    def test_no_stableford_no_card(self):
        self.round.active_games = ['skins']
        self.round.save(update_fields=['active_games'])
        assert self._card(1) == {}


class StandardTableTests(_Base):

    def test_points_follow_the_table(self):
        # Birdie 3, par 2, bogey 1, double 0.
        self._hole(1, (-1, 0, 1, 2))
        card = self._card(1)
        assert [(p['first'], p['points'], p['points_text'])
                for p in card['players']] == [
            ('Paul', 3, '3 pts'), ('Dave', 2, '2 pts'),
            ('Sam', 1, '1 pt'), ('Mike', 0, '0 pts')]
        assert [p['points_low'] for p in card['players']] == \
            [False, False, False, True]

    def test_the_tray_ranks_higher_points_first(self):
        self._hole(1, (-1, 0, 1, 2))
        card = self._card(1)
        assert [r['name'].split()[0] for r in card['standing']] == \
            ['Paul', 'Dave', 'Sam', 'Mike']
        assert [r['place_text'] for r in card['standing']] == \
            ['1', '2', '3', '4']
        assert [r['total_text'] for r in card['standing']] == \
            ['3', '2', '1', '0']

    def test_pace_is_the_par_value_of_the_table(self):
        """Two a hole on standard points: ahead, on it, behind."""
        self._hole(1, (-1, 0, 1, 2))
        card = self._card(1)
        assert [r['pace'] for r in card['standing']] == \
            ['ahead', 'on', 'behind', 'behind']

    def test_a_first_hole_has_no_place_to_have_moved_from(self):
        self._hole(1, (-1, 0, 1, 2))
        assert all(r['moved'] is None for r in self._card(1)['standing'])

    def test_places_gained_on_the_hole(self):
        self._hole(1, (-1, 0, 1, 2))     # Paul 3, Dave 2, Sam 1, Mike 0
        self._hole(2, (2, 0, 0, -2))     # Paul 0, Dave 2, Sam 2, Mike 4
        card = self._card(2)
        # Totals: Mike 4, Dave 4, Paul 3, Sam 3.
        assert self._row(card, 'Mike')['place_text'] == 'T1'
        assert self._row(card, 'Mike')['moved'] == 3
        assert self._row(card, 'Paul')['moved'] == -2
        assert self._row(card, 'Paul')['place_text'] == 'T3'

    def test_past_the_bottom_of_the_table_is_said_in_a_sentence(self):
        """No cap in Stableford: a 9 on a par 4 scores what a 6 would."""
        hole = next(h for h in range(1, 19) if self._par(h) == 4)
        par = 4
        submit_hole(self.fs, hole, [
            (self.pid['Paul'], par), (self.pid['Dave'], par),
            (self.pid['Sam'], par + 2), (self.pid['Mike'], 9)])
        card = stableford_hole_card(self.fs, hole)
        assert card['cap_notes'] == [
            'Mike’s 9 scores 0 pts, the same as a 6. The card keeps the 9.']
        # A 6 IS the bottom of the table: nothing to explain.
        assert self._player(card, 'Sam')['points'] == 0
        assert self._player(card, 'Mike')['gross'] == 9
        assert not any(p['capped'] for p in card['players'])

    def test_the_keypad_is_told_where_the_table_bottoms_out(self):
        hole = next(h for h in range(1, 19) if self._par(h) == 4)
        card = self._card(hole)
        assert self._player(card, 'Paul')['floor_text'] == '0 pts from 6'
        assert self._player(card, 'Paul')['cap_max'] is None

    def test_the_card_agrees_with_the_board(self):
        for h in (1, 2, 3):
            self._hole(h, (-1, 0, 1, 2))
        card = self._card(3)
        board = {r['player_id']: r['total_points']
                 for r in stableford_standings(self.round)}
        for r in card['standing']:
            assert r['total'] == board[r['player_id']]

    def test_the_last_hole_drops_the_arrows(self):
        for h in range(1, 19):
            self._hole(h, (-1, 0, 1, 2))
        card = self._card(18)
        assert card['final'] is True
        assert all(r['moved'] is None for r in card['standing'])


class ModifiedTableTests(_Base):
    table = MODIFIED

    def test_the_table_is_signed(self):
        self._hole(1, (-1, 0, 1, 2))
        card = self._card(1)
        assert card['table_label'] == 'Modified points'
        assert card['signed'] is True
        assert [p['points_text'] for p in card['players']] == \
            ['+2 pts', '0 pts', '−1 pts', '−3 pts']
        assert [r['total_text'] for r in card['standing']] == \
            ['+2', '0', '−1', '−3']

    def test_zero_or_worse_wears_the_bogey_tint(self):
        self._hole(1, (-1, 0, 1, 2))
        assert [p['points_low'] for p in self._card(1)['players']] == \
            [False, True, True, True]

    def test_pace_is_nothing_a_hole(self):
        self._hole(1, (-1, 0, 1, 2))
        assert [r['pace'] for r in self._card(1)['standing']] == \
            ['ahead', 'on', 'behind', 'behind']

    def test_the_floor_reads_without_a_unit(self):
        hole = next(h for h in range(1, 19) if self._par(h) == 4)
        assert self._player(self._card(hole), 'Paul')['floor_text'] == \
            '−3 from 6'


class NetTests(_Base):
    mode = 'net'
    handicaps = (0, 0, 18, 18)

    def test_a_stroke_moves_the_points_and_the_floor(self):
        """Sam and Mike get a shot a hole: a gross par is a net birdie."""
        hole = next(h for h in range(1, 19) if self._par(h) == 4)
        submit_hole(self.fs, hole, [(self.pid[n.split()[0]], 4)
                                    for n in NAMES])
        card = stableford_hole_card(self.fs, hole)
        assert card['show_net'] is True
        sam, paul = self._player(card, 'Sam'), self._player(card, 'Paul')
        assert (sam['strokes'], sam['net'], sam['points']) == (1, 3, 3)
        assert (paul['strokes'], paul['net'], paul['points']) == (0, 4, 2)
        assert sam['floor_text'] == '0 pts from 7'
        assert paul['floor_text'] == '0 pts from 6'

    def test_strokes_are_stated_before_a_score_is_entered(self):
        """The keypad is coded against par plus the strokes."""
        card = self._card(1)
        assert self._player(card, 'Sam')['strokes'] == 1
        assert self._player(card, 'Paul')['strokes'] == 0


class FieldTests(_Base):

    def test_the_leader_is_named_when_he_is_on_another_card(self):
        other = make_foursome(self.round, [('Ben Ortiz', 0)], tee=self.tee,
                              group_number=2)
        ben = other.memberships.first().player_id
        submit_hole(other, 1, [(ben, self._par(1) - 2)])     # an eagle: 4
        self._hole(1, (-1, 0, 1, 2))
        card = self._card(1)
        assert card['field'] == 5
        assert card['leader']['name'] == 'Ben Ortiz'
        assert card['leader']['text'] == '4 pts'
        # A place is in the FIELD: Paul's 3 is second behind Ben.
        assert self._row(card, 'Paul')['place_text'] == '2'

    def test_no_leader_line_when_he_is_on_this_card(self):
        self._hole(1, (-1, 0, 1, 2))
        assert self._card(1)['leader'] is None


class TextTests(TestCase):

    def test_points(self):
        assert [_pts_text(n, False) for n in (None, 0, 1, 3)] == \
            ['– pts', '0 pts', '1 pt', '3 pts']
        assert [_pts_text(n, True) for n in (2, 0, -1)] == \
            ['+2 pts', '0 pts', '−1 pts']

    def test_totals(self):
        assert [_total_text(n, False) for n in (0, 18)] == ['0', '18']
        assert [_total_text(n, True) for n in (4, 0, -9)] == ['+4', '0', '−9']


class FixtureRegenTests(_Base):
    OUT = pathlib.Path(__file__).resolve().parents[2] / 'mobile/test/fixtures'
    mode = 'net'
    handicaps = (0, 6, 12, 18)

    def _write(self, name, card):
        text = json.dumps(card, indent=2, ensure_ascii=False)
        for i, n in enumerate(NAMES, start=1):
            text = text.replace(f'"player_id": {self.pid[n.split()[0]]},',
                                f'"player_id": {300 + i},')
        if os.environ.get('REGEN_STABLEFORD_FIXTURES'):
            (self.OUT / name).write_text(text + '\n')
        assert card['players']

    def test_empty(self):
        self._write('stableford_hole1_empty.json', self._card(1))

    def test_tray(self):
        self._hole(1, (-1, 0, 1, 2))
        self._hole(2, (0, 1, 0, 5))
        self._write('stableford_hole2_tray.json', self._card(2))


class ModifiedFixtureTests(FixtureRegenTests):
    table = MODIFIED
    mode = 'gross'
    handicaps = (0, 0, 0, 0)

    def test_empty(self):
        pass

    def test_tray(self):
        self._hole(1, (-1, 0, 1, 2))
        self._hole(2, (0, 1, 0, 5))
        self._write('stableford_hole2_modified.json', self._card(2))
