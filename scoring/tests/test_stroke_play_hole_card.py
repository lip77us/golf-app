"""
scoring/tests/test_stroke_play_hole_card.py
-------------------------------------------
`stroke_play_hole_card` — what the Stroke Play score-entry tray draws for one
hole (`~/Downloads/handoff-stroke-play`).

The fixture is four golfers off 8 / 12 / 15 / 18 on `DEFAULT_HOLES`, and the
hole under test is the **4th** (par 5, stroke index 9) for a reason: Paul gets
no stroke there and the other three get one, so the stroke dots, the par-coded
keys and the cap ceiling all have something to say. A hole where everybody
strokes the same cannot pin any of them.
"""
from django.test import TestCase

from games.models import LowNetRoundConfig
from services.low_net_round import stroke_play_hole_card
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_round, make_tee, submit_hole,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}
HOLE = 4            # par 5, SI 9


class _Base(TestCase):
    cap = True
    npct = 100
    mode = 'net'

    def setUp(self):
        course = make_course()
        self.tee = make_tee(course=course, holes=DEFAULT_HOLES)
        self.round = make_round(course=course, handicap_mode='net',
                                net_percent=100,
                                active_games=['low_net_round'])
        self.round.net_max_double_bogey = self.cap
        self.round.save()
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 8), ('Dave Kim', 12),
             ('Sam Reid', 15), ('Mike Ruiz', 18)],
            tee=self.tee)
        LowNetRoundConfig.objects.create(
            round=self.round, handicap_mode=self.mode, net_percent=self.npct)

    def pid(self, first):
        return next(m.player_id for m in self.fs.memberships.all()
                    if m.player.name.startswith(first))

    def post(self, hole, scores):
        submit_hole(self.fs, hole, [(self.pid(n), v) for n, v in scores])

    def card(self, hole=HOLE):
        return stroke_play_hole_card(self.fs, hole)

    def by_name(self, rows):
        return {r['name'].split(' ')[0]: r for r in rows}


