"""A Multi-Group Skins round settles, and gets a receipt.

Reported from a live round (Paul, 9 Nov 2026): *"we played a multi group
skins side game and this didn't seem to finish correctly and there was no
receipt."*

`multi_skins` was never in `settlement.NETTABLE`, so a round whose only
money game was the pool produced no settlement at all — and
`build_round_receipt` has nothing to build from. The third time an engine
with a zero-sum ledger turned out never to have been wired in: Nassau,
Rabbit and Survivor were the first, Banker and Sequoya the second.
"""
from decimal import Decimal

from django.test import TestCase

from services.multi_skins import (calculate_multi_skins, multi_skins_summary,
                                  setup_multi_skins)
from services.receipt_build import build_round_receipt
from services.settlement import round_settlement

from scoring.tests._helpers import (make_foursome, make_round, make_tee,
                                    submit_hole)


class _PoolBase(TestCase):
    """Two groups, one pot — the shape the reported round had."""

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.round.active_games = ['multi_skins']
        self.round.primary_game = 'multi_skins'
        self.round.bet_unit = Decimal('5')
        self.round.save()
        self.a = make_foursome(self.round, [('Jim Diederich', 0),
                                            ('Paul Lipkin', 0)],
                               tee=self.tee, group_number=1)
        self.b = make_foursome(self.round, [('Larry Sanders', 0),
                                            ('Wendell Doman', 0)],
                               tee=self.tee, group_number=2)
        self.ids = [m.player_id for fs in (self.a, self.b)
                    for m in fs.memberships.all()]
        setup_multi_skins(self.round, self.ids, handicap_mode='gross',
                          bet_unit=5)

    def _play(self):
        """Jim takes every hole outright, so the pot pays one golfer."""
        for h in range(1, 19):
            submit_hole(self.a, h, [(self.ids[0], 3), (self.ids[1], 5)])
            submit_hole(self.b, h, [(self.ids[2], 5), (self.ids[3], 5)])
        calculate_multi_skins(self.round)


class ThePoolSettlesTests(_PoolBase):

    def test_the_summary_carries_a_signed_zero_sum_net(self):
        self._play()
        nets = [p['net'] for p in multi_skins_summary(self.round)['players']]
        self.assertAlmostEqual(sum(nets), 0.0, places=2)
        self.assertEqual(len([n for n in nets if n > 0]), 1,
                         'one golfer took every skin')

    def test_nobody_is_charged_until_a_skin_is_WON(self):
        """A pot that has paid nothing must not leave four losses and no
        winner — the same rule the tournament pool's pot uses."""
        for h in range(1, 19):          # every hole halved across the field
            submit_hole(self.a, h, [(self.ids[0], 4), (self.ids[1], 4)])
            submit_hole(self.b, h, [(self.ids[2], 4), (self.ids[3], 4)])
        calculate_multi_skins(self.round)
        s = multi_skins_summary(self.round)
        self.assertEqual(s['money']['total_skins'], 0)
        self.assertEqual([p['net'] for p in s['players']], [0.0] * 4)

    def test_the_round_settles(self):
        self._play()
        st = round_settlement(self.round, min_games=1)
        self.assertIsNotNone(st, 'the pool was never in NETTABLE')
        self.assertAlmostEqual(
            sum(p['net'] for p in st['players']), 0.0, places=2)
        self.assertIn('multi_skins', {g['game'] for g in st['per_game']})

    def test_and_it_gets_a_receipt(self):
        self._play()
        self.round.status = 'complete'
        self.round.save(update_fields=['status'])
        r = build_round_receipt(self.round)
        self.assertIsNotNone(r, 'the whole report was that there was none')
        blob = str(r.payload)
        self.assertIn('Multi-Group Skins', blob)

    def test_the_receipt_says_what_the_pot_paid(self):
        self._play()
        self.round.status = 'complete'
        self.round.save(update_fields=['status'])
        payload = build_round_receipt(self.round).payload
        sections = payload.get('webGames') or payload.get('games') or []
        blob = str(sections)
        self.assertIn('The pool', blob)
        self.assertIn('18 skins', blob,
                      'a pool divides ONE pot by the count, so the count is '
                      'the only way a golfer can check his share')


class ACrossRoundPoolIsNotThisRoundsToSettleTests(_PoolBase):
    """Half its golfers are not on this receipt.

    Netting the slice that IS would hand somebody a figure that is not what
    he is owed, so the engine says which case it is and settlement does not
    guess.
    """

    def test_a_linked_round_makes_the_pool_unsettleable_here(self):
        self._play()
        self.assertTrue(multi_skins_summary(self.round)['round_local'])

        other = make_round(self.tee.course, handicap_mode='gross')
        from games.models import MultiSkinsLinkedRound
        MultiSkinsLinkedRound.objects.create(
            game=self.round.multi_skins_game, round=other,
            linked_by_id=self.ids[0])

        self.assertFalse(multi_skins_summary(self.round)['round_local'])
        self.assertIsNone(round_settlement(self.round, min_games=1),
                          'a pool that spans rounds is not round-scoped')


class AGroupThatNeverPostedTakesTheWholePoolDownTests(_PoolBase):
    """The other half of the report — *"this didn't seem to finish
    correctly"*.

    **A pool hole counts only once EVERY participant has a score on it.**
    That is right for a live pool: you cannot award a skin before everybody
    has played the hole. What it means when one group never posts is that
    NO hole counts — for anybody, including the golfers who entered their
    own cards. The pot awards nothing, nobody is charged, and the round
    cannot auto-complete.

    CLAUDE.md records the same trap from the paper-card side ("enter a pool
    member's card in full or not at all"). This pins it from the
    settlement side, because it is the reason a receipt can still be
    missing after the wiring above is fixed.

    **This is NOT what the reported round was.** That one's group 1 was a
    separate LINKED round (primary Sixes) whose golfers were also seated,
    unscored, in the host round — the pool read their real scores through
    `_resolve_participant_memberships`, and what stuck was
    `_all_foursomes_done`, which only ever looks at the host round's own
    foursomes. Kept because the case below is real on its own and is the
    one a single-round pool hits.
    """

    def _half(self):
        """Group 1 plays its whole card; group 2 never tees off."""
        for h in range(1, 19):
            submit_hole(self.a, h, [(self.ids[0], 3), (self.ids[1], 5)])
        calculate_multi_skins(self.round)

    def test_no_hole_counts_for_the_pool(self):
        self._half()
        s = multi_skins_summary(self.round)
        self.assertEqual(s['money']['total_skins'], 0)
        self.assertTrue(all(p['skins_won'] == 0 for p in s['players']),
                        'a hole one group has not played awards nothing')

    def test_so_nobody_is_charged_the_ante(self):
        self._half()
        nets = {p['name']: p['net'] for p in
                multi_skins_summary(self.round)['players']}
        self.assertEqual(set(nets.values()), {0.0},
                         f'a pot that paid nothing charged somebody: {nets}')

    def test_and_there_is_still_no_receipt_to_build(self):
        """Not a regression — the right answer. A staked round that settles
        to nothing produces no transfers, and four `+$0` lines texted to a
        group say nothing. The fix for THIS round is the missing card, not
        the receipt."""
        self._half()
        self.assertIsNone(build_round_receipt(self.round))

    def test_the_full_card_is_what_makes_the_difference(self):
        """Same fixture, same pot — the only change is that the second
        group posts. One assertion against the other is what says the
        missing scores are the cause."""
        self._play()
        self.assertEqual(
            multi_skins_summary(self.round)['money']['total_skins'], 18)
        self.assertIsNotNone(build_round_receipt(self.round))
