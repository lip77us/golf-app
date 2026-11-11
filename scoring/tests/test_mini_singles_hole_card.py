"""
scoring/tests/test_mini_singles_hole_card.py
--------------------------------------------
`services.tournament_match_play.mini_singles_hole_card` — what the Mini
Singles score-entry tray draws for ONE hole
(`~/Downloads/handoff-mini-singles-score-entry`, 11 Nov 2026).

The handoff's worked example, played through the real bracket engine in
gross so every result is arithmetic:

* Semi 1  Paul v Lee   Paul 2 up with 1 to play after 8         → Paul 2&1
* Semi 2  Dave v Sam   Dave 1 up after 8, Sam wins 9            → level, plays on
* 10      Dave and Sam halve; Paul and Lee each go 1 UP v TBD
* 11      Sam wins the hole and the semi
* Finals  Paul v Sam   Paul 3&2 on 16
* 3rd     Lee v Dave   halved on 18

Set REGEN_MS_FIXTURES=1 to rewrite the JSON `mobile/test` draws.
"""
import json
import os
import pathlib

from django.test import TestCase

from services.tournament_match_play import (
    setup_tournament_match_play, calculate_tournament_match_play,
    mini_singles_hole_card, tournament_match_play_summary,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole

# Strokes over par for (Paul, Dave, Sam, Lee) on each hole.
SCRIPT = {
    1: (0, 0, 1, 1),   # Paul +1 · Dave +1
    2: (0, 0, 0, 0),
    3: (0, 0, 0, 0),
    4: (0, 0, 0, 1),   # Paul +2
    5: (0, 0, 0, 0),
    6: (0, 0, 0, 0),
    7: (1, 0, 0, 0),   # Lee wins: Paul +1
    8: (0, 0, 0, 1),   # Paul 2 up with 1 to play — 2&1
    9: (0, 1, 0, 0),   # Sam wins: Semi 2 level after nine
    10: (0, 1, 1, 0),  # Dave and Sam halve; Paul and Lee 1 UP v TBD
    11: (0, 1, 0, 2),  # Sam wins the semi; Dave beats Lee
    12: (0, 1, 1, 1),  # Paul 2 UP; Lee and Dave halve
    13: (0, 0, 0, 0),
    14: (0, 0, 1, 0),  # Paul 3 UP
    15: (0, 0, 0, 0),
    16: (0, 0, 0, 0),  # 3 up with 2 to play — 3&2
    17: (0, 0, 0, 0),
    18: (0, 0, 0, 0),  # 3rd place halved
}
ORDER = ('Paul', 'Dave', 'Sam', 'Lee')


class _Base(TestCase):
    entry = 10
    payouts = {'1st': 24, '2nd': 10, '3rd': 6, '4th': 0}

    def setUp(self):
        self.tee = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross',
                                active_games=['match_play'])
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 8), ('Dave Moran', 11),
             ('Sam Reid', 14), ('Lee Naylor', 18)], tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_tournament_match_play(
            self.fs, entry_fee=self.entry, payout_config=self.payouts,
            handicap_mode='gross')

    def _play(self, thru, script=None):
        script = script or SCRIPT
        for hole in range(1, thru + 1):
            par = self.tee.hole(hole)['par']
            submit_hole(self.fs, hole, [
                (self.pid[n], par + over)
                for n, over in zip(ORDER, script[hole])])
        calculate_tournament_match_play(self.fs)

    def _card(self, hole, thru=None, script=None):
        self._play(hole if thru is None else thru, script)
        return mini_singles_hole_card(self.fs, hole)

    @staticmethod
    def _block(card, title):
        return next(b for b in card['blocks'] if b['title'] == title)


class ShapeTests(_Base):

    def test_a_card_before_anything_is_scored(self):
        """Gated on the BRACKET, not its status: no card means no keypad."""
        calculate_tournament_match_play(self.fs)
        card = mini_singles_hole_card(self.fs, 1)
        assert card['hole_complete'] is False
        assert [b['title'] for b in card['blocks']] == ['Semi 1', 'Semi 2']
        assert [b['names'] for b in card['blocks']] == \
            [['Paul', 'Lee'], ['Dave', 'Sam']]
        assert [p['first'] for p in card['players']] == list(
            ('Paul', 'Dave', 'Sam', 'Lee'))
        assert card['label'] == 'Hole 1 · semis'
        assert card['trailing'] == '$40 pot'

    def test_no_bracket_no_card(self):
        other = make_foursome(self.round, [('X', 0), ('Y', 0)],
                              tee=self.tee, group_number=2)
        assert mini_singles_hole_card(other, 1) == {}

    def test_a_hole_outside_the_round_has_no_card(self):
        calculate_tournament_match_play(self.fs)
        assert mini_singles_hole_card(self.fs, 19) == {}