class StrokePlayHoleCardTests(_Base):
    # ── the hole ─────────────────────────────────────────────────────────────
    def test_nothing_when_the_round_does_not_play_it(self):
        self.round.active_games = ['skins']
        self.round.save()
        self.assertEqual(self.card(), {})

    def test_the_strokes_are_there_before_a_score_is(self):
        """The keypad is coded against par plus the strokes, so the card has
        to state them for a hole nobody has played."""
        p = self.by_name(self.card()['players'])
        self.assertEqual(p['Paul']['strokes'], 0)
        self.assertEqual(p['Dave']['strokes'], 1)
        self.assertEqual(p['Sam']['strokes'], 1)
        self.assertEqual(p['Mike']['strokes'], 1)
        self.assertIsNone(p['Paul']['gross'])

    def test_the_ceiling_is_the_golfers_own(self):
        """`cap_max` is a GROSS number — par + 2 + his strokes — because that
        is what he types."""
        p = self.by_name(self.card()['players'])
        self.assertEqual(p['Paul']['cap_max'], PAR[HOLE] + 2)
        self.assertEqual(p['Mike']['cap_max'], PAR[HOLE] + 2 + 1)

    def test_the_net_is_the_counted_figure(self):
        self.post(HOLE, [('Paul', 5), ('Dave', 6), ('Sam', 5), ('Mike', 7)])
        p = self.by_name(self.card()['players'])
        self.assertEqual(p['Paul']['net'], 5)       # no stroke
        self.assertEqual(p['Dave']['net'], 5)       # 6 − 1
        self.assertEqual(p['Mike']['net'], 6)       # 7 − 1
        self.assertFalse(any(x['capped'] for x in p.values()))

    # ── the cap ──────────────────────────────────────────────────────────────
    def test_a_blow_up_counts_the_ceiling_and_keeps_the_score(self):
        self.post(HOLE, [('Paul', 5), ('Dave', 6), ('Sam', 5), ('Mike', 10)])
        c = self.card()
        mike = self.by_name(c['players'])['Mike']
        self.assertEqual(mike['gross'], 10)         # the card keeps it
        self.assertEqual(mike['net'], PAR[HOLE] + 2)  # the total counts the cap
        self.assertTrue(mike['capped'])
        self.assertEqual(
            c['cap_notes'],
            ['Mike’s 10 counts as 8, net double bogey. '
             'The card keeps the 10.'])

    def test_the_note_names_the_gross_ceiling_not_the_net(self):
        """`counts as 8` is gross — 7 would be the net, and a golfer reading
        it beside his own 10 would be comparing two different things."""
        self.post(HOLE, [('Paul', 5), ('Dave', 6), ('Sam', 5), ('Mike', 10)])
        note = self.card()['cap_notes'][0]
        self.assertIn('counts as 8', note)
        self.assertNotIn('counts as 7', note)

    def test_a_score_exactly_on_the_ceiling_is_not_capped(self):
        """Mike's 8 off a stroke is net 7, which IS the ceiling — nothing
        was taken off it, so flagging it would explain a correction that did
        not happen. Paul's 8 off no stroke is over it."""
        self.post(HOLE, [('Paul', 8), ('Dave', 6), ('Sam', 5), ('Mike', 8)])
        p = self.by_name(self.card()['players'])
        self.assertTrue(p['Paul']['capped'])
        self.assertFalse(p['Mike']['capped'])
        self.assertEqual(self.card()['cap_notes'],
                         ['Paul’s 8 counts as 7, net double bogey. '
                          'The card keeps the 8.'])

    # ── places ───────────────────────────────────────────────────────────────
    def test_the_standing_is_ordered_and_placed(self):
        self.post(1, [('Paul', PAR[1]), ('Dave', PAR[1] + 2),
                      ('Sam', PAR[1] + 2), ('Mike', PAR[1] + 3)])
        rows = self.card(1)['standing']
        # Everybody strokes on the 1st (SI 7), so the nets are −0/+1/+1/+2.
        self.assertEqual([r['name'].split(' ')[0] for r in rows],
                         ['Paul', 'Dave', 'Sam', 'Mike'])
        p = self.by_name(rows)
        self.assertEqual(p['Paul']['place_text'], '1')
        self.assertEqual(p['Dave']['place_text'], 'T2')
        self.assertEqual(p['Sam']['place_text'], 'T2')
        self.assertEqual(p['Mike']['place_text'], '4')

    def test_the_first_hole_has_nowhere_to_have_moved_from(self):
        self.post(1, [('Paul', 4), ('Dave', 5), ('Sam', 5), ('Mike', 6)])
        for r in self.card(1)['standing']:
            self.assertIsNone(r['moved'])

    def test_a_hole_moves_a_golfer_up_the_board(self):
        self.post(1, [('Paul', 6), ('Dave', 4), ('Sam', 5), ('Mike', 5)])
        self.post(2, [('Paul', 3), ('Dave', 7), ('Sam', 5), ('Mike', 5)])
        p = self.by_name(self.card(2)['standing'])
        # Paul was last after the 1st and takes the lead with a net birdie;
        # Dave goes the other way.
        self.assertGreater(p['Paul']['moved'], 0)
        self.assertLess(p['Dave']['moved'], 0)
        self.assertEqual(p['Paul']['place'], 1)

    def test_the_last_hole_drops_the_arrow(self):
        for h in range(1, 19):
            self.post(h, [('Paul', PAR[h]), ('Dave', PAR[h]),
                          ('Sam', PAR[h]), ('Mike', PAR[h])])
        c = self.card(18)
        self.assertTrue(c['final'])
        for r in c['standing']:
            self.assertIsNone(r['moved'])

    def test_a_place_is_the_whole_field_not_the_card(self):
        """A second group's scores move this group's places, because a place
        is about everybody — the board the tray's own pill opens."""
        other = make_foursome(self.round, [('Ann Shaw', 0)], tee=self.tee,
                              group_number=2)
        aid = next(m.player_id for m in other.memberships.all())
        for h in range(1, 3):
            submit_hole(other, h, [(aid, PAR[h] - 1)])
        self.post(1, [('Paul', PAR[1]), ('Dave', PAR[1]),
                      ('Sam', PAR[1]), ('Mike', PAR[1])])
        c = self.card(1)
        self.assertEqual(c['field'], 5)
        self.assertEqual(c['group'], 4)
        # Ann is −2 and nobody on this card is under par, so every one of
        # them is behind her.
        self.assertTrue(all(r['place'] > 1 for r in c['standing']))

    def test_the_leader_line_names_a_golfer_off_this_card(self):
        other = make_foursome(self.round, [('Ann Shaw', 0)], tee=self.tee,
                              group_number=2)
        aid = next(m.player_id for m in other.memberships.all())
        submit_hole(other, 1, [(aid, PAR[1] - 1)])
        # The group makes net par — everybody strokes on the 1st, so a gross
        # bogey is level. Ann is scratch and one under, so she leads alone.
        self.post(1, [('Paul', PAR[1] + 1), ('Dave', PAR[1] + 1),
                      ('Sam', PAR[1] + 1), ('Mike', PAR[1] + 1)])
        self.assertEqual(self.card(1)['leader'],
                         {'name': 'Ann Shaw', 'to_par': -1, 'thru': 1})

    def test_no_leader_line_when_he_is_on_it(self):
        """Naming a golfer whose row is two lines below is a repeat."""
        self.post(1, [('Paul', PAR[1] - 1), ('Dave', PAR[1]),
                      ('Sam', PAR[1]), ('Mike', PAR[1])])
        self.assertIsNone(self.card(1)['leader'])


