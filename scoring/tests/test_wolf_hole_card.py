"""
scoring/tests/test_wolf_hole_card.py
------------------------------------
`services.wolf.wolf_hole_card` — the Wolf score-entry card
(`~/Downloads/handoff-wolf-score-entry`).

The handoff's three worked calls are played through the REAL engine rather
than asserted against numbers typed here, because the whole point of the card
is that it renders the engine and decides nothing.  Its hole is par 4 / SI 5
with the group off the low man, so Dave (4 under the low man) takes no stroke
on it while Sam (7) and Lee (10) each take one — the handoff's own
allocation, and the thing a hand-written fixture would quietly lose.
"""
from decimal import Decimal

from django.test import TestCase

from games.models import WolfHoleDecision
from services.wolf import calculate_wolf, setup_wolf, wolf_hole_card

from ._helpers import make_foursome, make_round, make_tee, submit_hole

HOLE = 9            # par 4, stroke index 5 — the handoff's hole


class _WolfCardBase(TestCase):
    """Paul 8, Dave 12, Sam 15, Lee 18, off the low man, $1 a point."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit = Decimal('1')
        self.round.save(update_fields=['bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Paul Lipkin', 8), ('Dave Kim', 12),
             ('Sam Reid', 15), ('Lee Nash', 18)],
            tee=self.tee,
        )
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}

    def _order(self, *names):
        return [self.pid[n] for n in names]

    def _setup(self, **kw):
        kw.setdefault('handicap_mode', 'strokes_off')
        kw.setdefault('net_percent', 100)
        # Hole 9 is play position 8, and 8 % 4 == 0, so order[0] is its Wolf.
        kw.setdefault('wolf_order', self._order('Sam', 'Lee', 'Paul', 'Dave'))
        self.game = setup_wolf(self.fs, **kw)
        return self.game

    def _decide(self, hole, decision, partner=None):
        WolfHoleDecision.objects.update_or_create(
            game=self.game, hole_number=hole,
            defaults={'decision': decision, 'partner_id': partner},
        )

    def _score(self, hole, paul, dave, sam, lee):
        submit_hole(self.fs, hole, [(self.pid['Paul'], paul),
                                    (self.pid['Dave'], dave),
                                    (self.pid['Sam'],  sam),
                                    (self.pid['Lee'],  lee)])
        calculate_wolf(self.fs)

    def _card(self, hole=HOLE):
        return wolf_hole_card(self.fs, hole)

    def _pts(self, card):
        return {r['first']: r['hole_points'] for r in card['players']}


class TheHandoffsThreeCallsTests(_WolfCardBase):
    """Hole 9, par 4, SI 5.  Sam is Wolf; Paul is the low man."""

    def test_the_strokes_are_the_handoffs(self):
        self._setup()
        card = self._card()
        self.assertEqual(card['par'], 4)
        self.assertEqual(card['stroke_index'], 5)
        self.assertEqual({r['first']: r['strokes'] for r in card['players']},
                         {'Sam': 1, 'Lee': 1, 'Paul': 0, 'Dave': 0})

    def test_sam_takes_paul_and_wins(self):
        self._setup()
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        self._score(HOLE, paul=4, dave=5, sam=5, lee=6)
        card = self._card()
        self.assertEqual(self._pts(card),
                         {'Sam': 1.0, 'Lee': -1.0, 'Paul': 1.0, 'Dave': -1.0})
        self.assertEqual(card['call_label'], 'partner')
        self.assertEqual(card['call_value'], '1 pt each')
        wolf, field = card['sides']
        self.assertEqual(wolf, {'side': 'wolf', 'label': 'Sam + Paul',
                                'best': 4, 'result': 'won'})
        self.assertEqual(field, {'side': 'field', 'label': 'Lee + Dave',
                                 'best': 5, 'result': 'lost'})

    def test_sam_goes_lone_and_loses(self):
        self._setup()
        self._decide(HOLE, 'lone')
        self._score(HOLE, paul=4, dave=5, sam=6, lee=6)
        card = self._card()
        self.assertEqual(self._pts(card),
                         {'Sam': -3.0, 'Lee': 1.0, 'Paul': 1.0, 'Dave': 1.0})
        self.assertEqual(card['call_label'], 'Lone Wolf')
        self.assertEqual(card['call_value'], '3 pts')
        wolf, field = card['sides']
        self.assertEqual(wolf['label'], 'Sam')
        self.assertEqual(wolf['best'], 5)       # net, off his stroke
        self.assertEqual(wolf['result'], 'lost')
        self.assertEqual(field['best'], 4)
        self.assertEqual(field['result'], 'won')

    def test_sam_calls_blind_and_wins(self):
        self._setup()
        self._decide(HOLE, 'blind')
        self._score(HOLE, paul=4, dave=5, sam=4, lee=5)
        card = self._card()
        self.assertEqual(self._pts(card),
                         {'Sam': 6.0, 'Lee': -2.0, 'Paul': -2.0, 'Dave': -2.0})
        self.assertEqual(card['call_value'], '6 pts')
        self.assertEqual(card['sides'][0]['best'], 3)

    def test_every_hole_sums_to_zero(self):
        for call, scores in (('partner', (4, 5, 5, 6)),
                             ('lone',    (4, 5, 6, 6)),
                             ('blind',   (4, 5, 4, 5))):
            with self.subTest(call=call):
                self.setUp()
                self._setup()
                self._decide(HOLE, call,
                             partner=self.pid['Paul'] if call == 'partner'
                             else None)
                self._score(HOLE, *scores)
                card = self._card()
                self.assertEqual(
                    sum(r['hole_points'] for r in card['players']), 0)
                self.assertEqual(
                    round(sum(s['money'] for s in card['standing']), 2), 0)


class TheCardIsThereBeforeTheHoleIsTests(_WolfCardBase):
    """No card means no keypad — the failure Points, Rabbit and Sixes each
    hit by gating on the game's STATUS, which stays `pending` until a hole is
    fully scored."""

    def test_hole_one_of_a_fresh_round_has_a_card(self):
        self._setup()
        card = wolf_hole_card(self.fs, 1)
        self.assertTrue(card)
        self.assertEqual(card['hole'], 1)
        self.assertEqual(len(card['players']), 4)
        self.assertFalse(card['hole_complete'])
        self.assertEqual(card['sides'], [])

    def test_no_game_means_no_card(self):
        self.assertEqual(wolf_hole_card(self.fs, 1), {})

    def test_a_hole_outside_the_round_has_no_card(self):
        self._setup()
        self.round.num_holes = 9
        self.round.save(update_fields=['num_holes'])
        self.assertEqual(wolf_hole_card(self.fs, 12), {})


class TheTrayAsksForTheCallTests(_WolfCardBase):
    """Four scores and no call is the state the dark tray exists for."""

    def test_four_scores_with_no_call_needs_one(self):
        self._setup()
        self._score(HOLE, 4, 5, 5, 6)
        card = self._card()
        self.assertTrue(card['hole_complete'])
        self.assertTrue(card['needs_call'])
        self.assertEqual(card['sides'], [])
        self.assertEqual(card['call_value'], '')

    def test_it_counts_toward_nothing_until_the_call_is_set(self):
        self._setup()
        self._score(HOLE, 4, 5, 5, 6)
        self.assertEqual({s['points'] for s in self._card()['standing']}, {0.0})
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        calculate_wolf(self.fs)
        card = self._card()
        self.assertFalse(card['needs_call'])
        self.assertEqual({s['first']: s['points'] for s in card['standing']},
                         {'Sam': 1.0, 'Paul': 1.0, 'Dave': -1.0, 'Lee': -1.0})

    def test_a_call_with_no_scores_does_not_need_one(self):
        self._setup()
        self._decide(HOLE, 'lone')
        card = self._card()
        self.assertFalse(card['needs_call'])
        self.assertFalse(card['hole_complete'])
        # The sides are drawn from the call alone — that is what colours the
        # golfer rows before anybody has holed out.
        self.assertEqual([s['side'] for s in card['sides']], ['wolf', 'field'])
        self.assertIsNone(card['sides'][0]['best'])
        self.assertIsNone(card['sides'][0]['result'])


class TheStandingIsThroughThisHoleTests(_WolfCardBase):
    """`summary['players']` carries the ROUND's totals, so reading them put a
    golfer on the 1st tee at the 18th's figure."""

    def _play(self, holes):
        self._setup()
        for h in holes:
            self._decide(h, 'lone')
            self._score(h, 4, 5, 3, 6)      # the hole 9 Wolf wins every time

    def test_the_figures_stop_at_the_hole_asked_for(self):
        from services.wolf import wolf_summary
        self._play([1, 2, 3, 4, 5])
        card = wolf_hole_card(self.fs, 2)
        self.assertEqual(card['thru'], 2)

        # The engine's own per-hole awards for holes 1 and 2, which is what
        # "through this hole" means. Holes 3-5 are in the round and must not
        # be in these figures.
        per_hole = {h['hole']: h for h in wolf_summary(self.fs)['holes']}
        want = {}
        for h in (1, 2):
            for e in per_hole[h]['entries']:
                want[e['player_id']] = want.get(e['player_id'], 0) + e['points']
        self.assertEqual({s['player_id']: s['points'] for s in card['standing']},
                         want)
        # …and the round's own totals are a DIFFERENT set of numbers, which
        # is what makes the assertion above worth making.
        through_5 = {s['player_id']: s['points']
                     for s in wolf_hole_card(self.fs, 5)['standing']}
        self.assertNotEqual(through_5, want)
        self.assertEqual({s['player_id']: s['money'] for s in card['standing']},
                         {pid: v * 1.0 for pid, v in want.items()})

    def test_the_last_hole_agrees_with_the_board(self):
        from services.wolf import wolf_summary
        self._play(list(range(1, 19)))
        card = wolf_hole_card(self.fs, 18)
        board = {p['player_id']: (p['points'], p['money'])
                 for p in wolf_summary(self.fs)['players']}
        for s in card['standing']:
            self.assertEqual((s['points'], s['money']), board[s['player_id']])