class SemisTests(_Base):

    def test_hole_4(self):
        card = self._card(4)
        s1, s2 = card['blocks']
        assert (s1['winner'], s1['head'], s1['margin']) == (1, 'Paul', '2 UP')
        assert s1['sub'] == 'thru 4 of 9 · 5 to play'
        assert s1['reason']['label'] == 'net'
        assert (s2['winner'], s2['head'], s2['margin']) == \
            (None, 'Dave', '1 UP')
        assert [t['state'] for t in s1['tiles']] == \
            ['p1', 'halved', 'halved', 'p1'] + ['open'] * 5
        assert card['hole_complete'] is True

    def test_the_front_nine_carries_no_matchups_card(self):
        """It read the same on every hole and added nothing (Paul, 11 Nov
        2026). The back-nine pairings are named once, on the 9th."""
        assert 'matchups' not in self._card(4)

    def test_semi_1_closes_on_the_8th(self):
        card = self._card(8)
        s1 = self._block(card, 'Semi 1')
        assert (s1['head'], s1['margin']) == ('Paul wins', '2&1')
        assert s1['sub'] == \
            'Paul goes to the finals · hole 9 stroke play only'
        assert s1['decided'] is True
        assert s1['tiles'][-1]['state'] == 'dead'

    def test_a_match_already_over_is_one_line(self):
        card = self._card(9)
        s1 = self._block(card, 'Semi 1')
        assert s1['over_line'] == \
            'Paul won 2&1 · hole 9 is stroke play only'
        # …and the hole still completes on the match that IS live.
        assert card['hole_complete'] is True

    def test_a_semi_level_after_nine_plays_on(self):
        card = self._card(9)
        s2 = self._block(card, 'Semi 2')
        # Not `halved`: a semi has no such result. It is all square and
        # goes to extra holes.
        assert (s2['head'], s2['margin']) == ('All square after 9', 'AS')
        assert s2['sub'] == 'Semi 2 goes to extra holes from the 10th'
        assert 'halved' not in (s2['head'] + s2['sub']).lower()
        assert s2['decided'] is False
        nxt = card['next']
        assert nxt['title'] == 'Dave and Sam go to extra holes from 10'
        assert nxt['button'] == 'Back nine · hole 10'

    def test_no_next_card_before_the_ninth(self):
        assert self._card(8)['next'] is None


class PlayingOnTests(_Base):

    def test_the_extra_hole_is_still_level(self):
        card = self._card(10)
        assert [b['title'] for b in card['blocks']] == \
            ['Semi 2', 'Finals', '3rd place']
        s2 = self._block(card, 'Semi 2')
        assert (s2['head'], s2['margin']) == ('Still level', 'AS')
        assert s2['sub'] == ('Halved the 10th. The first hole either of '
                             'them wins settles it.')
        assert card['label'] == 'Hole 10 · back nine'

    def test_nobody_waits_the_finals_is_scored_against_tbd(self):
        card = self._card(10)
        f = self._block(card, 'Finals')
        assert f['tbd'] is True
        assert f['names'] == ['Paul', 'TBD']
        assert (f['head'], f['margin']) == ('Paul', '1 UP')
        t = self._block(card, '3rd place')
        assert t['names'] == ['Lee', 'TBD']
        assert (t['head'], t['margin']) == ('Lee', '1 UP')

    def test_the_semi_is_settled_on_the_11th(self):
        card = self._card(11)
        s2 = self._block(card, 'Semi 2')
        assert (s2['head'], s2['margin']) == ('Sam wins the semi', '11th')
        assert s2['sub'] == 'Level after 9, won on the 11th.'
        f = self._block(card, 'Finals')
        assert f['tbd'] is False
        assert f['names'] == ['Paul', 'Sam']
        assert (f['head'], f['margin']) == ('Paul', '1 UP')
        t = self._block(card, '3rd place')
        assert sorted(t['names']) == ['Dave', 'Lee']
        assert t['margin'] == 'AS'

    def test_the_semi_is_gone_from_the_12th(self):
        card = self._card(12)
        assert [b['title'] for b in card['blocks']] == ['Finals', '3rd place']
        f = self._block(card, 'Finals')
        assert (f['head'], f['margin']) == ('Paul', '2 UP')
        assert f['sub'] == 'thru 3 of 9 · 6 to play'