class GrossRoundTests(_Base):
    cap = False
    mode = 'gross'

    def test_a_gross_round_has_no_strokes_no_net_column_and_no_cap(self):
        self.post(HOLE, [('Paul', 5), ('Dave', 6), ('Sam', 5), ('Mike', 12)])
        c = self.card()
        self.assertFalse(c['show_net'])
        self.assertFalse(c['cap'])
        self.assertEqual(c['cap_notes'], [])
        p = self.by_name(c['players'])
        self.assertEqual(p['Mike']['strokes'], 0)
        self.assertIsNone(p['Mike']['cap_max'])
        self.assertEqual(p['Mike']['net'], 12)      # the gross IS the figure
        self.assertFalse(p['Mike']['capped'])


class ReducedAllowanceTests(_Base):
    npct = 90

    def test_the_cap_is_off_below_a_full_allowance(self):
        """The casual rule, and the reason `cap_in_force` is one function:
        the keypad must not offer a ceiling the engine does not enforce."""
        self.post(HOLE, [('Paul', 5), ('Dave', 6), ('Sam', 5), ('Mike', 12)])
        c = self.card()
        self.assertFalse(c['cap'])
        self.assertIsNone(self.by_name(c['players'])['Mike']['cap_max'])
        self.assertEqual(c['cap_notes'], [])


class StrokePlayFixtureRegenTests(_Base):
    """Writes the JSON the Flutter tests draw, from the REAL engine.

    `REGEN_STROKE_PLAY_FIXTURES=1 manage.py test
    scoring.tests.test_stroke_play_hole_card` rewrites them. A screen tested
    against hand-written JSON is tested against what somebody THOUGHT the
    server sends.
    """

    def _write(self, name, card):
        import json, os, pathlib
        if os.environ.get('REGEN_STROKE_PLAY_FIXTURES') != '1':
            return
        path = (pathlib.Path(__file__).resolve().parents[2]
                / 'mobile' / 'test' / 'fixtures' / name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(card, indent=2, default=str) + '\n')

    def test_regenerate(self):
        # A second group, so the places are a FIELD and the leader line has
        # somebody to name — which is the half of this tray that a
        # single-foursome fixture cannot exercise at all.
        other = make_foursome(self.round, [('Ben Ortiz', 2)], tee=self.tee,
                              group_number=2)
        bid = next(m.player_id for m in other.memberships.all())
        for h in range(1, 7):
            submit_hole(other, h, [(bid, PAR[h] - 1)])

        self.post(1, [('Paul', 4), ('Dave', 5), ('Sam', 5), ('Mike', 6)])
        self.post(2, [('Paul', 5), ('Dave', 4), ('Sam', 5), ('Mike', 5)])
        self.post(3, [('Paul', 3), ('Dave', 5), ('Sam', 4), ('Mike', 4)])

        card = self.card(3)
        self.assertEqual(card['field'], 5)
        self.assertIsNotNone(card['leader'])
        self.assertTrue(any(r['moved'] for r in card['standing']))
        self._write('stroke_play_hole3.json', card)

        # The blow-up: Mike's 12 on the 4th counts the ceiling, and the card
        # keeps the 12.
        self.post(4, [('Paul', 5), ('Dave', 6), ('Sam', 5), ('Mike', 12)])
        capped = self.card(4)
        self.assertEqual(len(capped['cap_notes']), 1)
        self._write('stroke_play_hole4_capped.json', capped)

    def test_regenerate_nothing_entered(self):
        """The hole before anybody has typed anything — the strokes are
        there and no place is claimed."""
        card = self.card(1)
        self.assertTrue(all(p['gross'] is None for p in card['players']))
        self._write('stroke_play_hole1_empty.json', card)


