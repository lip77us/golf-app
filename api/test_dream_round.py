"""
api/test_dream_round.py
--------------------
The Dream Round's endpoints, its leaderboard block and its two settlement pots.

The engine is tested in `scoring/tests/test_dream_round.py`; what is here is the
wiring — and the two things the wiring decides on its own: that the
availability rule is enforced at the API rather than only greyed in the client,
and that the two pools settle as two games.
"""
from datetime import date

from django.test import TestCase
from rest_framework.test import APIClient

from accounts.models import Account, User
from games.models import DreamRoundConfig
from scoring.tests._helpers import (
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)

PAR = {h['number']: h['par'] for h in DEFAULT_HOLES}


class _Base(TestCase):
    def setUp(self):
        self.course = make_course('North Links')
        self.tee = make_tee(course=self.course, holes=DEFAULT_HOLES)
        self.tourn = make_tournament(name='Club Champs')
        self.tourn.total_rounds = 2
        self.tourn.save()

        self.ann = make_player('Ann', handicap_index=0)
        self.bea = make_player('Bea', handicap_index=0)
        self.rounds, self.foursomes = [], []
        for n in (1, 2):
            r = make_round(course=self.course, tournament=self.tourn,
                           round_number=n)
            r.date = date(2026, 10, 10 + n)
            r.save()
            self.rounds.append(r)
            self.foursomes.append(make_foursome(
                r, [(self.ann, 0), (self.bea, 0)], tee=self.tee))

        self.account = self.course.account
        self.user = User.objects.create_user(
            username='td', password='x', account=self.account,
            is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def url(self, suffix=''):
        return f'/api/tournaments/{self.tourn.id}/dream-round/{suffix}'

    def play(self, idx, player, offsets=None):
        for h in range(1, 19):
            submit_hole(self.foursomes[idx], h,
                        [(player.id, PAR[h] + (offsets or {}).get(h, 0))])


class SetupEndpointTests(_Base):
    def test_get_defaults_to_both_pools_on(self):
        r = self.client.get(self.url('setup/'))
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data['configured'])
        self.assertTrue(r.data['gross_on'])
        self.assertTrue(r.data['net_on'])
        self.assertTrue(r.data['available'])

    def test_the_gate_travels_with_the_config(self):
        # So the screen can say WHY it cannot be saved instead of the client
        # re-deriving the rule.
        self.rounds[1].num_holes = 9
        self.rounds[1].save(update_fields=['num_holes'])
        r = self.client.get(self.url('setup/'))
        self.assertFalse(r.data['available'])
        self.assertEqual(r.data['unavailable_reason'],
                         'Needs every round to be 18 holes')

    def test_post_saves_and_turns_the_game_on(self):
        r = self.client.post(self.url('setup/'), {
            'gross_on': True, 'net_on': True,
            'gross_entry_fee': '10.00',
            'gross_payouts': [{'place': 1, 'amount': '160.00'}],
            'net_entry_fee': '10.00',
            'net_payouts': [{'place': 1, 'amount': '160.00'}],
        }, format='json')
        self.assertEqual(r.status_code, 201)
        self.tourn.refresh_from_db()
        self.assertIn('dream_round', self.tourn.active_games)
        self.assertTrue(DreamRoundConfig.objects.filter(
            tournament=self.tourn).exists())

    def test_the_last_pool_cannot_be_turned_off(self):
        r = self.client.post(self.url('setup/'), {
            'gross_on': False, 'net_on': False,
        }, format='json')
        self.assertEqual(r.status_code, 400)

    def test_an_ineligible_event_is_REFUSED_not_just_greyed(self):
        # The rule is about the EVENT, and a round can be shortened after the
        # screen was drawn.
        self.rounds[1].num_holes = 9
        self.rounds[1].save(update_fields=['num_holes'])
        r = self.client.post(self.url('setup/'), {
            'gross_on': True, 'net_on': True,
        }, format='json')
        self.assertEqual(r.status_code, 400)
        self.assertIn('18 holes', r.data['detail'])
        self.assertFalse(DreamRoundConfig.objects.filter(
            tournament=self.tourn).exists())

    def test_a_one_round_event_is_refused(self):
        self.rounds[1].delete()
        r = self.client.post(self.url('setup/'), {'gross_on': True},
                             format='json')
        self.assertEqual(r.status_code, 400)

    def test_delete_turns_the_game_off(self):
        self.client.post(self.url('setup/'), {'gross_on': True, 'net_on': True},
                         format='json')
        r = self.client.delete(self.url('setup/'))
        self.assertEqual(r.status_code, 204)
        self.tourn.refresh_from_db()
        self.assertNotIn('dream_round', self.tourn.active_games)
        self.assertFalse(DreamRoundConfig.objects.filter(
            tournament=self.tourn).exists())

    def test_another_account_gets_404(self):
        other = Account.objects.create(name='Someone Else')
        user = User.objects.create_user(username='x', password='x',
                                        account=other, is_account_admin=True)
        c = APIClient()
        c.force_authenticate(user)
        self.assertEqual(c.get(self.url('setup/')).status_code, 404)


