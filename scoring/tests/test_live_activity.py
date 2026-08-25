"""
scoring/tests/test_live_activity.py
-----------------------------------
The Sixes lock-screen state (docs/design-review/handoff-sixes-lock/SPEC.md).

The activity is a PROJECTION of `sixes_summary` — it computes nothing about the
match — so these tests check the projection, not the golf: that the number wears
the leading side's colour, that the rows do not swap under the reader, that the
pips are the shape of the round, and that the one personal number stays in the
quietest slot.
"""
from django.test import TestCase

from services.live_activity import (
    BLUE, NEUTRAL, ORANGE, pairing_push, segment_ordinal, sixes_activity_state,
    sixes_final_state,
)
from services.sixes import calculate_sixes, setup_sixes
from ._helpers import make_foursome, make_round, make_tee, submit_hole


def _teams(a, b, c, d):
    base = {'team_select_method': 'long_drive',
            'team1_player_ids': [a, b], 'team2_player_ids': [c, d]}
    return [
        {**base, 'start_hole':  1, 'end_hole':  6},
        {**base, 'start_hole':  7, 'end_hole': 12},
        {**base, 'start_hole': 13, 'end_hole': 18},
    ]


class LiveActivityStateTests(TestCase):

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_sixes(
            self.fs,
            _teams(self.pid['Paul'], self.pid['Dave'],
                   self.pid['Sam'],  self.pid['Lee']),
            handicap_mode='gross',
        )

    def _play(self, hole, t1, t2):
        submit_hole(self.fs, hole, [
            (self.pid['Paul'], t1), (self.pid['Dave'], t1),
            (self.pid['Sam'],  t2), (self.pid['Lee'],  t2),
        ])
        # The API recalculates on every post; a unit test has to say so.
        calculate_sixes(self.fs)

    def _state(self, **kw):
        return sixes_activity_state(self.fs, **kw)

    # -- the number ------------------------------------------------------

    def test_all_square_is_neutral_never_a_sides_colour(self):
        """Mint is the app's colour, not a side's — an all-square number that
        wore one would say a side was up."""
        s = self._state()
        self.assertEqual(s['number']['text'], 'ALL SQ')
        self.assertEqual(s['number']['colour'], NEUTRAL)

    def test_the_number_wears_the_leading_sides_colour(self):
        par = self.tee.hole(1)['par']
        self._play(1, par, par + 1)          # blue wins the hole
        s = self._state()
        self.assertEqual(s['number']['text'], '1 UP')
        self.assertEqual(s['number']['colour'], BLUE)

    def test_the_other_side_leading_flips_the_colour_not_the_rows(self):
        """The rows must NOT reorder when the lead changes — a board that
        re-sorts under the reader is unreadable at a glance."""
        par = self.tee.hole(1)['par']
        self._play(1, par + 1, par)          # orange wins
        s = self._state()
        self.assertEqual(s['number']['colour'], ORANGE)
        self.assertEqual(s['sides'][0]['colour'], BLUE)     # still first
        self.assertTrue(s['sides'][1]['leading'])
        self.assertFalse(s['sides'][0]['leading'])

    # -- the sides -------------------------------------------------------

    def test_both_pairings_are_named(self):
        """Never "you are 2 up" — four golfers read the same string, and the
        pairing changes mid-round."""
        s = self._state()
        names = {side['names'] for side in s['sides']}
        self.assertEqual(len(names), 2)
        for n in names:
            self.assertIn('&', n)

    # -- the state slot --------------------------------------------------

    def test_dormie_when_the_lead_equals_the_holes_left(self):
        par = self.tee.hole(1)['par']
        self._play(1, par, par + 1)      # blue wins
        self._play(2, par, par + 1)      # blue wins
        self._play(3, par, par)          # halved
        self._play(4, par, par)          # halved
        s = self._state()
        # Two up with two of the six to play — the one fact that changes how
        # the next hole gets played.
        self.assertEqual(s['state']['word'], 'DORMIE')
        self.assertEqual(s['state']['to_play'], '2 TO PLAY')

    def test_the_state_slot_is_never_the_money(self):
        s = self._state(player_id=self.pid['Paul'])
        self.assertIn(s['state']['word'], ('DORMIE', '—'))
        self.assertNotIn('$', s['state']['word'])

    # -- pips ------------------------------------------------------------

    def test_three_pips_always(self):
        """Identical in every state — the one element that never moves."""
        self.assertEqual(len(self._state()['pips']), 3)

    def test_a_won_segment_takes_the_winning_sides_colour(self):
        par = self.tee.hole(1)['par']
        for h in range(1, 7):                # blue takes segment 1
            self._play(h, par, par + 1)
        self.assertEqual(self._state()['pips'][0], BLUE)

    # -- footer ----------------------------------------------------------

    def test_thru_is_in_the_footer_not_on_the_sides_line(self):
        s = self._state(thru=4)
        self.assertIn('Thru 4', s['footer']['context'])
        for side in s['sides']:
            self.assertNotIn('thru', side['names'].lower())

    def test_money_is_the_one_personal_number_and_it_is_in_the_footer(self):
        par = self.tee.hole(1)['par']
        for h in range(1, 7):
            self._play(h, par, par + 1)      # blue wins segment 1
        paul = self._state(player_id=self.pid['Paul'])
        sam  = self._state(player_id=self.pid['Sam'])

        # The ONLY slot that differs between two phones in the same group.
        self.assertNotEqual(paul['footer']['money'], sam['footer']['money'])
        for slot in ('header', 'number', 'sides', 'state', 'pips'):
            self.assertEqual(paul[slot], sam[slot])

    # -- header ----------------------------------------------------------

    def test_the_header_names_the_segment_and_its_holes(self):
        self.assertEqual(self._state()['header']['segment'],
                         'SEGMENT 1 · HOLES 1-6')
        self.assertEqual(self._state()['header']['game'], 'SIXES')

    def test_high_low_says_so_and_counts_points(self):
        fs2 = make_foursome(
            self.round,
            [('A', 0), ('B', 0), ('C', 0), ('D', 0)],
            tee=self.tee, group_number=2,
        )
        pid = {m.player.name: m.player_id
               for m in fs2.memberships.select_related('player')}
        setup_sixes(fs2, _teams(pid['A'], pid['B'], pid['C'], pid['D']),
                    handicap_mode='gross', scoring_format='high_low')
        s = sixes_activity_state(fs2)
        self.assertEqual(s['header']['game'], 'SIXES · HIGH-LOW')
        self.assertIn(s['number']['text'], ('ALL SQ',))


