"""
scoring/tests/test_live_activity_android.py
-------------------------------------------
The Android board — `services/live_activity_android.py`.

Two things are worth pinning here and they are different in kind.

The flattener makes JUDGEMENTS, and they are all about what survives
truncation: the system draws one line of body, so the order of the slots is
the design. Those tests are pure.

The sender makes a CLAIM — that the recipients are the intersection of "can
read this round" and "has an Android phone". An iOS-only follower appearing
there would mean a golfer got the degraded board instead of the card, and
nothing on either phone would say so.
"""
import os
from decimal import Decimal
from unittest import mock

from django.test import SimpleTestCase, TestCase

from accounts.models import DeviceToken, User
from services import live_activity_android as lab
from services.skins import HandicapMode, calculate_skins, setup_skins
from ._helpers import _test_account, make_foursome, make_round, make_tee, submit_hole


# ---------------------------------------------------------------------------
# The flattener
# ---------------------------------------------------------------------------

def _state(**over):
    """A running Skins-shaped card, with the slots this module reads."""
    s = {
        'kind'  : 'skins',
        'header': {'game': 'SKINS · POOL', 'segment': 'SEG 2'},
        'number': {'text': '1 UP', 'colour': 'mint'},
        'state' : {'word': 'DORMIE', 'to_play': '2 TO PLAY'},
        'sides' : [{'names': 'Kelly & Moran v. Reid & Naylor',
                    'colour': 'blue', 'leading': True}],
        'thru'  : 'THRU 12 · +7',
        'footer': {'context': '4 golfers · $48 pot', 'money': 'you +$5'},
    }
    s.update(over)
    return s


class TitleTests(SimpleTestCase):

    def test_the_title_is_the_headline_and_the_state(self):
        t = lab.notification_text(_state())
        self.assertEqual(t['title'], '1 UP · DORMIE · 2 TO PLAY')

    def test_a_closing_frame_leads_with_the_settlement(self):
        """The cards that sign off with money say so; the title is the one slot
        guaranteed to be read, so it goes there rather than into the body."""
        t = lab.notification_text(
            _state(final={'amount': '−$20', 'detail': 'Lost 4 & 3',
                          'collect': 'Pay Paul Kelly'}),
            final=True)
        self.assertEqual(t['title'], '−$20 · Lost 4 & 3')
        self.assertIn('Pay Paul Kelly', t['lines'])

    def test_a_card_that_keeps_its_board_keeps_its_headline(self):
        """Rabbit, Survivor, Stableford and Triple Cup return an empty `final`
        and repurpose their slots instead. Reading `final` first would blank
        the title on exactly those four."""
        t = lab.notification_text(_state(final={}), final=True)
        self.assertEqual(t['title'], '1 UP · DORMIE · 2 TO PLAY')

    def test_a_word_headline_survives(self):
        """Survivor's headline is a word, not a measurement."""
        t = lab.notification_text(
            _state(number={'text': 'ZOMBIE'},
                   state={'word': 'BACK IN', 'to_play': ''}))
        self.assertEqual(t['title'], 'ZOMBIE · BACK IN')