class ResultEndpointTests(_Base):
    def setUp(self):
        super().setUp()
        DreamRoundConfig.objects.create(
            tournament=self.tourn, gross_entry_fee=10,
            gross_payouts=[{'place': 1, 'amount': 160}],
            net_entry_fee=10, net_payouts=[{'place': 1, 'amount': 160}])
        self.tourn.active_games = ['dream_round']
        self.tourn.save(update_fields=['active_games'])

    def test_the_result_carries_both_pools_and_the_cards(self):
        self.play(0, self.ann, {3: -1})
        self.play(1, self.ann)
        r = self.client.get(self.url())
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data['pools'], ['gross', 'net'])
        self.assertEqual(r.data['gross']['standings'][0]['total'], -1)
        card = r.data['gross']['cards'][self.ann.id]
        self.assertEqual(len(card['rounds']), 2)
        self.assertEqual(card['best'][3], -1)

    def test_the_leaderboard_gains_an_dream_round_block(self):
        self.play(0, self.ann)
        r = self.client.get(f'/api/tournaments/{self.tourn.id}/leaderboard/')
        self.assertEqual(r.status_code, 200)
        self.assertIn('dream_round', r.data['games'])
        self.assertEqual(r.data['games']['dream_round']['label'], 'Dream Round')

    def test_the_tab_exists_BEFORE_the_config_does(self):
        # **How a TD finds the setup.** Hiding the tab until he has configured
        # the game means he has to already know it is there — and the setup was
        # genuinely unreachable that way, reported from testing.
        self.tourn.dream_round_config.delete()
        self.tourn.refresh_from_db()
        r = self.client.get(f'/api/tournaments/{self.tourn.id}/leaderboard/')
        block = r.data['games']['dream_round']
        self.assertEqual(block['label'], 'Dream Round')
        self.assertEqual(block['pools'], [])
        self.assertFalse(block['configured'])
        self.assertTrue(block['available'])

    def test_dream_round_on_a_ROUND_still_reaches_the_tournament_board(self):
        # The wizard puts it on the tournament; the per-round picker can put it
        # on a round. A TD who did that has said his event plays it, and the
        # game must not be unreachable because of where he said it.
        self.tourn.active_games = ['low_net']
        self.tourn.save(update_fields=['active_games'])
        self.rounds[0].active_games = ['dream_round']
        self.rounds[0].save(update_fields=['active_games'])
        r = self.client.get(f'/api/tournaments/{self.tourn.id}/leaderboard/')
        self.assertIn('dream_round', r.data['active_games'])
        self.assertIn('dream_round', r.data['games'])

    def test_no_block_when_the_game_is_off(self):
        self.tourn.active_games = []
        self.tourn.save(update_fields=['active_games'])
        for r in self.rounds:
            r.active_games = []
            r.save(update_fields=['active_games'])
        r = self.client.get(f'/api/tournaments/{self.tourn.id}/leaderboard/')
        self.assertNotIn('dream_round', r.data['games'])


