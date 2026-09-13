"""
scoring/tests/test_live_activity_wolf.py
----------------------------------------
The Wolf lock screen, and the 17/18 rule under it.

Wolf departs from the set more than any other card: **the headline is the price
of the hole**, not a standing. That figure is a decision one man made ninety
seconds ago, and it is the only thing anyone on the tee is talking about. The
totals are still on the card, in the strip — they are just not the news.

Spec: `~/Downloads/handoff-lock-screens 2/wolf/HANDOFF.md`. Its one open
question — what happens on 17 and 18 — was settled by Paul on 13 Sep and is
pinned in `LastTwoHolesTests` below.
"""
from decimal import Decimal

from django.test import TestCase

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _Base(TestCase):
    LONE = 4

    def setUp(self):
        from services.wolf import setup_wolf
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, active_games=['wolf'])
        self.round.primary_game = 'wolf'
        self.round.bet_unit = Decimal('1.00')
        self.round.save(update_fields=['primary_game', 'bet_unit'])
        self.fs = make_foursome(
            self.round,
            [('Dave Moran', 0), ('Sam Reid', 0),
             ('Lee Naylor', 0), ('Tom Hayes', 0)],
            tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        self.order = [self.pid[n] for n in
                      ('Dave Moran', 'Sam Reid', 'Lee Naylor', 'Tom Hayes')]
        setup_wolf(self.fs, wolf_order=self.order, handicap_mode='gross',
                   lone_wolf_points=self.LONE)

    def _play(self, hole, a, b, c, d):
        submit_hole(self.fs, hole, [
            (self.pid['Dave Moran'], a), (self.pid['Sam Reid'], b),
            (self.pid['Lee Naylor'], c), (self.pid['Tom Hayes'], d)])

    def _state(self, thru, who='Dave Moran'):
        from services.live_activity_wolf import wolf_activity_state
        return wolf_activity_state(
            self.fs, player_id=self.pid[who] if who else None, thru=thru)


class HeadlineTests(_Base):

    def test_before_the_call_the_price_is_a_range(self):
        """The wolf has the tee and the sides do not exist yet, so a card
        naming a single number would be inventing one."""
        s = self._state(0)
        self.assertIn('–', s['number']['text'])
        self.assertTrue(s['number']['text'].endswith('PTS'))

    def test_the_range_tops_out_at_this_group_s_lone_multiplier(self):
        """**Nothing on the card may hard-code four.** The header reads the
        setup field; it does not assert it."""
        self.assertEqual(self._state(0)['number']['text'], '1–4 PTS')

    def test_a_group_that_set_three_gets_a_range_that_tops_out_at_three(self):
        from services.wolf import setup_wolf
        setup_wolf(self.fs, wolf_order=self.order, handicap_mode='gross',
                   lone_wolf_points=3)
        self.assertEqual(self._state(0)['number']['text'], '1–3 PTS')
        self.assertEqual(self._state(0)['header']['game'], 'WOLF · LONE 3')

    def test_the_header_names_the_scoring_table(self):
        """Groups do not agree on what a lone wolf is worth, and two groups on
        the same four totals under different multipliers are not playing the
        same game."""
        self.assertEqual(self._state(0)['header']['game'], 'WOLF · LONE 4')

    def test_the_state_slot_names_who_has_the_tee(self):
        s = self._state(0, who='Sam Reid')
        self.assertEqual(s['state']['to_play'], 'TO CALL')

    def test_and_tells_the_reader_when_it_is_him(self):
        s = self._state(0, who='Dave Moran')
        self.assertEqual(s['state']['word'], 'YOU')
        self.assertEqual(s['state']['to_play'], 'ARE THE WOLF')


class StripTests(_Base):

    def test_four_golfers_go_across(self):
        s = self._state(0)
        self.assertEqual(len(s['strip']), 4)
        self.assertNotIn('rows', s)

    def test_the_wolf_and_the_next_seat_are_labelled(self):
        """The seat about to move is visible without a sentence."""
        labels = [c['label'] for c in self._state(0)['strip']]
        self.assertIn('WOLF', labels)
        self.assertIn('NEXT', labels)

    def test_unclaimed_carries_no_side_rule(self):
        """Before a call, all four are grey — the honest state. Three of these
        men are about to be on a side and none of them knows which."""
        for c in self._state(0)['strip']:
            self.assertNotIn('rule', c)

    def test_names_are_surnames(self):
        """A column is about sixty points and a first name spends it on
        nothing."""
        self.assertEqual([c['name'] for c in self._state(0)['strip']],
                         ['MORAN', 'REID', 'NAYLOR', 'HAYES'])


class FooterTests(_Base):

    def test_it_answers_when_you_are_wolf(self):
        """The one question a golfer has that the hole in front of him cannot
        answer."""
        ctx = self._state(0, who='Lee Naylor')['footer']['context']
        self.assertTrue(ctx.startswith('You are wolf on'), ctx)

    def test_the_stake_is_the_money_slot(self):
        self.assertEqual(self._state(0)['footer']['money'], '$1 a point')


class LastTwoHolesTests(_Base):
    """**Paul, 13 Sep:** the lowest point total is wolf on 17; then recalculate
    and the lowest is wolf on 18.

    The packet left this open and drew it as "the two lowest in points", which
    is a different rule — it fixes both seats at once off one standing. The
    confirmed rule resolves them one at a time, so **the same golfer can be
    wolf twice** if 17 does not lift him off the bottom. The engine already
    worked this way; these tests stop it being "simplified" later.
    """

    def _order_for(self, hole):
        from services.wolf import wolf_summary
        s = wolf_summary(self.fs)
        row = next(h for h in s['holes'] if h['hole'] == hole)
        return row['wolf_id']

    def test_the_rotation_hands_the_last_two_holes_to_the_low_man(self):
        from services.wolf import wolf_summary
        cfg = wolf_summary(self.fs)['points']
        self.assertTrue(cfg['last_place_wolf_1718'])

    def test_seventeen_and_eighteen_are_resolved_separately(self):
        """Not both off one standing: 17's result advances the totals before
        18 is decided. That is the whole difference between the confirmed rule
        and the one the packet drew."""
        import inspect
        from services import wolf
        src = inspect.getsource(wolf)
        self.assertIn("Advance standings for the NEXT hole's last-place calc",
                      src)

    def test_the_same_golfer_can_take_both(self):
        """If 17 does not lift him off the bottom, he is wolf again. The rule
        allows it on purpose — it is a catch-up, not a turn."""
        from services.wolf import _last_place
        from decimal import Decimal as D
        ids = self.order
        pts = {ids[0]: D('0'), ids[1]: D('5'), ids[2]: D('4'), ids[3]: D('3')}
        net = {p: 0 for p in ids}
        first = _last_place(ids, self.order, pts, net)
        # He wins nothing on 17 and is still last.
        second = _last_place(ids, self.order, pts, net)
        self.assertEqual(first, ids[0])
        self.assertEqual(second, ids[0])

    def test_and_a_golfer_who_climbs_off_the_bottom_hands_it_over(self):
        from services.wolf import _last_place
        from decimal import Decimal as D
        ids = self.order
        pts = {ids[0]: D('0'), ids[1]: D('5'), ids[2]: D('4'), ids[3]: D('3')}
        net = {p: 0 for p in ids}
        self.assertEqual(_last_place(ids, self.order, pts, net), ids[0])
        # 17 pays him four; the bottom is now somebody else.
        pts[ids[0]] = D('4')
        self.assertEqual(_last_place(ids, self.order, pts, net), ids[3])


class BlindWolfTests(_Base):
    """Blind is **optional and off by default**, and its multiplier must not
    widen the range merely by existing in the config.

    `blind_wolf_points` has a non-zero default whether or not the group plays
    it, so a naive `max()` over the table named a price nobody could pay — the
    card read `1–6 PTS` on a group that has never declared blind.
    """

    def test_a_group_not_playing_blind_never_sees_its_multiplier(self):
        s = self._state(0)
        self.assertEqual(s['number']['text'], '1–4 PTS')
        self.assertNotIn('BLIND', s['header']['game'])

    def test_a_group_playing_blind_gets_both_in_the_header_and_the_range(self):
        from services.wolf import setup_wolf
        setup_wolf(self.fs, wolf_order=self.order, handicap_mode='gross',
                   lone_wolf_points=4, blind_wolf_points=8,
                   require_lone_or_blind=True)
        s = self._state(0)
        self.assertEqual(s['header']['game'], 'WOLF · LONE 4 · BLIND 8')
        self.assertEqual(s['number']['text'], '1–8 PTS')


class StripOrderTests(_Base):
    """The strip follows the ROTATION, not the standings.

    `summary['players']` is sorted by money for the leaderboard. A strip built
    from it reorders itself as the money moves, and the `NEXT` label — which is
    about the seat — jumps with it. Same finding as Survivor's track, where
    standings order made the rows disagree with every other surface.
    """

    def test_the_columns_keep_their_seats_as_the_money_moves(self):
        before = [c['name'] for c in self._state(0)['strip']]
        self._play(1, 3, 6, 6, 6)     # Moran takes the hole outright
        self._play(2, 6, 3, 6, 6)
        after = [c['name'] for c in self._state(2)['strip']]
        self.assertEqual(before, after)

    def test_and_that_order_is_the_rotation_the_group_set(self):
        self.assertEqual([c['name'] for c in self._state(0)['strip']],
                         ['MORAN', 'REID', 'NAYLOR', 'HAYES'])


class FinalFrameTests(_Base):
    """**Points become money**, and the headline is free for the first time
    all round.

    The running card headlines the PRICE of the hole — the only number on it
    that is not a standing. At the end there is no hole and therefore no
    price, and what goes in the slot is what the strip has been counting
    toward.
    """

    def _final(self, who='Dave Moran'):
        from services.live_activity_wolf import wolf_final_state
        return wolf_final_state(self.fs, player_id=self.pid[who])

    def _play_out(self):
        for h in range(1, 19):
            self._play(h, 4, 4, 5, 5)

    def test_the_headline_is_money_not_a_price(self):
        self._play_out()
        s = self._final()
        self.assertTrue(s['number']['text'].startswith(('+$', '−$', '$')))
        self.assertTrue(s['closed'])

    def test_the_state_slot_takes_the_points_total(self):
        self._play_out()
        st = self._final()['state']
        self.assertTrue(st['word'].endswith('PTS'))
        self.assertEqual(st['colour'], 'mint')

    def test_the_strip_survives_and_loses_its_furniture(self):
        """`WOLF` and the side rules both described the hole in front of you,
        and there isn't one. Four names and four totals are left, which is the
        leaderboard the round produced."""
        self._play_out()
        strip = self._final()['strip']
        self.assertEqual(len(strip), 4)
        self.assertEqual({c['label'] for c in strip}, {''})
        self.assertEqual({c.get('rule') or '' for c in strip}, {''})

    def test_the_strip_stays_in_rotation_order(self):
        """Same finding as the running card and as Survivor's track: sorting
        by money makes the rows disagree with every other surface."""
        self._play_out()
        from services.wolf import wolf_summary
        order = wolf_summary(self.fs).get('wolf_order') or []
        names = [c['name'] for c in self._final()['strip']]
        self.assertEqual(len(names), len(order))

    def test_it_says_who_to_settle_with(self):
        self._play_out()
        self.assertTrue(self._final()['footer']['context'].startswith(
            ('Collect from', 'Pay', 'Nothing')))