class PairingPushTests(TestCase):
    """One push per pairing landing, and the copy for extra holes is
    method-neutral — half the time nothing was drawn."""

    def test_a_drawn_segment_names_its_holes_and_pairing(self):
        seg = {'start_hole': 7, 'end_hole': 12, 'is_extra': False,
               'team1': {'players_short': ['Paul', 'Sam']},
               'team2': {'players_short': ['Dave', 'Lee']}}
        push = pairing_push(seg, [{'is_extra': False}, seg])
        self.assertEqual(push['title'], 'New partners — holes 7-12')
        self.assertEqual(push['body'], 'Pairing 2: Paul & Sam v. Dave & Lee')

    def test_extra_holes_copy_never_says_drawn(self):
        seg = {'start_hole': 5, 'end_hole': 6, 'is_extra': True,
               'team1': {'players_short': ['Paul', 'Sam']},
               'team2': {'players_short': ['Dave', 'Lee']}}
        push = pairing_push(seg)
        self.assertEqual(push['title'], 'New partners — extra holes')
        self.assertEqual(push['body'], 'Extra holes 5-6: Paul & Sam v. Dave & Lee')
        self.assertNotIn('drawn', push['body'].lower())
        self.assertNotIn('drawn', push['title'].lower())

    def test_extra_holes_are_not_a_fourth_segment(self):
        segs = [{'is_extra': False}, {'is_extra': True}, {'is_extra': False}]
        self.assertEqual(segment_ordinal(segs, segs[0]), 1)
        self.assertEqual(segment_ordinal(segs, segs[2]), 2)


class PipTests(TestCase):
    """Three bars carry the whole round, so every combination has to be right —
    not just the one a happy-path round happens to produce."""

    def _pips(self, segs):
        from services.live_activity import _pips
        return _pips(segs)

    def test_a_fresh_round_is_one_live_and_two_unplayed(self):
        segs = [{'status': 'pending'}] * 3
        self.assertEqual(self._pips(segs), ['live', 'unplayed', 'unplayed'])

    def test_the_live_pip_advances_as_segments_finish(self):
        segs = [
            {'status': 'complete', 'winner': 'Team 1'},
            {'status': 'pending'},
            {'status': 'pending'},
        ]
        self.assertEqual(self._pips(segs), [BLUE, 'live', 'unplayed'])

    def test_each_side_and_a_halve_get_their_own_mark(self):
        segs = [
            {'status': 'complete', 'winner': 'Team 1'},
            {'status': 'complete', 'winner': 'Team 2'},
            {'status': 'complete', 'winner': 'Halved'},
        ]
        self.assertEqual(self._pips(segs), [BLUE, ORANGE, 'halved'])

    def test_a_voided_segment_is_neither_side(self):
        """A withdrawal voids a segment — it scores nothing, so it cannot wear
        a winner's colour."""
        segs = [
            {'status': 'complete', 'is_void': True, 'winner': 'Halved'},
            {'status': 'pending'},
            {'status': 'pending'},
        ]
        self.assertEqual(self._pips(segs)[0], 'void')

    def test_extra_holes_borrow_the_live_pip(self):
        """Still three pips. The packet leaves the treatment open and asks which
        of two; this is the one that cannot be wrong about the segment count."""
        segs = [
            {'status': 'complete', 'winner': 'Team 1'},
            {'status': 'pending', 'is_extra': True},
            {'status': 'pending'},
            {'status': 'pending'},
        ]
        pips = self._pips(segs)
        self.assertEqual(len(pips), 3)
        self.assertEqual(pips, [BLUE, 'live', 'unplayed'])