class BackNineTests(_Base):

    def test_the_finals_closes_three_and_two(self):
        card = self._card(16)
        f = self._block(card, 'Finals')
        assert (f['head'], f['margin']) == ('Paul wins', '3&2')
        assert f['sub'] == 'Paul 1st, Sam 2nd'

    def test_the_17th_is_stroke_play_only_for_the_finalists(self):
        card = self._card(17)
        f = self._block(card, 'Finals')
        assert f['over_line'] == \
            'Paul won 3&2 · hole 17 is stroke play only'
        assert card['hole_complete'] is True

    def test_the_group_is_over(self):
        card = self._card(18)
        assert card['round_over'] is True
        assert card['label'] == 'Round over'
        t = self._block(card, '3rd place')
        assert (t['head'], t['margin']) == ('3rd place halved', 'AS')
        assert t['sub'] == '3rd and 4th split'
        # The tray on 18 carries the money; the tiles are left out.
        assert all(b['tiles'] == [] for b in card['blocks'])
        assert card['winner'] == {'label': 'Group winner',
                                  'name': 'Paul Lipkin', 'line': ''}

    def test_the_money_is_net_of_the_entry(self):
        result = self._card(18)['result']
        assert result['label'] == 'Result'
        rows = {r['name'].split()[0]: (r['place'], r['amount'], r['tone'])
                for r in result['rows']}
        assert rows == {
            'Paul': ('1st', '+$14', 'up'),
            'Sam': ('2nd', '$0', 'level'),
            'Dave': ('T3', '−$7', 'dn'),
            'Lee': ('T3', '−$7', 'dn'),
        }
        assert [r['name'].split()[0] for r in result['rows']][:2] == \
            ['Paul', 'Sam']
        assert result['line'] == ('$24 / $10 / $6 on the $40 pot, 4th '
                                  'nothing. Net of the $10 entry.')

    def test_the_money_balances(self):
        self._play(18)
        from services.tournament_match_play import _bracket_money
        money = _bracket_money(self.fs, tournament_match_play_summary(self.fs))
        assert sum(money['paid'].values()) == 40.0

    def test_no_money_before_the_last_hole(self):
        card = self._card(16)
        assert card['result'] is None and card['winner'] is None

    def test_played_for_nothing_has_no_result_table(self):
        from games.models import MatchPlayBracket
        MatchPlayBracket.objects.filter(foursome=self.fs).update(
            entry_fee=0, payout_config={})
        card = self._card(18)
        assert card['result'] is None
        assert card['trailing'] == ''
        assert card['winner']['name'] == 'Paul Lipkin'


class AsOfTheHoleTests(_Base):
    """A tray reopened on an early hole reports the bracket as it stood."""

    def test_the_semi_as_of_the_fourth(self):
        self._play(18)
        card = mini_singles_hole_card(self.fs, 4)
        s1 = self._block(card, 'Semi 1')
        assert s1['decided'] is False
        assert (s1['head'], s1['margin']) == ('Paul', '2 UP')
        assert [t['state'] for t in s1['tiles']] == \
            ['p1', 'halved', 'halved', 'p1'] + ['open'] * 5
        assert card['result'] is None


