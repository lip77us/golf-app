"""A seat held for a LINKED round is not a group still out.

Reported 9 Nov 2026 with a screenshot whose board read **Final** — four
golfers thru 18, 8 skins, the $20 pool paid out — directly under a banner
reading **"1 still out of 2 — the board is not final. Group 1 (thru 0)."**

Both were reading real data. Paul: *"group 1 completed our round as a
linked round. The primary was sixes."* Those golfers were parked in the
host round so they were on the pool's roster, and they scored in their own
Sixes round. `_resolve_participant_memberships` follows them there — its
docstring names this very case — so the POOL was right. Nothing else
followed them, so the board and `RoundCompleteView` kept waiting on a seat
that could never be filled.

The fixture is the screenshot: a host round seating everybody, and a linked
Sixes round where the scores actually go.
"""
from decimal import Decimal

from django.test import TestCase

from api.views import RoundCompleteView, _field_progress
from games.models import MultiSkinsLinkedRound
from services.multi_skins import (calculate_multi_skins, multi_skins_summary,
                                  parked_foursome_ids, setup_multi_skins)

from scoring.tests._helpers import (make_foursome, make_round, make_tee,
                                    submit_hole)


class _ParkedBase(TestCase):
    """Host round: group 1 parked, group 2 real. Linked round: the scores."""

    def setUp(self):
        self.tee  = make_tee()
        self.host = make_round(self.tee.course, handicap_mode='gross')
        self.host.active_games = ['multi_skins']
        self.host.primary_game = 'multi_skins'
        self.host.bet_unit = Decimal('5')
        self.host.save()

        self.parked = make_foursome(
            self.host, [('Jim Diederich', 0), ('Paul Lipkin', 0)],
            tee=self.tee, group_number=1)
        self.here = make_foursome(
            self.host, [('Larry Sanders', 0), ('Wendell Doman', 0)],
            tee=self.tee, group_number=2)

        self.pids = {m.player.name: m.player_id
                     for fs in (self.parked, self.here)
                     for m in fs.memberships.all()}
        setup_multi_skins(self.host, list(self.pids.values()),
                          handicap_mode='gross', bet_unit=5)

        # The group's OWN round — the one they actually played.
        self.linked = make_round(self.tee.course, handicap_mode='gross')
        self.linked.active_games = ['sixes']
        self.linked.primary_game = 'sixes'
        self.linked.save()
        # The SAME Player rows — a golfer's own round in his own account
        # reuses the roster, which is what lets the resolver follow him.
        # (Across accounts it is the phone that matches; same mechanism,
        # one step longer, and not what this test is about.)
        from core.models import Player
        self.lfs = make_foursome(
            self.linked,
            [(Player.objects.get(pk=self.pids[n]), 0)
             for n in ('Jim Diederich', 'Paul Lipkin')],
            tee=self.tee, group_number=1)
        self.lpids = {m.player.name: m.player_id
                      for m in self.lfs.memberships.all()}
        MultiSkinsLinkedRound.objects.create(
            game=self.host.multi_skins_game, round=self.linked,
            linked_by_id=self.pids['Jim Diederich'])

    def _play(self):
        """Everybody posts — group 2 in the host round, group 1 in theirs."""
        for h in range(1, 19):
            submit_hole(self.here, h, [(self.pids['Larry Sanders'], 5),
                                       (self.pids['Wendell Doman'], 5)])
            submit_hole(self.lfs, h, [(self.lpids['Jim Diederich'], 3),
                                      (self.lpids['Paul Lipkin'], 5)])
        calculate_multi_skins(self.host)


class TheSeatIsNotAGroupStillOutTests(_ParkedBase):

    def test_the_parked_seat_is_named(self):
        self._play()
        self.assertEqual(parked_foursome_ids(self.host), {self.parked.id})

    def test_the_board_does_not_report_it_as_missing(self):
        """The symptom: `1 still out of 2` over a board reading Final."""
        self._play()
        fp = _field_progress(self.host, list(self.host.foursomes.all()))
        missing = [r['group_number'] for r in (fp or {}).get('awaiting', [])]
        self.assertEqual(missing, [],
                         f'a parked seat was reported as still out: {fp}')

    def test_the_round_can_now_be_completed(self):
        self._play()
        self.assertTrue(RoundCompleteView._all_foursomes_done(self.host))

    def test_the_force_dialog_does_not_name_it_either(self):
        """The gate and the dialog have to agree, or the TD reads a list he
        cannot act on."""
        self._play()
        groups = RoundCompleteView._groups_outstanding(self.host)
        self.assertEqual(groups, [])

    def test_the_pool_still_reads_the_linked_round(self):
        """The half that was already right — and the reason the board said
        Final. Everybody is thru 18 even though half of them never posted a
        hole in this round."""
        self._play()
        s = multi_skins_summary(self.host)
        self.assertEqual({p['thru'] for p in s['players']}, {18})
        self.assertGreater(s['money']['total_skins'], 0)


class TheRuleIsNarrowTests(_ParkedBase):
    """Each clause earns its place: without one of them this would start
    exempting groups that really are still out."""

    def test_a_seat_with_any_score_is_not_parked(self):
        self._play()
        submit_hole(self.parked, 1, [(self.pids['Jim Diederich'], 4)])
        self.assertEqual(parked_foursome_ids(self.host), set())

    def test_no_linked_round_means_nothing_is_ever_parked(self):
        """An ordinary single-round pool is untouched — which is every
        round that is not this shape."""
        self.host.multi_skins_game.linked_rounds.all().delete()
        self._play()
        self.assertEqual(parked_foursome_ids(self.host), set())

    def test_a_round_with_no_pool_is_untouched(self):
        plain = make_round(self.tee.course, handicap_mode='gross')
        make_foursome(plain, [('A', 0)], tee=self.tee, group_number=1)
        make_foursome(plain, [('B', 0)], tee=self.tee, group_number=2)
        self.assertEqual(parked_foursome_ids(plain), set())

    def test_a_group_that_is_genuinely_out_is_still_reported(self):
        """The clause that matters most: parking must not sweep up a group
        that really is still on the course.

        A THIRD host group is added so there is still a field to be missing
        from after the parked seat comes out — otherwise the board returns
        None on the shipped `<2 groups` rule and this would pass without
        reporting anything, which is not what the name claims.
        """
        third = make_foursome(self.host, [('Steve Etingoff', 0)],
                              tee=self.tee, group_number=3)
        self._play()                      # groups 1 and 2 are in
        # Group 3 posts nothing and is in no linked round.
        fp = _field_progress(self.host, list(self.host.foursomes.all()))
        self.assertEqual([r['group_number'] for r in fp['awaiting']], [3],
                         f'the real group went missing from the board: {fp}')
        self.assertEqual(fp['groups'], 2, 'the parked seat is not a group')
        self.assertFalse(RoundCompleteView._all_foursomes_done(self.host))
        self.assertEqual(
            [g['group_number']
             for g in RoundCompleteView._groups_outstanding(self.host)], [3])