class TheSideGameBlocksTests(_Base):
    """`handoff-stroke-play-side-games`: the card carries what the group's
    field-wide side games add, and NOTHING when they are not being played.

    Both blocks are `None` rather than empty, because the row has to draw no
    badge and the strip has to say nothing — an empty one reads as a value
    that failed to load.
    """

    def test_neither_block_appears_on_a_plain_stroke_play_round(self):
        card = self.card()
        self.assertIsNone(card['ball'])
        self.assertIsNone(card['rumble'])

    def test_the_keys_are_always_present(self):
        """A missing key and a null one are different things to a client."""
        card = self.card()
        self.assertIn('ball', card)
        self.assertIn('rumble', card)


class TheRumbleStripTests(_Base):
    """How many balls count on this hole — the group strip's one number."""

    def setUp(self):
        super().setUp()
        from games.models import IrishRumbleConfig
        self.round.active_games = ['low_net_round', 'irish_rumble']
        self.round.save(update_fields=['active_games'])
        IrishRumbleConfig.objects.create(
            round=self.round, variant='custom',
            segments=[{'start_hole': 1, 'end_hole': 9, 'balls_to_count': 2},
                      {'start_hole': 10, 'end_hole': 18, 'balls_to_count': 4}],
        )

    def test_it_reads_the_segment_the_hole_falls_in(self):
        self.assertEqual(self.card(4)['rumble']['count'], 2)
        self.assertEqual(self.card(12)['rumble']['count'], 4)

    def test_all_count_is_the_group_s_size_not_a_literal_four(self):
        """The design draws "[4] all count"; the test is that it is the SIZE."""
        front = self.card(4)['rumble']
        back  = self.card(12)['rumble']
        self.assertEqual(front['of'], 4)
        self.assertFalse(front['all_count'])
        self.assertTrue(back['all_count'])

    def test_a_hole_in_no_segment_says_nothing(self):
        from games.models import IrishRumbleConfig
        cfg = IrishRumbleConfig.objects.get(round=self.round)
        cfg.segments = [{'start_hole': 10, 'end_hole': 18,
                         'balls_to_count': 3}]
        cfg.save(update_fields=['segments'])
        # Re-fetch: `balls_on_hole` reads `round_obj.irish_rumble_config`, a
        # CACHED reverse relation, so the card would otherwise answer from the
        # segments this test just replaced. Harmless in the app, where each
        # request builds the card from a fresh fetch — the same stale-related
        # -object trap `setup_solo` hit.
        self.fs = type(self.fs).objects.get(pk=self.fs.pk)
        self.assertIsNone(self.card(4)['rumble'],
                          'guessing a count the calculator would not use is '
                          'worse than an empty strip')

    def test_the_count_is_capped_to_the_group(self):
        """A three-ball cannot play four balls, and the strip must not say so.

        `counting_players` is the same figure `calculate_irish_rumble` caps
        with, so the strip and the money cannot disagree.
        """
        from services.irish_rumble import counting_players
        m = self.fs.memberships.order_by('-id').first()
        pid = m.player_id
        m.delete()
        from scoring.models import HoleScore
        HoleScore.objects.filter(foursome=self.fs, player_id=pid).delete()

        self.fs.refresh_from_db()
        self.assertEqual(counting_players(self.fs), 3, 'fixture: a three-ball')
        back = self.card(12)['rumble']
        self.assertEqual(back['count'], 3, 'capped from the configured 4')
        self.assertTrue(back['all_count'])
