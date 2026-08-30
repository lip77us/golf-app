"""
api/test_settlement_receipt.py
------------------------------
Receipt composition (handoff-settlement-receipt).

Composition is a pure function of settled data — same input, same string — so
it is tested as one, with no screen and no database in the way.
"""
from django.test import SimpleTestCase

from services.settlement_receipt import (
    compose_field, compose_personal, money, sms_segments,
)


class MoneyTests(SimpleTestCase):
    """One formatter. Two formatters means two answers."""

    def test_display_uses_a_real_minus(self):
        self.assertEqual(money(-120), '−$120')
        self.assertEqual(money(84), '$84')

    def test_plain_is_ascii_and_always_signed(self):
        self.assertEqual(money(-120, plain=True), '-$120')
        self.assertEqual(money(84, plain=True), '+$84')

    def test_whole_dollars_lose_the_cents(self):
        self.assertEqual(money(60), '$60')
        self.assertEqual(money(60.5), '$60.50')

    def test_zero_is_not_negative(self):
        self.assertEqual(money(0), '$0')


class SegmentTests(SimpleTestCase):
    """Length is shown as messages, not characters."""

    def test_short_ascii_is_one_message(self):
        r = sms_segments('Settled. You collect $84.')
        self.assertEqual(r['segments'], 1)
        self.assertEqual(r['encoding'], 'GSM-7')

    def test_160_ascii_chars_is_still_one(self):
        self.assertEqual(sms_segments('a' * 160)['segments'], 1)
        self.assertEqual(sms_segments('a' * 161)['segments'], 2)

    def test_one_typographic_dash_forces_ucs2_and_costs_messages(self):
        """
        The expensive surprise this counter exists to prevent: a single
        non-GSM character re-encodes the whole message at 70 chars a segment.
        """
        plain = 'a' * 150
        fancy = plain[:-1] + '—'
        self.assertEqual(sms_segments(plain)['segments'], 1)
        self.assertEqual(sms_segments(fancy)['encoding'], 'UCS-2')
        self.assertEqual(sms_segments(fancy)['segments'], 3)
        self.assertEqual(sms_segments(fancy)['non_gsm'], ['—'])

    def test_empty_costs_nothing(self):
        self.assertEqual(sms_segments('')['segments'], 0)


class ComposePersonalTests(SimpleTestCase):
    ENTRIES = [{'amount': 40}, {'amount': 10}, {'amount': 10},
               {'amount': 15}, {'amount': 15}, {'amount': 10}]
    PRIZES = [
        {'label': 'Beer Ball R1', 'detail': 'Group 1, 4 ways', 'amount': 60},
        {'label': 'Mini Singles day 1', 'detail': 'Group 1, 1st', 'amount': 24},
    ]

    def _msg(self, **kw):
        base = dict(event_name='Pine Valley Fall Classic',
                    golfer_name='Aldo Detomasi', entries=self.ENTRIES,
                    prizes=self.PRIZES, net=84)
        base.update(kw)
        return compose_personal(**base)

    def test_is_a_pure_function(self):
        self.assertEqual(self._msg(), self._msg())

    def test_prizes_carry_the_group_and_the_ways(self):
        """The share is the only part he can check himself."""
        self.assertIn('Beer Ball R1 (Group 1, 4 ways) +$60', self._msg())

    def test_entry_count_travels_so_he_can_compare(self):
        """Six lines against seven answers 'why did he stake less than me'."""
        self.assertIn('Entries (6) -$100', self._msg())

    def test_says_collect_or_pay_in_words(self):
        self.assertIn('to collect', self._msg(net=84))
        self.assertIn('to pay', self._msg(net=-84))

    def test_note_is_appended(self):
        self.assertTrue(self._msg(note='Venmo @paul-lipkin by Friday.')
                        .endswith('Venmo @paul-lipkin by Friday.'))

    def test_carries_no_link_back_into_the_app(self):
        """It has to be readable by a man who has not installed it."""
        m = self._msg(note='Venmo @paul-lipkin by Friday.')
        for token in ('http', 'halved.golf', '://'):
            self.assertNotIn(token, m)

    def test_stays_inside_gsm7(self):
        """Plain text, and cheap to send fourteen times."""
        r = sms_segments(self._msg(note='Venmo @paul-lipkin by Friday.'))
        self.assertEqual(r['encoding'], 'GSM-7', f'non-GSM: {r["non_gsm"]}')


class ComposeFieldTests(SimpleTestCase):
    FIELD = [
        {'name': 'Anna Maiolini', 'net': 266},
        {'name': 'Aldo Detomasi', 'net': 84},
        {'name': 'Paul Lipkin',   'net': -120},
        {'name': 'Joe Salas',     'net': -120},
    ]

    def test_collectors_first_then_payers(self):
        m = compose_field(event_name='Pine Valley Fall Classic',
                          golfers=self.FIELD, pots=7)
        self.assertLess(m.index('Collecting'), m.index('Paying'))
        self.assertLess(m.index('Maiolini'), m.index('Salas'))

    def test_sorted_by_net_descending(self):
        m = compose_field(event_name='E', golfers=self.FIELD)
        self.assertLess(m.index('Maiolini +$266'), m.index('Detomasi +$84'))

    def test_uses_surnames_only(self):
        m = compose_field(event_name='E', golfers=self.FIELD)
        self.assertIn('Maiolini +$266', m)
        self.assertNotIn('Anna Maiolini', m)

    def test_carries_no_itemisation(self):
        m = compose_field(event_name='E', golfers=self.FIELD)
        for token in ('Entries', 'Beer Ball', 'ways'):
            self.assertNotIn(token, m)

    def test_is_a_pure_function(self):
        a = compose_field(event_name='E', golfers=self.FIELD, note='n')
        b = compose_field(event_name='E', golfers=self.FIELD, note='n')
        self.assertEqual(a, b)