class HalvedFinalsTests(_Base):

    def _script(self):
        s = dict(SCRIPT)
        # Finals Paul v Sam: 1 UP after 12 becomes level, then Paul takes
        # the 18th back... keep it halved overall: Sam wins 13 and 14, Paul
        # wins 17 and 18 from 1 down.
        s[12] = (0, 1, 0, 1)      # halved: Paul stays 1 UP
        s[13] = (1, 0, 0, 0)      # Sam: AS
        s[14] = (1, 0, 0, 0)      # Sam 1 UP
        s[15] = (0, 0, 0, 0)
        s[16] = (0, 0, 0, 0)
        s[17] = (0, 0, 0, 0)
        s[18] = (0, 0, 1, 0)      # Paul wins 18: halved
        return s

    def test_first_and_second_split_and_the_trophy_reads_the_last_hole(self):
        card = self._card(18, script=self._script())
        f = self._block(card, 'Finals')
        assert (f['head'], f['margin']) == ('Finals halved', 'AS')
        assert f['sub'] == '1st and 2nd split'
        w = card['winner']
        assert w['name'] == 'Paul Lipkin'
        assert w['line'] == (
            'Finals halved, so 1st and 2nd split. The trophy goes to Paul, '
            'who won the last hole that was not halved (the 18th).')
        rows = {r['name'].split()[0]: (r['place'], r['amount'])
                for r in card['result']['rows']}
        assert rows['Paul'] == ('T1', '+$7')
        assert rows['Sam'] == ('T1', '+$7')


class StrokesTests(TestCase):
    """A golfer's dots change at the turn, because his opponent does."""

    def test_strokes_follow_the_match_he_is_in(self):
        tee = make_tee()
        rnd = make_round(tee.course, active_games=['match_play'])
        fs = make_foursome(rnd, [('A A', 0), ('B B', 5), ('C C', 10),
                                 ('D D', 15)], tee=tee)
        pid = {m.player.name[0]: m.player_id for m in fs.memberships.all()}
        setup_tournament_match_play(fs)          # strokes off low, per pair
        calculate_tournament_match_play(fs)
        # Hole 5 is SI 1. Semi 1 is A v D: D gets 15, A none.
        by = {p['first']: p['strokes']
              for p in mini_singles_hole_card(fs, 5)['players']}
        assert by == {'A': 0, 'B': 0, 'C': 1, 'D': 1}
        # Hole 1 is SI 7: D (15) strokes, C (5 v B) does not.
        by = {p['first']: p['strokes']
              for p in mini_singles_hole_card(fs, 1)['players']}
        assert by == {'A': 0, 'B': 0, 'C': 0, 'D': 1}
        assert pid


class StrokesAtTheTurnTests(TestCase):
    """Strokes come off the low man of each PAIR, so they follow the match a
    golfer is in — and on an extra hole that is still his semi."""

    def setUp(self):
        self.tee = make_tee()
        rnd = make_round(self.tee.course, active_games=['match_play'])
        self.fs = make_foursome(
            rnd, [('A A', 0), ('B B', 5), ('C C', 10), ('D D', 15)],
            tee=self.tee)
        self.pid = {m.player.name[0]: m.player_id
                    for m in self.fs.memberships.all()}
        setup_tournament_match_play(self.fs)      # strokes off low, per pair
        # Semi 1 (A v D): A wins every hole. Semi 2 (B v C): C shoots one
        # over wherever he strokes, so every hole halves and it plays on.
        summary = tournament_match_play_summary(self.fs)
        semi2 = next(m for m in summary['matches'] if m['round'] == 1
                     and self.pid['C'] in (m['player1_id'], m['player2_id']))
        self.c_strokes = semi2['scorecard']['strokes_by_hole'][self.pid['C']]
        for hole in range(1, 10):
            par = self.tee.hole(hole)['par']
            submit_hole(self.fs, hole, [
                (self.pid['A'], par), (self.pid['D'], par + 3),
                (self.pid['B'], par),
                (self.pid['C'], par + self.c_strokes[hole])])
        calculate_tournament_match_play(self.fs)

    def _by(self, hole):
        return {p['first']: p for p in
                mini_singles_hole_card(self.fs, hole)['players']}

    def test_the_fixture_is_level_after_nine(self):
        card = mini_singles_hole_card(self.fs, 9)
        semi2 = next(b for b in card['blocks'] if b['title'] == 'Semi 2')
        assert semi2['head'] == 'All square after 9'

    def test_on_an_extra_hole_he_keeps_his_semis_strokes(self):
        # A back-nine hole where C strokes against B (the pair's five).
        hole = next(h for h in range(10, 19) if self.c_strokes[h])
        by = self._by(hole)
        assert by['C']['match'] == 'Semi 2'
        assert by['C']['strokes'] == self.c_strokes[hole] == 1
        assert by['B']['strokes'] == 0
        # …and the two who are through are already in their back-nine match.
        assert by['A']['match'] == 'Finals'
        assert by['D']['match'] == '3rd place'

    def test_d_strokes_less_on_the_back_than_against_the_scratch_man(self):
        """Fifteen off A on the front; off a five or a ten on the back."""
        front = sum(self._by(h)['D']['strokes'] for h in range(1, 10))
        back = sum(self._by(h)['D']['strokes'] for h in range(10, 19))
        assert front > back > 0