class ContractTests(TestCase):
    """The Python state and the Swift `ContentState` are one contract in two
    languages, and nothing else checks that they still agree.

    An APNs `content-state` payload decodes straight into the Swift struct, so a
    key renamed on this side does not fail a build — it fails on a lock screen,
    on a course, silently. These tests read the Swift source and compare.
    """

    SWIFT = 'mobile/ios/SixesActivity/SixesActivity.swift'

    def setUp(self):
        import os
        from django.conf import settings
        path = os.path.join(settings.BASE_DIR, self.SWIFT)
        with open(path) as fh:
            self.swift = fh.read()

        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=self.tee,
        )
        pid = {m.player.name: m.player_id
               for m in self.fs.memberships.select_related('player')}
        self.paul = pid['Paul']
        setup_sixes(
            self.fs,
            _teams(pid['Paul'], pid['Dave'], pid['Sam'], pid['Lee']),
            handicap_mode='gross',
        )

    def test_every_top_level_slot_exists_in_the_swift_struct(self):
        state = sixes_activity_state(self.fs, player_id=self.paul)
        for key in state:
            self.assertIn(f'let {key}:', self.swift,
                          f'`{key}` has no field in ContentState')

    def test_the_nested_keys_the_swift_decodes_are_all_emitted(self):
        state = sixes_activity_state(self.fs, player_id=self.paul, thru=3)
        self.assertEqual(set(state['header']), {'game', 'segment'})
        self.assertEqual(set(state['number']), {'text', 'colour'})
        self.assertEqual(set(state['state']),  {'word', 'to_play'})
        self.assertEqual(set(state['footer']), {'context', 'money'})
        for side in state['sides']:
            self.assertEqual(set(side), {'names', 'colour', 'leading'})

    def test_to_play_is_snake_case_because_swift_maps_it(self):
        """Swift renames exactly one key. If this side stops sending
        `to_play`, the CodingKeys mapping silently yields nothing."""
        self.assertIn('case toPlay = "to_play"', self.swift)
        self.assertIn('to_play', sixes_activity_state(self.fs)['state'])

    def test_final_is_always_present_so_the_optional_decodes(self):
        ordinary = sixes_activity_state(self.fs, player_id=self.paul)
        self.assertIn('final', ordinary)
        self.assertIsNone(ordinary['final'])

    def test_the_final_state_fills_the_three_fields_swift_draws(self):
        final = sixes_final_state(self.fs, player_id=self.paul)
        self.assertEqual(set(final['final']), {'amount', 'detail', 'collect'})
        self.assertEqual(final['header']['segment'], 'ROUND COMPLETE')

    def test_the_colours_the_server_names_are_the_ones_swift_switches_on(self):
        """`Sixes.side` and `Sixes.pip` switch on these literals; a colour name
        the Swift does not know falls through to a default and the side loses
        its identity."""
        for name in ('blue', 'orange'):
            self.assertIn(f'case "{name}":', self.swift)
        for name in ('halved', 'void', 'live'):
            self.assertIn(f'case "{name}":', self.swift)


class FinalStateTests(TestCase):

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.fs = make_foursome(
            self.round,
            [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=self.tee,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_sixes(
            self.fs,
            _teams(self.pid['Paul'], self.pid['Dave'],
                   self.pid['Sam'],  self.pid['Lee']),
            handicap_mode='gross',
        )

    def _win_segment(self, holes):
        for h in holes:
            par = self.tee.hole(h)['par']
            submit_hole(self.fs, h, [
                (self.pid['Paul'], par), (self.pid['Dave'], par),
                (self.pid['Sam'], par + 1), (self.pid['Lee'], par + 1),
            ])
            calculate_sixes(self.fs)

    def test_it_says_what_you_won_and_who_to_see(self):
        self._win_segment(range(1, 7))       # blue takes segment 1
        winner = sixes_final_state(self.fs, player_id=self.pid['Paul'])
        loser  = sixes_final_state(self.fs, player_id=self.pid['Sam'])

        self.assertTrue(winner['final']['amount'].startswith('+'))
        self.assertTrue(winner['final']['collect'].startswith('Collect from'))
        self.assertTrue(loser['final']['amount'].startswith('-'))
        self.assertTrue(loser['final']['collect'].startswith('Pay'))

    def test_the_detail_names_the_segments_a_side_took(self):
        self._win_segment(range(1, 7))
        final = sixes_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertIn('Blue won 1', final['final']['detail'])

    def test_all_square_says_there_is_nothing_to_settle(self):
        final = sixes_final_state(self.fs, player_id=self.pid['Paul'])
        self.assertEqual(final['final']['collect'],
                         'All square — nothing to settle')