# ---------------------------------------------------------------------------
# The endpoint.  Composition above is pure and DB-free; this is the wiring.
# ---------------------------------------------------------------------------

from decimal import Decimal                                    # noqa: E402

from django.contrib.auth import get_user_model                 # noqa: E402
from django.test import TestCase                               # noqa: E402
from django.urls import reverse                                # noqa: E402
from rest_framework.test import APIClient                      # noqa: E402

from core.models import RoundStatus                            # noqa: E402
from accounts.models import Account                            # noqa: E402
from games.models import LowNetChampionshipConfig              # noqa: E402
from tournament.models import SettlementSend                   # noqa: E402
from scoring.tests._helpers import (                           # noqa: E402
    DEFAULT_HOLES, make_course, make_foursome, make_player, make_round,
    make_tee, make_tournament, submit_hole,
)


class ReceiptEndpointTests(TestCase):
    """A small settle-able tournament, over the wire."""

    NAMES = ['Petersen', 'Gunst', 'Detomasi', 'Maiolini']

    def setUp(self):
        self.course = make_course()
        self.tee    = make_tee(self.course)
        self.tourn  = make_tournament(total_rounds=1)
        LowNetChampionshipConfig.objects.create(
            tournament=self.tourn, entry_fee=Decimal('10.00'),
            payouts=[{'place': 1, 'amount': 40}])
        self.players = [make_player(n, 0, short_name=n[:5]) for n in self.NAMES]
        self.round = make_round(self.course, tournament=self.tourn,
                                round_number=1, active_games=['low_net_round'])
        make_foursome(self.round, [(p, 0) for p in self.players], tee=self.tee,
                      group_number=1)

        # The helpers all hang off one shared tenant; the TD must live there
        # too or account scoping (rightly) hides the tournament.
        acct = Account.objects.get(name='Test Account')
        self.user = get_user_model().objects.create_user(
            username='td', account=acct, is_account_admin=True)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def _url(self):
        return reverse('api-tournament-receipt', args=[self.tourn.id])

    def _play_and_close(self):
        fs = self.round.foursomes.first()
        members = list(fs.memberships.select_related('player'))
        for i, h in enumerate(DEFAULT_HOLES):
            submit_hole(fs, h['number'], [
                (m.player, h['par'] + (1 if i < self.players.index(m.player) else 0))
                for m in members])
        self.round.status = RoundStatus.COMPLETE
        self.round.save(update_fields=['status'])

    # -- reading it ----------------------------------------------------------

    def test_it_returns_a_receipt_per_golfer_and_a_field_summary(self):
        self._play_and_close()
        resp = self.client.get(self._url())
        self.assertEqual(resp.status_code, 200, resp.data)
        self.assertEqual(len(resp.data['golfers']), 4)
        self.assertIn('Collecting', resp.data['field_summary']['message'])
        self.assertTrue(resp.data['can_send'])

    def test_the_note_is_composed_server_side(self):
        """Rule 1: the screen never builds the message."""
        self._play_and_close()
        resp = self.client.get(self._url(), {'note': 'Venmo by Friday'})
        self.assertIn('Venmo by Friday', resp.data['field_summary']['message'])

    def test_an_open_round_blocks_the_send_and_says_why(self):
        resp = self.client.get(self._url())
        self.assertFalse(resp.data['can_send'])
        self.assertTrue(resp.data['blocking'])

    # -- recording a send ----------------------------------------------------

    def test_recording_a_send_shows_up_on_the_next_read(self):
        self._play_and_close()
        resp = self.client.post(self._url(),
                                {'mode': 'field', 'recipients': 4}, format='json')
        self.assertEqual(resp.status_code, 201, resp.data)
        again = self.client.get(self._url())
        self.assertEqual(again.data['last_send']['mode'], 'field')
        self.assertEqual(again.data['last_send']['recipients'], 4)

    def test_a_send_cannot_be_recorded_while_money_can_still_move(self):
        """The gate is not just a greyed button — the server refuses too."""
        resp = self.client.post(self._url(),
                                {'mode': 'field', 'recipients': 4}, format='json')
        self.assertEqual(resp.status_code, 400, resp.data)
        self.assertTrue(resp.data['blocking'])
        self.assertFalse(SettlementSend.objects.exists())

    def test_an_unknown_mode_is_refused(self):
        self._play_and_close()
        resp = self.client.post(self._url(),
                                {'mode': 'carrier-pigeon'}, format='json')
        self.assertEqual(resp.status_code, 400, resp.data)

    def test_another_accounts_tournament_cannot_be_marked_sent(self):
        self._play_and_close()
        other = Account.objects.create(name='Somebody Else')
        intruder = get_user_model().objects.create_user(
            username='them', account=other, is_account_admin=True)
        self.client.force_authenticate(intruder)
        resp = self.client.post(self._url(),
                                {'mode': 'field', 'recipients': 4}, format='json')
        self.assertEqual(resp.status_code, 404)
