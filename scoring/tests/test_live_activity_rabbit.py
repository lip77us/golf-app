"""
scoring/tests/test_live_activity_rabbit.py
------------------------------------------
The Rabbit lock screen
(docs/design-review/handoff-live-activities/rabbit-HANDOFF.md).

Like the Sixes tests, these check the PROJECTION rather than the golf — that
mint means held and nothing else, that a word never wears a number's meaning,
that the money slot stays empty until something has actually paid, and that the
header never prints a denominator.
"""
from django.test import TestCase

from services.live_activity_rabbit import rabbit_activity_state
from services.rabbit import setup_rabbit
from ._helpers import make_foursome, make_round, make_tee, submit_hole


class RabbitActivityTests(TestCase):
    """Three golfers, three rabbits, gross — so the nets are the scores and the
    tests read as the golf did."""

    def setUp(self):
        from services.rabbit import HandicapMode
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.active_games = ['rabbit']
        self.round.primary_game = 'rabbit'
        self.round.save(update_fields=['active_games', 'primary_game'])
        self.fs = make_foursome(
            self.round, [('Dave', 0), ('Paul', 0), ('Sam', 0)], tee=self.tee)
        self.pid = {m.player.name: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        setup_rabbit(self.fs, handicap_mode=HandicapMode.GROSS,
                     num_segments=3, extra_rabbits=True)

    def _play(self, hole, dave, paul, sam):
        submit_hole(self.fs, hole, [(self.pid['Dave'], dave),
                                    (self.pid['Paul'], paul),
                                    (self.pid['Sam'], sam)])

    def _state(self, thru=None, who='Paul'):
        return rabbit_activity_state(self.fs, player_id=self.pid[who],
                                     thru=thru)

    # -- the number is a lead, not a score --------------------------------

    def test_nobody_holds_it_at_the_start(self):
        self._play(1, 4, 4, 4)          # halved — nobody takes it
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], 'LOOSE')
        self.assertEqual(s['state']['word'], 'LOOSE')

    def test_winning_a_hole_takes_the_rabbit(self):
        self._play(1, 3, 4, 4)          # Dave outright
        s = self._state(thru=1)
        self.assertEqual(s['number']['text'], '+1')
        self.assertEqual(s['number']['colour'], 'mint')
        self.assertEqual(s['state']['word'], 'HELD')

    def test_a_lead_run_down_to_zero_is_loose_not_plus_zero(self):
        """`+0` is not a state. A lead run to zero has freed the rabbit, and a
        zero in a lead's slot reads like a margin."""
        self._play(1, 3, 4, 4)          # Dave holds, +1
        self._play(2, 4, 4, 4)          # halved
        s = self._state(thru=2)
        self.assertNotEqual(s['number']['text'], '+0')

    # -- mint is held, and nothing else -----------------------------------

    def test_only_the_holder_wears_mint(self):
        """Sixes could not use mint for a number because mint is the app's
        colour and picks neither side. Rabbit has one distinguished party."""
        self._play(1, 3, 4, 4)
        s = self._state(thru=1)
        self.assertEqual(s['number']['colour'], 'mint')
        self.assertEqual(s['sides'][0]['colour'], 'mint')
        self.assertEqual(s['sides'][1]['colour'], 'dim')

    def test_loose_puts_all_three_on_one_dim_line(self):
        """There is no leader to name, and the card should not imply one by
        putting somebody first."""
        self._play(1, 4, 4, 4)
        s = self._state(thru=1)
        self.assertEqual(len(s['sides']), 1)
        self.assertEqual(s['sides'][0]['colour'], 'dim')
        # Short names — three full ones do not fit a line, and the holder line
        # is the only place a full name is affordable.
        self.assertEqual(s['sides'][0]['names'].count(','), 2)

    # -- the header never prints a denominator ----------------------------

    def test_the_header_names_the_rabbit_and_its_real_holes(self):
        self._play(1, 3, 4, 4)
        seg = self._state(thru=1)['header']['segment']
        self.assertEqual(seg, 'RABBIT 1 · HOLES 1-6')

    def test_never_a_denominator(self):
        """A round that opens as three rabbits can finish as five."""
        self._play(1, 3, 4, 4)
        seg = self._state(thru=1)['header']['segment']
        self.assertNotIn(' of ', seg)
        self.assertNotIn('/3', seg)

    # -- LOCKED is the DORMIE analogue ------------------------------------

    def test_an_early_lock_moves_the_card_to_the_next_rabbit(self):
        """With extra rabbits on, a lock ENDS the leg — so the card is already
        on the next rabbit and the push is what announces the move.  A lock on
        the 4th makes the next one holes 5-10: a full six for a full stake, not
        the tail of the old window."""
        for hole in range(1, 5):
            self._play(hole, 3, 4, 4)   # Dave +4 with 2 of rabbit 1 to play
        s = self._state(thru=4)
        self.assertEqual(s['header']['segment'], 'RABBIT 2 · HOLES 5-10')
        self.assertEqual(s['state']['word'], 'LOOSE')

    def test_locked_shows_while_a_decided_leg_plays_out(self):
        """`lead > holes_remaining` — the Sixes DORMIE analogue.  Reachable
        when the leg is not cut short, which is the extra-rabbits-off game."""
        from services.rabbit import HandicapMode
        setup_rabbit(self.fs, handicap_mode=HandicapMode.GROSS,
                     num_segments=3, extra_rabbits=False)
        for hole in range(1, 5):
            self._play(hole, 3, 4, 4)
        s = self._state(thru=4)
        self.assertEqual(s['state']['word'], 'LOCKED')
        self.assertEqual(s['number']['text'], '+4')

    # -- money is settled only --------------------------------------------

    def test_the_money_slot_is_empty_until_a_rabbit_closes(self):
        """Not `$0`. A rabbit in progress is worth nothing yet, and a zero
        implies it was played for nothing."""
        self._play(1, 3, 4, 4)
        self.assertEqual(self._state(thru=1)['footer']['money'], '')

    def test_the_ladder_the_packet_draws(self):
        """`the holder takes the stake from each of the other two` — +$10 to
        the holder and −$5 each at $5 a rabbit. The packet's ladder had to be
        corrected twice in the prototype, so it is a test here."""
        for hole in range(1, 7):        # Dave wins rabbit 1 outright
            self._play(hole, 3, 4, 4)
        paul = self._state(thru=6, who='Paul')['footer']['money']
        dave = self._state(thru=6, who='Dave')['footer']['money']
        self.assertEqual(paul, '-$5')
        self.assertEqual(dave, '+$10')

    # -- the run strip is generated, never fixed --------------------------

    def test_the_run_strip_is_as_long_as_the_round_actually_ran(self):
        self._play(1, 3, 4, 4)
        s = self._state(thru=1)
        self.assertGreaterEqual(len(s['pips']), 3)
        self.assertIn('live', s['pips'])

    # -- the footer -------------------------------------------------------

    def test_the_footer_carries_gross_thru_and_the_stake(self):
        self._play(1, 3, 4, 4)
        ctx = self._state(thru=1)['footer']['context']
        self.assertIn('Thru 1', ctx)
        self.assertIn('a rabbit', ctx)