class TheMoneyIsTheGamesOwnTests(_WolfCardBase):
    """Through `_wager_config`, so a loss cap settles in the tray exactly as
    it does on the board — `points × stake` is right only without one."""

    def test_a_cap_that_does_not_bite_changes_nothing(self):
        self._setup(loss_cap=Decimal('2'))
        self._decide(HOLE, 'blind')
        self._score(HOLE, paul=4, dave=5, sam=4, lee=5)
        card = self._card()
        money = {s['first']: s['money'] for s in card['standing']}
        # Each of the three is exactly 2 points down, so a $2 cap is not
        # reached and the money is still points × stake.
        self.assertEqual(money, {'Sam': 6.0, 'Paul': -2.0,
                                 'Dave': -2.0, 'Lee': -2.0})
        self.assertEqual(round(sum(money.values()), 2), 0)

    def test_the_cap_actually_bites(self):
        self._setup(loss_cap=Decimal('1'))
        self._decide(HOLE, 'blind')
        self._score(HOLE, paul=4, dave=5, sam=4, lee=5)
        money = {s['first']: s['money'] for s in self._card()['standing']}
        # Each of the three is -2 points but can lose at most $1, so the Wolf
        # collects $3 rather than $6.
        self.assertEqual(money['Paul'], -1.0)
        self.assertEqual(money['Sam'], 3.0)