class FixtureRegenTests(_Base):
    OUT = pathlib.Path(__file__).resolve().parents[2] / 'mobile/test/fixtures'

    def _write(self, name, card):
        text = json.dumps(card, indent=2, ensure_ascii=False)
        for i, n in enumerate(ORDER, start=1):
            text = text.replace(f'"player_id": {self.pid[n]},',
                                f'"player_id": {200 + i},')
        if os.environ.get('REGEN_MS_FIXTURES'):
            (self.OUT / name).write_text(text + '\n')
        assert card['blocks']

    def test_semis(self):
        self._write('mini_singles_hole4_semis.json', self._card(4))

    def test_semi_closes(self):
        self._write('mini_singles_hole8_semi_closes.json', self._card(8))

    def test_semi_halved(self):
        self._write('mini_singles_hole9_semi_halved.json', self._card(9))

    def test_extra_hole(self):
        self._write('mini_singles_hole10_extra_hole.json', self._card(10))

    def test_semi_settled(self):
        self._write('mini_singles_hole11_semi_settled.json', self._card(11))

    def test_back_nine(self):
        self._write('mini_singles_hole12_back_nine.json', self._card(12))

    def test_group_over(self):
        self._write('mini_singles_hole18_group_over.json', self._card(18))


class TournamentMoneyTests(_Base):
    """The same card on both tournament days; only the pot differs."""

    def _tournament(self, *, champions=False):
        from decimal import Decimal
        from games.models import (MiniSinglesConfig,
                                  LowNetChampionshipConfig)
        from ._helpers import make_tournament
        tourn = make_tournament(total_rounds=2, mini_singles_carve_pct=25)
        LowNetChampionshipConfig.objects.create(
            tournament=tourn, entry_fee=Decimal('40.00'), payouts=[])
        MiniSinglesConfig.objects.create(
            tournament=tourn, handicap_mode='gross',
            day1_entry_fee=Decimal('10.00'),
            day1_payouts=[{'place': 1, 'amount': 24},
                          {'place': 2, 'amount': 10},
                          {'place': 3, 'amount': 6}],
            day2_payouts=[{'place': 1, 'amount': 24},
                          {'place': 2, 'amount': 10},
                          {'place': 3, 'amount': 6}])
        self.round.tournament = tourn
        self.round.save(update_fields=['tournament'])
        if champions:
            self.fs.is_champions_foursome = True
            self.fs.save(update_fields=['is_champions_foursome'])
        return tourn

    def test_day_one_is_net_of_the_entry_and_sends_the_winner_on(self):
        self._tournament()
        card = self._card(18)
        assert card['day'] == 1
        assert card['trailing'] == '$40 pot'
        assert card['winner']['label'] == 'Group winner'
        assert card['winner']['line'] == \
            "Paul goes through to the champions' foursome on day 2."
        rows = {r['name'].split()[0]: r['amount']
                for r in card['result']['rows']}
        assert rows == {'Paul': '+$14', 'Sam': '$0',
                        'Dave': '−$7', 'Lee': '−$7'}

    def test_day_two_is_paid_from_the_carve_out(self):
        """No entry on day 2: the pot is the carve-out, so the table shows
        what each golfer is PAID and nobody is down."""
        self._tournament(champions=True)
        card = self._card(18)
        assert card['day'] == 2
        # Four golfers at $40 is a $160 pool; 25% is carved.
        assert card['trailing'] == '$40 carve-out'
        assert card['winner']['label'] == 'Champion'
        assert card['winner']['line'] == ''
        rows = {r['name'].split()[0]: (r['amount'], r['tone'])
                for r in card['result']['rows']}
        assert rows == {'Paul': ('+$24', 'up'), 'Sam': ('+$10', 'up'),
                        'Dave': ('+$3', 'up'), 'Lee': ('+$3', 'up')}
        assert card['result']['line'] == \
            '$24 / $10 / $6 from the $40 carve-out, 4th nothing.'
