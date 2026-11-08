"""
scoring/tests/test_skins_hole_card.py
-------------------------------------
`services.skins.skins_hole_card` — the Skins score-entry card
(`~/Downloads/handoff-skins-score-entry`).

The handoff's worked examples are played through the REAL engine rather
than asserted against numbers typed here: what rides, who took it, whether
a gross birdie stole it and what the money is are all the engine's, and
the card's whole job is to render them.
"""
import re
from decimal import Decimal

from django.test import TestCase

from services.skins import (
    calculate_skins, setup_skins, skins_hole_card, skins_summary,
)

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _CardBase(TestCase):
    """The handoff's own group: Paul 8, Dave 12, Sam 15, Lee 18, $5 a skin.

    On hole 7 (par 4, SI 5) Sam and Lee get a stroke off the low man and
    Dave does not — which is why that hole is the one the packet works.
    """

    HCPS = [('Paul Lipkin', 8), ('Dave Kim', 12),
            ('Sam Reid', 15), ('Lee Novak', 18)]

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = Decimal('5')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(self.round, self.HCPS, tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _setup(self, **kw):
        kw.setdefault('handicap_mode', 'strokes_off')
        kw.setdefault('carryover', True)
        kw.setdefault('payout_style', 'per_point')
        kw.setdefault('per_point_mode', 'all')
        kw.setdefault('per_point_rate', 5)
        self.game = setup_skins(self.fs, **kw)
        return self.game

    def _play(self, hole, *gross):
        submit_hole(self.fs, hole,
                    [(self.pid[n], g) for n, g in
                     zip(['Paul', 'Dave', 'Sam', 'Lee'], gross)])
        calculate_skins(self.fs)

    def _card(self, hole):
        return skins_hole_card(self.fs, hole)

    def _by(self, card, first):
        return next(p for p in card['players'] if p['first'] == first)


class TheHoleItselfTests(_CardBase):

    def test_the_low_net_takes_it_outright(self):
        self._setup()
        self._play(1, 4, 5, 6, 6)
        card = self._card(1)
        self.assertEqual(card['outcome'], 'outright')
        self.assertEqual(card['winner_id'], self.pid['Paul'])
        self.assertEqual(card['riding'], 1)
        self.assertIn('Paul takes 1 skin with net', card['line'])

    def test_the_nets_run_low_to_high(self):
        self._setup()
        self._play(1, 6, 5, 4, 7)
        nets = [p['net'] for p in self._card(1)['players']]
        self.assertEqual(nets, sorted(nets))

    def test_a_fresh_hole_has_a_card_and_no_result(self):
        self._setup()
        card = self._card(1)
        self.assertEqual(card['outcome'], 'pending')
        self.assertFalse(card['hole_complete'])
        self.assertTrue(all(p['gross'] is None for p in card['players']))
        self.assertEqual(card['riding'], 1)

    def test_no_game_means_no_card(self):
        self.assertEqual(self._card(1), {})

    def test_it_follows_the_group_s_play_order(self):
        self.round.starting_hole = 10
        self.round.save(update_fields=['starting_hole'])
        self._setup()
        self._play(10, 4, 5, 6, 6)
        card = self._card(10)
        self.assertEqual(card['thru'], 1)
        self.assertEqual(card['nine'], 'front nine')
        self.assertEqual(card['next_hole'], 11)


class TheCarryTests(_CardBase):
    """GROSS, so a tie is exactly what the scores say.

    Off the low man, hole 1 is SI 7 (Dave takes no stroke) and hole 2 is
    SI 3 (he does) — so the same four scores tie on one and are won
    outright on the other, and a carry test written against net would be
    testing the allocation instead. The allocation has its own tests.
    """

    def _setup(self, **kw):
        kw.setdefault('handicap_mode', 'gross')
        return super()._setup(**kw)


    def test_a_tie_carries_and_says_where(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)          # Paul and Dave tie on net 4
        card = self._card(1)
        self.assertEqual(card['outcome'], 'carry')
        self.assertIsNone(card['winner_id'])
        self.assertIn('Tied on net 4', card['line'])
        self.assertEqual(card['rides_to'], '2 ride to 2')

    def test_and_the_next_hole_carries_it_in(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)
        card = self._card(2)
        self.assertEqual(card['riding'], 2)
        self.assertEqual(card['carried_in'], 1)
        self.assertEqual(card['carried_from'], 1)

    def test_two_carried_holes_ride_as_three(self):
        """A carried hole's stored value is the pot INCLUDING itself."""
        self._setup()
        self._play(1, 4, 4, 6, 6)
        self._play(2, 4, 4, 6, 6)
        card = self._card(3)
        self.assertEqual(card['riding'], 3)
        self.assertEqual(card['carried_in'], 2)
        self.assertEqual(card['carried_from'], 1)

    def test_and_the_winner_takes_the_lot(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)
        self._play(2, 4, 6, 6, 6)
        card = self._card(2)
        self.assertEqual(card['riding'], 2)
        self.assertIn('takes 2 skins', card['line'])

    def test_with_carry_OFF_the_skin_is_killed(self):
        self._setup(carryover=False)
        self._play(1, 4, 4, 6, 6)
        card = self._card(1)
        self.assertEqual(card['outcome'], 'dead')
        self.assertEqual(card['rides_to'], 'no skin')
        self.assertEqual(self._card(2)['riding'], 1)


class TheGrossBirdieStealTests(_CardBase):
    """The handoff's phone 4, on the hole the allocation actually gives it.

    Hole 1 is par 4, SI 7. Off the low man Paul (8) takes no stroke and Sam
    (15) takes seven, so SI 7 is his last one — Paul's gross 3 is a natural
    birdie and Sam's gross 4 is a made one, and they tie on net 3. **The
    fixture asserts that before asserting the rule**, because a hole where
    they did not tie would make the steal test pass about nothing.
    """

    def _assert_it_is_the_tie(self, card):
        paul, sam = self._by(card, 'Paul'), self._by(card, 'Sam')
        self.assertEqual((paul['net'], sam['net']), (3, 3))
        self.assertTrue(paul['birdie'])
        self.assertFalse(sam['birdie'])

    def test_a_natural_birdie_beats_a_made_one(self):
        self._setup(birdie_steal=True)
        self._play(1, 3, 6, 4, 7)
        card = self._card(1)
        self._assert_it_is_the_tie(card)
        self.assertEqual(card['outcome'], 'steal')
        self.assertEqual(card['winner_id'], self.pid['Paul'])
        self.assertEqual(card['steal_by'], self.pid['Paul'])
        self.assertEqual(
            card['line'],
            "Gross birdie steals. Paul's gross 3 beats Sam's net 3")

    def test_without_the_option_the_same_hole_ties(self):
        self._setup(birdie_steal=False)
        self._play(1, 3, 6, 4, 7)
        card = self._card(1)
        self._assert_it_is_the_tie(card)
        self.assertIsNone(card['winner_id'])
        self.assertEqual(card['outcome'], 'carry')

    def test_an_outright_natural_is_not_a_steal(self):
        self._setup(birdie_steal=True)
        self._play(1, 3, 6, 6, 7)
        card = self._card(1)
        self.assertEqual(card['outcome'], 'outright')
        self.assertIsNone(card['steal_by'])
        self.assertTrue(self._by(card, 'Paul')['birdie'])


class ParIsPerGolferTests(_CardBase):
    """Par is read from EACH GOLFER'S OWN TEE, the way the engine reads it.

    The summary's hole `par` is one layout for the foursome, which is right
    when the question is about the HOLE. The birdie flag and the steal ask
    about the GOLFER, and on a mixed-tee card the pars differ — so a
    fixture on one tee cannot tell the two readings apart, which is why
    this one puts Sam on a women's tee where the 1st is a par 5.
    """

    def setUp(self):
        super().setUp()
        from scoring.tests._helpers import DEFAULT_HOLES
        womens = [dict(h) for h in DEFAULT_HOLES]
        womens[0]['par'] = 5                 # the 1st, a par 4 off White
        self.womens = make_tee(self.tee.course, tee_name='Red',
                               holes=womens)
        m = self.fs.memberships.get(player_id=self.pid['Sam'])
        m.tee = self.womens
        m.save(update_fields=['tee'])

    def test_a_birdie_is_measured_against_his_own_par(self):
        self._setup(handicap_mode='gross')
        # Gross 4 on the 1st: a par off White, a BIRDIE off Red.
        self._play(1, 4, 6, 4, 7)
        card = self._card(1)
        self.assertFalse(self._by(card, 'Paul')['birdie'],
                         'a 4 on his par 4 is not a birdie')
        self.assertTrue(self._by(card, 'Sam')['birdie'],
                        'the same 4 on his par 5 is')


class TheMoneyTests(_CardBase):

    def test_it_is_the_engine_s_own_net(self):
        self._setup()
        self._play(1, 4, 5, 6, 6)
        card = self._card(1)
        nets = {e['first']: e['money'] for e in card['ledger']}
        summary = skins_summary(self.fs)
        for p in summary['players']:
            self.assertEqual(nets[p['name'].split()[0]], p['net'])

    def test_and_it_is_zero_sum(self):
        self._setup()
        self._play(1, 4, 5, 6, 6)
        total = sum(e['money'] for e in self._card(1)['ledger'])
        self.assertAlmostEqual(total, 0.0, places=2)

    def test_the_hole_is_worth_what_the_winner_takes(self):
        """Four golfers at $5: one skin pays the winner $15, three others."""
        self._setup()
        self._play(1, 4, 5, 6, 6)
        self.assertEqual(self._card(1)['hole_value'], 15.0)

    def test_and_a_carried_hole_is_worth_both(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)
        self.assertEqual(self._card(2)['hole_value'], 30.0)

    def test_a_pool_quotes_no_per_skin_price(self):
        """One pot is divided among however many skins get won, so a
        per-skin figure would stop being true the moment the next one is."""
        self._setup(payout_style='pool')
        self._play(1, 4, 5, 6, 6)
        card = self._card(1)
        self.assertTrue(card['is_pool'])
        self.assertEqual(card['hole_value'], 0.0)
        self.assertEqual(card['skin_worth'], 0.0)

    def test_the_ledger_is_sorted_by_skins(self):
        self._setup()
        self._play(1, 4, 5, 6, 6)
        self._play(2, 6, 4, 6, 6)
        order = [e['total_skins'] for e in self._card(2)['ledger']]
        self.assertEqual(order, sorted(order, reverse=True))

    def test_and_marks_what_was_won_on_THIS_hole(self):
        self._setup()
        self._play(1, 4, 4, 6, 6)          # carries
        self._play(2, 4, 6, 6, 6)          # Paul takes both
        card = self._card(2)
        this = {e['first']: e['this_hole'] for e in card['ledger']}
        self.assertEqual(this['Paul'], 2)
        self.assertEqual(this['Dave'], 0)


class TheFooterTests(_CardBase):
    """GROSS, for the reason `TheCarryTests` gives: hole 2 is SI 3, where
    Dave takes a stroke and the four scores that tie on hole 1 do not."""

    def _setup(self, **kw):
        kw.setdefault('handicap_mode', 'gross')
        return super()._setup(**kw)

    def test_it_counts_the_skins_actually_won(self):
        self._setup()
        self._play(1, 4, 5, 6, 6)
        self._play(2, 4, 4, 6, 6)          # carries
        card = self._card(2)
        self.assertEqual(card['skins_won'], 1)
        self.assertEqual(card['holes_played'], 2)
        self.assertEqual(card['holes_left'], 16)

    def test_the_last_hole_has_nowhere_to_ride(self):
        """Confirmed with the engine, which the handoff asked for: skins
        still in the pot after the last hole are voided."""
        self._setup()
        for h in range(1, 18):
            self._play(h, 4, 5, 6, 6)      # Paul takes every one
        self._play(18, 4, 4, 6, 6)         # …and the last one ties
        card = self._card(18)
        self.assertEqual(card['outcome'], 'carry')
        self.assertEqual(card['rides_to'], 'no skin')
        self.assertTrue(card['round_over'])
        self.assertIsNone(card['next_hole'])
        self.assertEqual(card['skins_won'], 17,
                         'the 18th is not in the denominator')


class SkinsFixtureRegenTests(_CardBase):
    """Writes the JSON `mobile/test/skins_entry_test.dart` draws, from the
    REAL engine.

    `REGEN_SKINS_FIXTURES=1 manage.py test scoring.tests.test_skins_hole_card`
    rewrites them. A tray tested against hand-written JSON is tested against
    what somebody THOUGHT the server sends.
    """

    def _write(self, name, card):
        import json, os, pathlib
        if os.environ.get('REGEN_SKINS_FIXTURES') != '1':
            return
        path = (pathlib.Path(__file__).resolve().parents[2]
                / 'mobile' / 'test' / 'fixtures' / name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(card, indent=2, default=str) + '\n')

    def test_regenerate_an_outright_winner(self):
        """The handoff's phone 2, on the holes the allocation gives it:
        thru 6 Paul has 2, Dave 2, Sam 0, Lee 1, with one carried, so two
        ride on the 7th and Paul takes them."""
        self._setup()
        self._play(1, 4, 6, 7, 8)          # Paul
        self._play(2, 4, 6, 7, 8)          # Paul
        self._play(3, 6, 4, 7, 8)          # Dave
        self._play(4, 7, 5, 8, 9)          # Dave
        self._play(5, 7, 8, 9, 6)          # Lee
        self._play(6, 5, 5, 8, 9)          # tie → carries
        card = self._card(7)
        self.assertEqual(card['riding'], 2)
        self.assertEqual(card['carried_in'], 1)
        self._write('skins_hole7_open.json', card)

        self._play(7, 4, 5, 5, 5)
        won = self._card(7)
        self.assertEqual(won['outcome'], 'outright')
        self.assertEqual(won['riding'], 2)
        self._write('skins_hole7_outright.json', won)

    def test_regenerate_a_tie_that_carries(self):
        self._setup(handicap_mode='gross')
        self._play(1, 4, 6, 7, 8)
        self._play(2, 4, 4, 7, 8)          # tie → carries
        card = self._card(2)
        self.assertEqual(card['outcome'], 'carry')
        self.assertEqual(card['rides_to'], '2 ride to 3')
        self._write('skins_hole2_carry.json', card)

    def test_regenerate_a_gross_birdie_steal(self):
        self._setup(birdie_steal=True)
        self._play(1, 3, 6, 4, 7)
        card = self._card(1)
        self.assertEqual(card['outcome'], 'steal')
        self._write('skins_hole1_steal.json', card)

    def test_regenerate_the_round_over(self):
        self._setup(handicap_mode='gross')
        for h in range(1, 18):
            self._play(h, 4, 5, 6, 7)
        self._play(18, 6, 4, 6, 7)
        card = self._card(18)
        self.assertTrue(card['round_over'])
        self.assertEqual(card['outcome'], 'outright')
        self._write('skins_hole18_final.json', card)