class TheEngineDecidesWhoWonTests(_WolfCardBase):
    """Not a comparison of the nets this card also carries."""

    def test_wolf_loses_ties_is_honoured(self):
        self._setup(wolf_loses_ties=True)
        self._decide(HOLE, 'lone')
        # Sam nets 4 off his stroke; Paul also 4. Level on the card.
        self._score(HOLE, paul=4, dave=6, sam=5, lee=7)
        card = self._card()
        self.assertEqual(card['sides'][0]['best'], 4)
        self.assertEqual(card['sides'][1]['best'], 4)
        self.assertEqual(card['sides'][0]['result'], 'lost')
        self.assertEqual(card['sides'][1]['result'], 'won')

    def test_without_it_the_same_hole_is_halved(self):
        self._setup()
        self._decide(HOLE, 'lone')
        self._score(HOLE, paul=4, dave=6, sam=5, lee=7)
        card = self._card()
        self.assertEqual([s['result'] for s in card['sides']],
                         ['halved', 'halved'])
        self.assertEqual(set(self._pts(card).values()), {0.0})

    def test_the_non_wolf_bonus_shows_what_it_actually_paid(self):
        self._setup(non_wolf_bonus=True)
        self._decide(HOLE, 'partner', partner=self.pid['Paul'])
        self._score(HOLE, paul=5, dave=4, sam=6, lee=6)
        card = self._card()
        self.assertEqual(self._pts(card)['Dave'], 2.0)
        # The configured team value is 1; saying so over a row that paid 2
        # would contradict the figures beside it.
        self.assertEqual(card['call_value'], '2 pts each')
        self.assertEqual(card['values']['team'], 1)