class SettlementTests(_Base):
    def setUp(self):
        super().setUp()
        DreamRoundConfig.objects.create(
            tournament=self.tourn, gross_entry_fee=10,
            gross_payouts=[{'place': 1, 'amount': 20}],
            net_entry_fee=10, net_payouts=[{'place': 1, 'amount': 20}])
        self.tourn.active_games = ['dream_round']
        self.tourn.save(update_fields=['active_games'])

    def _settle(self):
        from services.tournament_settlement import tournament_settlement
        return tournament_settlement(self.tourn)

    def test_two_pools_are_two_games_each_balancing_on_its_own(self):
        self.play(0, self.ann, {3: -1})
        self.play(1, self.ann)
        self.play(0, self.bea)
        self.play(1, self.bea)
        s = self._settle()
        keys = {g['key']: g for g in s['games']}
        self.assertIn('dream_round_gross', keys)
        self.assertIn('dream_round_net', keys)
        for k in ('dream_round_gross', 'dream_round_net'):
            self.assertEqual(keys[k]['entries_in'], 20.0)   # $10 × 2 golfers
            self.assertEqual(keys[k]['prizes_out'], 20.0)
            self.assertTrue(keys[k]['balanced'])

    def test_the_label_takes_no_round_suffix(self):
        # It is the one side game that spans the event.
        s = self._settle()
        labels = {g['label'] for g in s['games']}
        self.assertIn('Dream Round · Gross', labels)
        self.assertNotIn('Dream Round · Gross · R2', labels)

    def test_the_prize_line_names_the_tie_and_the_split(self):
        # Both level: they share 1st, $20 becomes $10 each, and the line has
        # to say why a golfer expecting $20 got $10.
        self.play(0, self.ann)
        self.play(1, self.ann)
        self.play(0, self.bea)
        self.play(1, self.bea)
        s = self._settle()
        ann = next(g for g in s['golfers'] if g['player_id'] == self.ann.id)
        prize = next(p for p in ann['prizes']
                     if p['game'] == 'Dream Round · Gross')
        self.assertEqual(prize['amount'], 10.0)
        self.assertEqual(prize['detail'], 'Dream Round Gross, T1 (2 ways)')

    def test_a_pool_that_is_off_has_no_pot(self):
        cfg = self.tourn.dream_round_config
        cfg.net_on = False
        cfg.save(update_fields=['net_on'])
        self.play(0, self.ann)
        s = self._settle()
        keys = {g['key'] for g in s['games']}
        self.assertIn('dream_round_gross', keys)
        self.assertNotIn('dream_round_net', keys)

    def test_every_golfer_in_the_field_pays_both_entries(self):
        self.play(0, self.ann)
        s = self._settle()
        bea = next(g for g in s['golfers'] if g['player_id'] == self.bea.id)
        games = [e['game'] for e in bea['entries']]
        self.assertIn('Dream Round · Gross', games)
        self.assertIn('Dream Round · Net', games)