class RabbitDispatchTests(TestCase):
    """The registry hands Rabbit its own card, and stamps the kind the Swift
    switches layouts on."""

    def setUp(self):
        from django.contrib.auth import get_user_model
        from services.rabbit import HandicapMode
        tee = make_tee()
        self.round = make_round(tee.course)
        self.round.active_games = ['rabbit']
        self.round.primary_game = 'rabbit'
        self.round.save(update_fields=['active_games', 'primary_game'])
        fs = make_foursome(self.round,
                           [('Dave', 0), ('Paul', 0), ('Sam', 0)], tee=tee)
        pid = [m.player_id for m in fs.memberships.all()]
        setup_rabbit(fs, handicap_mode=HandicapMode.GROSS, num_segments=3,
                     extra_rabbits=True)
        submit_hole(fs, 1, [(pid[0], 3), (pid[1], 4), (pid[2], 4)])
        self.user = get_user_model().objects.create_user(
            username='td', account=self.round.account)
        self.user.is_account_admin = True
        self.user.save(update_fields=['is_account_admin'])

    def test_the_kind_is_rabbit(self):
        from services.live_activity_registry import activity_state
        self.assertEqual(activity_state(self.round, self.user)['kind'],
                         'rabbit')

    def test_every_slot_the_swift_decodes_is_present(self):
        from services.live_activity_registry import activity_state
        state = activity_state(self.round, self.user)
        self.assertEqual(set(state),
                         {'kind', 'header', 'number', 'sides', 'state', 'pips',
                          'final', 'footer'})
        self.assertEqual(set(state['number']), {'text', 'colour'})
        self.assertEqual(set(state['state']),  {'word', 'to_play'})
        self.assertEqual(set(state['footer']), {'context', 'money'})
        for side in state['sides']:
            self.assertEqual(set(side), {'names', 'colour', 'leading'})

    def test_the_header_accent_is_only_on_the_extra(self):
        """The extra is the one leg playing for a different amount, which is
        what earns it a different colour.  An early-lock rabbit is mint."""
        from services.live_activity_registry import activity_state
        self.assertNotIn('accent', activity_state(self.round, self.user)
                         ['header'])