class TheWolfAndTheNextOneTests(_WolfCardBase):
    def test_the_button_names_the_next_hole_s_wolf(self):
        self._setup()
        card = wolf_hole_card(self.fs, 1)
        self.assertEqual(card['next_hole'], 2)
        self.assertEqual(card['next_wolf_first'], 'Lee')     # order[1]
        self.assertEqual(card['wolf_first'], 'Sam')          # order[0]

    def test_the_last_two_holes_say_why_their_wolf_is_the_wolf(self):
        self._setup()
        self.assertFalse(wolf_hole_card(self.fs, 16)['last_place_wolf'])
        self.assertTrue(wolf_hole_card(self.fs, 17)['last_place_wolf'])
        self.assertTrue(wolf_hole_card(self.fs, 18)['last_place_wolf'])

    def test_the_rule_can_be_off(self):
        self._setup(last_place_wolf_1718=False)
        self.assertFalse(wolf_hole_card(self.fs, 18)['last_place_wolf'])

    def test_round_over_on_the_last_hole_in_play_order(self):
        self._setup()
        for h in range(1, 19):
            self._decide(h, 'lone')
            self._score(h, 4, 5, 3, 6)
        self.assertFalse(wolf_hole_card(self.fs, 17)['round_over'])
        card = wolf_hole_card(self.fs, 18)
        self.assertTrue(card['round_over'])
        self.assertIsNone(card['next_hole'])
        self.assertEqual(card['winner']['points'],
                         card['standing'][0]['points'])
        self.assertEqual(card['winner']['stake'], 1.0)

    def test_the_last_hole_with_no_call_has_no_winner(self):
        self._setup()
        for h in range(1, 18):
            self._decide(h, 'lone')
            self._score(h, 4, 5, 3, 6)
        self._score(18, 4, 5, 3, 6)
        card = wolf_hole_card(self.fs, 18)
        self.assertTrue(card['round_over'])
        self.assertTrue(card['needs_call'])
        self.assertIsNone(card['winner'])


class ItFollowsPlayOrderTests(_WolfCardBase):
    """The shotgun shape: `thru` is holes played, not the hole number, and
    the next hole is the group's next one."""

    def setUp(self):
        super().setUp()
        self.round.starting_hole = 7
        self.round.save(update_fields=['starting_hole'])

    def test_thru_and_the_next_hole_are_the_groups_own(self):
        self._setup()
        first = wolf_hole_card(self.fs, 7)
        self.assertEqual(first['thru'], 1)
        self.assertEqual(first['next_hole'], 8)
        last = wolf_hole_card(self.fs, 6)
        self.assertEqual(last['thru'], 18)
        self.assertIsNone(last['next_hole'])

    def test_hole_18_is_not_the_end_of_a_shotgun_round(self):
        self._setup()
        card = wolf_hole_card(self.fs, 18)
        self.assertEqual(card['next_hole'], 1)
        self.assertEqual(card['thru'], 12)


class TheNamesAreSentencesTests(_WolfCardBase):
    def test_a_first_name_not_an_initial(self):
        self._setup()
        card = wolf_hole_card(self.fs, 1)
        self.assertEqual({r['first'] for r in card['players']},
                         {'Paul', 'Dave', 'Sam', 'Lee'})
        # `short` is still there for anything read at arm's length.
        self.assertEqual({r['short'] for r in card['players']},
                         {'PL', 'DK', 'SR', 'LN'})

    def test_two_daves_are_told_apart(self):
        self.fs.memberships.all().delete()
        self.fs = make_foursome(
            self.round,
            [('Dave Kim', 8), ('Dave Moran', 12),
             ('Sam Reid', 15), ('Lee Nash', 18)],
            tee=self.tee, group_number=2,
        )
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_wolf(self.fs, handicap_mode='gross',
                   wolf_order=list(self.pid.values()))
        card = wolf_hole_card(self.fs, 1)
        firsts = {r['name']: r['first'] for r in card['players']}
        self.assertEqual(firsts['Dave Kim'], 'Dave K')
        self.assertEqual(firsts['Dave Moran'], 'Dave M')
        self.assertEqual(firsts['Sam Reid'], 'Sam')


class ThePartnerChipsTests(_WolfCardBase):
    def test_four_players_may_take_a_partner(self):
        self._setup()
        self.assertTrue(wolf_hole_card(self.fs, 1)['can_partner'])

    def test_the_forced_solo_turn_offers_no_partner(self):
        self._setup(require_lone_or_blind=True)
        # Sam is order[0], so he is Wolf on 1, 5, 9 and 13. Three partner
        # calls and the fourth turn is his last inside the first 16.
        for h in (1, 5, 9):
            self._decide(h, 'partner', partner=self.pid['Paul'])
        self.assertFalse(wolf_hole_card(self.fs, 9)['partner_locked'])
        card = wolf_hole_card(self.fs, 13)
        self.assertTrue(card['partner_locked'])
        self.assertFalse(card['can_partner'])

    def test_one_solo_turn_already_frees_him(self):
        self._setup(require_lone_or_blind=True)
        for h in (1, 5):
            self._decide(h, 'partner', partner=self.pid['Paul'])
        self._decide(9, 'lone')
        self.assertTrue(wolf_hole_card(self.fs, 13)['can_partner'])

    def test_three_players_never_do(self):
        self.fs.memberships.all().delete()
        self.fs = make_foursome(
            self.round, [('Paul Lipkin', 8), ('Dave Kim', 12),
                         ('Sam Reid', 15)],
            tee=self.tee, group_number=3,
        )
        setup_wolf(self.fs, handicap_mode='gross')
        self.assertFalse(wolf_hole_card(self.fs, 1)['can_partner'])