class ReachabilityTests(_Base):
    """**The only door was behind the door.**

    The Dream Round tab and the gear's `Configure Dream Round` both keyed off the
    tournament's `active_games`, and the thing that PUTS it there is the
    setup POST — so an event created without Dream Round had no way to reach the
    screen that would turn it on. Reported from testing twice.

    The leaderboard now carries the offer whether or not the game is on.
    """

    def board(self):
        return self.client.get(
            f'/api/tournaments/{self.tourn.id}/leaderboard/').data

    def test_an_event_that_never_turned_it_on_is_still_offered_it(self):
        self.assertNotIn('dream_round', self.tourn.active_games or [])
        offer = self.board()['dream_round_offer']
        self.assertTrue(offer['offer'])
        self.assertTrue(offer['available'])
        self.assertFalse(offer['configured'])

    def test_setting_it_up_turns_it_on_and_the_offer_says_so(self):
        resp = self.client.post(self.url('setup/'), {
            'pools': ['gross'],
            'gross_entry_fee': '10.00', 'gross_payouts': [],
            'net_entry_fee': '0.00', 'net_payouts': [],
        }, format='json')
        self.assertIn(resp.status_code, (200, 201))
        offer = self.board()['dream_round_offer']
        self.assertTrue(offer['configured'])
        self.assertTrue(offer['available'])

    def test_a_one_round_event_is_not_offered_it_at_all(self):
        # Not a condition to explain — the wrong shape of event. The wizard
        # hides its entry for the same reason rather than disabling it.
        self.rounds[1].delete()
        offer = self.board()['dream_round_offer']
        self.assertFalse(offer['offer'])

    def test_a_nine_hole_round_is_offered_it_DISABLED_with_the_reason(self):
        # Two rounds, so the event is the right shape; one of them is not.
        self.rounds[1].num_holes = 9
        self.rounds[1].save()
        offer = self.board()['dream_round_offer']
        self.assertTrue(offer['offer'])
        self.assertFalse(offer['available'])
        self.assertEqual(offer['reason'], 'Needs every round to be 18 holes')


class TournamentCardOfferTests(_Base):
    """The tournament LIST carries the offer too, for the card's own button.

    The gear is an unlabelled icon two screens deep — the spot `Settle up`
    hid in until it was given a name on this card. The offer is computed
    server-side in both places so the rule has one home.
    """

    def card(self):
        rows = self.client.get('/api/tournaments/').data
        rows = rows if isinstance(rows, list) else rows['results']
        return next(t for t in rows if t['id'] == self.tourn.id)

    def test_a_two_round_event_is_offered_it_before_it_plays_it(self):
        offer = self.card()['dream_round_offer']
        self.assertTrue(offer['offer'])
        self.assertTrue(offer['available'])
        self.assertFalse(offer['configured'])

    def test_a_one_round_event_is_not(self):
        self.rounds[1].delete()
        self.assertFalse(self.card()['dream_round_offer']['offer'])

    def test_the_list_and_the_board_agree(self):
        board = self.client.get(
            f'/api/tournaments/{self.tourn.id}/leaderboard/').data
        self.assertEqual(self.card()['dream_round_offer'],
                         board['dream_round_offer'])


class RoundBoardTests(_Base):
    """Dream Round is a tournament game and never a ROUND tab.

    The individual wizard writes side games onto the rounds, so a round in an
    Dream Round event carries the slug. The round leaderboard has no Dream Round
    block to draw — the game spans the event and is built one level up — so
    the tab came up lowercase and empty: `dream_round` over `No data yet.`
    """

    def test_the_round_board_does_not_offer_an_dream_round_tab(self):
        r = self.rounds[0]
        r.active_games = ['dream_round']
        r.save()
        data = self.client.get(f'/api/rounds/{r.id}/leaderboard/').data
        board = data.get('leaderboard', data)
        self.assertNotIn('dream_round', board['active_games'])
        self.assertNotIn('dream_round', board['games'])

    def test_the_tournament_board_still_reads_the_rounds(self):
        # The same slug on the round is what tells the EVENT it plays one —
        # a different question, asked one level up.
        self.tourn.active_games = []
        self.tourn.save()
        self.rounds[0].active_games = ['dream_round']
        self.rounds[0].save()
        board = self.client.get(
            f'/api/tournaments/{self.tourn.id}/leaderboard/').data
        self.assertIn('dream_round', board['active_games'])
        self.assertIn('dream_round', board['games'])