class BodyTests(SimpleTestCase):

    def test_the_body_is_one_line(self):
        """FCM's own display calls `setContentText` with no BigTextStyle, so a
        second line is not truncated — it is never drawn at all."""
        self.assertNotIn('\n', lab.notification_text(_state())['body'])

    def test_the_body_puts_the_money_first_and_the_game_label_last(self):
        """The system truncates this line, so the order IS the design. The game
        name is the only one of the five a reader can infer from the title and
        from being in the round at all, so it is what truncation should eat."""
        b = lab.notification_text(_state())['body']
        self.assertEqual(
            b, 'you +$5 · SEG 2 · THRU 12 · +7 · SKINS · POOL')
        self.assertLess(b.index('you +$5'), b.index('SKINS'))

    def test_the_stroke_band_rides_in_the_body_when_it_fires(self):
        """It only appears on a hole where the reader actually gets a stroke,
        so the width it costs is width that matters."""
        b = lab.notification_text(
            _state(ribbon='POPPING ON HOLE 13'))['body']
        self.assertIn('POPPING ON HOLE 13', b)
        self.assertTrue(b.startswith('POPPING ON HOLE 13'))

    def test_an_empty_slot_leaves_no_dangling_separator(self):
        """The money line is blank from the 1st to the 17th on a match card,
        and ` ·  · ` reads as a missing value rather than an absent slot."""
        b = lab.notification_text(
            _state(footer={'context': '', 'money': ''}, thru=''))['body']
        self.assertEqual(b, 'SEG 2 · SKINS · POOL')
        self.assertNotIn('· ·', b)

    def test_a_card_with_nothing_filled_in_says_nothing(self):
        t = lab.notification_text({})
        self.assertEqual(t['title'], '')
        self.assertEqual(t['body'], '')
        self.assertEqual(t['lines'], [])


class LinesTests(SimpleTestCase):

    def test_the_full_board_travels_even_though_nothing_draws_it_yet(self):
        """This is the seam to a client that can render more. If `lines` ever
        stops carrying the sides, the rich board silently loses the matchup
        and the server looks correct."""
        lines = lab.notification_text(_state(ribbon='POPPING ON HOLE 13'))['lines']
        self.assertIn('Kelly & Moran v. Reid & Naylor', lines)
        self.assertIn('POPPING ON HOLE 13', lines)
        self.assertIn('you +$5', lines)
        self.assertIn('4 golfers · $48 pot', lines)

    def test_a_sides_note_is_folded_into_its_line(self):
        lines = lab.notification_text(_state(sides=[
            {'names': 'Your Triple Cup', 'note': '1–0, in the foursomes'},
        ]))['lines']
        self.assertIn('Your Triple Cup — 1–0, in the foursomes', lines)

    def test_a_repeated_string_is_not_repeated(self):
        """Skins' closing frame carries the winners in both `sides` and
        `collect`, and one line printed twice reads as a rendering fault."""
        lines = lab.notification_text(
            _state(sides=[{'names': 'Winners: Paul 3'}],
                   final={'amount': '$12', 'detail': 'per skin',
                          'collect': 'Winners: Paul 3'}),
            final=True)['lines']
        self.assertEqual(lines.count('Winners: Paul 3'), 1)

    def test_the_board_is_capped(self):
        lines = lab.notification_text(_state(sides=[
            {'names': f'side {i}'} for i in range(20)]))['lines']
        self.assertLessEqual(len(lines), lab.MAX_LINES)


# ---------------------------------------------------------------------------
# Delivery options
# ---------------------------------------------------------------------------

class OptionTests(TestCase):

    def setUp(self):
        self.round = make_round()

    def test_the_tag_is_the_round_not_the_foursome(self):
        """A TD watching a multi-group tournament would otherwise carry one row
        per group, each claiming to be the board."""
        self.assertEqual(lab._tag(self.round), f'halved-board-{self.round.id}')

    def test_the_tag_doubles_as_the_collapse_key(self):
        """A phone that was off through three holes should wake to the current
        board, not to a queue of superseded ones."""
        o = lab._android_options(self.round)
        self.assertEqual(o['tag'], o['collapse_key'])

    def test_the_channel_is_named_forward(self):
        """`halved_board` does not exist on any shipped build. FCM falls back
        to the manifest default for a channel the app has not created, so this
        is inert today and correct the moment the Kotlin lands — with no server
        change."""
        self.assertEqual(lab._android_options(self.round)['channel_id'],
                         'halved_board')

    def test_it_is_not_sticky(self):
        """FCM cannot cancel a notification it displayed, so a sticky board
        would outlive its round and could not be dismissed."""
        self.assertNotIn('sticky', lab._android_options(self.round))


# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------

class GateTests(TestCase):

    def test_off_unless_set(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('ANDROID_BOARD', None)
            self.assertFalse(lab.is_enabled())

    def test_on_when_set(self):
        for v in ('1', 'true', 'YES'):
            with mock.patch.dict(os.environ, {'ANDROID_BOARD': v}):
                self.assertTrue(lab.is_enabled())

    def test_nothing_is_sent_while_it_is_off(self):
        with mock.patch.dict(os.environ, {'ANDROID_BOARD': ''}), \
                mock.patch('services.push.send_push') as send:
            self.assertEqual(lab.push_round_android(make_round()), 0)
        send.assert_not_called()


# ---------------------------------------------------------------------------
# Recipients — the claim worth pinning
# ---------------------------------------------------------------------------

class _Fixture:
    """A real scored Skins round, so `activity_state` returns a real card.

    A mixin rather than a base TestCase: subclassing a TestCase to reuse its
    setUp re-runs every one of its tests under the subclass, which doubles the
    count and makes a failure report name a class that does not own the test.
    """

    def setUp(self):
        patcher = mock.patch.dict(os.environ, {'ANDROID_BOARD': '1'})
        patcher.start()
        self.addCleanup(patcher.stop)

        self.acct  = _test_account()
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.round.bet_unit     = Decimal('2.00')
        self.round.active_games = ['skins']
        self.round.primary_game = 'skins'
        self.round.save(update_fields=['bet_unit', 'active_games',
                                       'primary_game'])
        self.fs = make_foursome(
            self.round, [('Paul', 0), ('Dave', 0), ('Sam', 0), ('Lee', 0)],
            tee=self.tee)
        setup_skins(self.fs, handicap_mode=HandicapMode.GROSS, carryover=True,
                    payout_style='per_point', per_point_mode='first',
                    per_point_rate=6)
        self.by_name = {m.player.name: m.player
                        for m in self.fs.memberships.select_related('player')}
        submit_hole(self.fs, 1, [(self.by_name[n].id, s) for n, s in
                                 (('Paul', 3), ('Dave', 4), ('Sam', 4), ('Lee', 4))])
        calculate_skins(self.fs)

    def _link(self, name, platform):
        """Give a golfer a login and a device on `platform`."""
        u = User.objects.create_user(username=name.lower(), account=self.acct)
        p = self.by_name[name]
        p.user = u
        p.save(update_fields=['user'])
        if platform:
            DeviceToken.objects.create(user=u, token=f'tok-{name}',
                                       platform=platform)
        return u


class RecipientTests(_Fixture, TestCase):

    def test_an_android_follower_gets_the_board(self):
        self._link('Paul', 'android')
        with mock.patch('services.push.send_push',
                        return_value=set()) as send:
            self.assertEqual(lab.push_round_android(self.round), 1)
        tokens, title, body, data = send.call_args.args
        self.assertEqual(list(tokens), ['tok-Paul'])
        self.assertTrue(title)
        self.assertEqual(data['round_id'], str(self.round.id))
        self.assertEqual(data['kind'], 'skins')
        self.assertEqual(data['type'], 'board')
        self.assertEqual(send.call_args.kwargs['android']['tag'],
                         f'halved-board-{self.round.id}')

    def test_an_ios_follower_is_not_a_recipient(self):
        """He has the real card. Sending him the degraded one as well would put
        two boards on one lock screen disagreeing about nothing."""
        self._link('Dave', 'ios')
        with mock.patch('services.push.send_push') as send:
            self.assertEqual(lab.push_round_android(self.round), 0)
        send.assert_not_called()

    def test_a_golfer_who_muted_the_board_is_skipped(self):
        """Muting the board must not mute birdies, which is why it is its own
        category rather than riding on an existing one."""
        u = self._link('Paul', 'android')
        u.notification_prefs = {'board': False}
        u.save(update_fields=['notification_prefs'])
        with mock.patch('services.push.send_push') as send:
            self.assertEqual(lab.push_round_android(self.round), 0)
        send.assert_not_called()

    def test_the_board_is_built_per_recipient(self):
        """Everything on the card is the same string on every phone except the
        money line, and that one is the reason this is a loop rather than one
        multicast."""
        self._link('Paul', 'android')
        self._link('Sam', 'android')
        with mock.patch('services.push.send_push',
                        return_value=set()) as send:
            self.assertEqual(lab.push_round_android(self.round), 2)
        self.assertEqual(send.call_count, 2)

    def test_a_dead_token_is_pruned(self):
        self._link('Paul', 'android')
        with mock.patch('services.push.send_push',
                        return_value={'tok-Paul'}):
            lab.push_round_android(self.round)
        self.assertFalse(DeviceToken.objects.filter(token='tok-Paul').exists())

    def test_a_round_nobody_follows_sends_nothing(self):
        with mock.patch('services.push.send_push') as send:
            self.assertEqual(lab.push_round_android(self.round), 0)
        send.assert_not_called()


# ---------------------------------------------------------------------------
# The three the real fleet found
# ---------------------------------------------------------------------------

class RealFleetTests(SimpleTestCase):
    """Rendering the thirty live boards on prod turned up three defects a
    fixture would never have shown, because all three are shapes the cards
    emit legitimately and draw fine in a laid-out column."""

    def test_a_finished_sixes_segment_sends_a_dash_for_its_state(self):
        """`1 UP · — · 0 TO PLAY` — a dash between two middots reads as a
        value that failed to load. Five of the thirty boards."""
        t = lab.notification_text(_state(
            number={'text': '1 UP'},
            state={'word': '—', 'to_play': '0 TO PLAY'}))
        self.assertEqual(t['title'], '1 UP · 0 TO PLAY')
        self.assertNotIn('—', t['title'])

    def test_rabbit_sends_the_same_word_twice(self):
        """The card draws `number` and `state` in different places, so `LOOSE`
        in both is not a repeat there. One line prints `LOOSE · LOOSE`."""
        t = lab.notification_text(_state(
            number={'text': 'LOOSE'},
            state={'word': 'LOOSE', 'to_play': '0 TO PLAY'}))
        self.assertEqual(t['title'], 'LOOSE · 0 TO PLAY')

    def test_a_repeat_is_caught_regardless_of_case(self):
        t = lab.notification_text(_state(
            number={'text': 'Loose'}, state={'word': 'LOOSE', 'to_play': ''}))
        self.assertEqual(t['title'], 'Loose')

    def test_nassau_empties_every_headline_slot_on_a_finished_round(self):
        """The card survives it — its header and sides rows carry the round.
        A notification with no title renders as the app name alone, which
        reads as a fault rather than as a round that has ended."""
        t = lab.notification_text(_state(
            number={'text': ''}, state={'word': '', 'to_play': ''},
            header={'game': 'NASSAU', 'segment': 'HOLE 18'},
            thru='', footer={'context': '$5 a match', 'money': '+$13'}))
        self.assertEqual(t['title'], 'NASSAU · HOLE 18')
        # and the body does not simply say it again
        self.assertEqual(t['body'], '+$13')
        self.assertNotIn('NASSAU · HOLE 18', t['lines'])

    def test_a_placeholder_never_reaches_a_line_either(self):
        t = lab.notification_text(_state(
            sides=[{'names': '—'}, {'names': 'Paul & Roger'}]))
        self.assertNotIn('—', t['lines'])
        self.assertIn('Paul & Roger', t['lines'])

    def test_a_deliberate_double_space_is_squashed(self):
        """`group_stroke_band` sends `POPPING  YOU · MA` on purpose — two
        spans at different opacities on the card. One run of notification text
        has no spans, and the gap reads as a hole in the sentence. Squashed
        HERE, never in the registry, which draws it correctly."""
        t = lab.notification_text(_state(ribbon='POPPING  YOU · MA'))
        self.assertIn('POPPING YOU · MA', t['body'])
        self.assertNotIn('POPPING  YOU', t['body'])
        self.assertNotIn('  ', t['body'])


# ---------------------------------------------------------------------------
# The allowlist
# ---------------------------------------------------------------------------

class AllowlistTests(TestCase):

    def test_empty_means_everyone(self):
        """Not nobody. `ANDROID_BOARD` is the feature switch and this is a
        narrowing on top of it; defaulting to nobody would make the switch do
        nothing on its own, which is the shipped-and-unreachable failure this
        codebase has hit twice."""
        with mock.patch.dict(os.environ, {'ANDROID_BOARD_PHONES': ''}):
            self.assertEqual(lab._allowlist(), set())

    def test_unset_behaves_as_empty(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop('ANDROID_BOARD_PHONES', None)
            self.assertEqual(lab._allowlist(), set())

    def test_it_normalizes_what_you_paste(self):
        """A number copied off a phone screen carries brackets and spaces."""
        with mock.patch.dict(
                os.environ,
                {'ANDROID_BOARD_PHONES': '(510) 282-3126, +15106841132'}):
            self.assertEqual(lab._allowlist(),
                             {'+15102823126', '+15106841132'})

    def test_junk_entries_are_dropped_not_matched(self):
        with mock.patch.dict(os.environ,
                             {'ANDROID_BOARD_PHONES': ' , not-a-number, '}):
            self.assertEqual(lab._allowlist(), set())


class AllowlistDeliveryTests(_Fixture, TestCase):
    """The same fixture, with the narrowing applied."""

    def test_a_listed_golfer_still_gets_the_board(self):
        u = self._link('Paul', 'android')
        u.phone = '+15105550101'
        u.save(update_fields=['phone'])
        with mock.patch.dict(os.environ,
                             {'ANDROID_BOARD_PHONES': '(510) 555-0101'}), \
                mock.patch('services.push.send_push',
                           return_value=set()) as send:
            self.assertEqual(lab.push_round_android(self.round), 1)
        send.assert_called_once()

    def test_an_unlisted_golfer_is_skipped(self):
        u = self._link('Paul', 'android')
        u.phone = '+15105550101'
        u.save(update_fields=['phone'])
        with mock.patch.dict(os.environ,
                             {'ANDROID_BOARD_PHONES': '+15105550199'}), \
                mock.patch('services.push.send_push') as send:
            self.assertEqual(lab.push_round_android(self.round), 0)
        send.assert_not_called()

    def test_a_golfer_with_no_phone_is_skipped_once_a_list_exists(self):
        """He cannot be on a list keyed by phone, and guessing him in would
        defeat the point of a trial."""
        self._link('Paul', 'android')   # created without a phone
        with mock.patch.dict(os.environ,
                             {'ANDROID_BOARD_PHONES': '+15105550101'}), \
                mock.patch('services.push.send_push') as send:
            self.assertEqual(lab.push_round_android(self.round), 0)
        send.assert_not_called()

    def test_the_narrowing_picks_one_out_of_two(self):
        """The trial case: it reaches your phone and nobody else's."""
        mine = self._link('Paul', 'android')
        mine.phone = '+15105550101'
        mine.save(update_fields=['phone'])
        theirs = self._link('Sam', 'android')
        theirs.phone = '+15105550102'
        theirs.save(update_fields=['phone'])
        with mock.patch.dict(os.environ,
                             {'ANDROID_BOARD_PHONES': '+15105550101'}), \
                mock.patch('services.push.send_push',
                           return_value=set()) as send:
            self.assertEqual(lab.push_round_android(self.round), 1)
        self.assertEqual(list(send.call_args.args[0]), ['tok-Paul'])
