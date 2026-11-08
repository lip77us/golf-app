"""Finish round -> a frozen Receipt and a push — settle-up handoff step 3."""
from django.test import TestCase
from rest_framework.test import APITestCase

from scoring.tests._helpers import (_test_account, make_foursome, make_round,
                                    make_tee, submit_hole)
from services.receipt_build import build_round_receipt, notify_receipt
from services.skins import setup_skins, calculate_skins
from tournament.models import Receipt


def _skins_round(**kw):
    rnd = make_round(active_games=['skins'], **kw)
    tee = make_tee()
    fs = make_foursome(rnd, [('Paul', 8), ('Dave', 12), ('Sam', 18),
                             ('Mike', 15)], tee=tee)
    setup_skins(fs, handicap_mode='gross', carryover=False)
    # Paul takes three holes outright; the rest are halved, so the money is
    # unambiguous and the nets cannot come out level by accident.
    ids = [m.player_id for m in fs.memberships.all()]
    for hole in range(1, 19):
        scores = [(pid, 5) for pid in ids]
        if hole in (1, 2, 3):
            scores[0] = (ids[0], 3)
        submit_hole(fs, hole, scores)
    calculate_skins(fs)
    return rnd, fs, ids


class BuildTests(TestCase):

    def test_a_settled_round_freezes_a_receipt(self):
        rnd, fs, ids = _skins_round()
        receipt = build_round_receipt(rnd)
        self.assertIsNotNone(receipt)
        self.assertEqual(len(receipt.code), 8)
        self.assertEqual(receipt.round_id, rnd.id)
        self.assertEqual(receipt.payload['code'], receipt.code)

    def test_the_nets_sum_to_zero_and_the_transfers_clear_them(self):
        """The invariant the whole document rests on.  A receipt whose chips
        and transfers disagree is worse than none: four golfers settle from
        it in a car park."""
        rnd, fs, ids = _skins_round()
        payload = build_round_receipt(rnd).payload
        self.assertEqual(sum(n['net'] for n in payload['nets']), 0)
        moved = {}
        for t in payload['pays']:
            moved[t['from']] = moved.get(t['from'], 0) - t['amount']
            moved[t['to']] = moved.get(t['to'], 0) + t['amount']
        for chip in payload['nets']:
            self.assertEqual(moved.get(chip['name'], 0), chip['net'],
                             f'{chip["name"]} settles to the wrong figure')

    def test_the_chips_are_sorted_by_net_descending(self):
        """§3: nets, sorted by net descending."""
        payload = build_round_receipt(_skins_round()[0]).payload
        amounts = [n['net'] for n in payload['nets']]
        self.assertEqual(amounts, sorted(amounts, reverse=True))

    def test_the_transfers_are_largest_first(self):
        payload = build_round_receipt(_skins_round()[0]).payload
        amounts = [t['amount'] for t in payload['pays']]
        self.assertEqual(amounts, sorted(amounts, reverse=True))

    def test_the_sub_names_the_course_and_date(self):
        rnd, fs, ids = _skins_round()
        sub = build_round_receipt(rnd).payload['sub']
        self.assertIn(rnd.course.name, sub)
        self.assertIn(rnd.date.strftime('%b'), sub)

    def test_the_fallback_stake_does_not_invent_a_unit(self):
        """Until a game registers §3's stakeLabel the unit is not known, so
        the generic line says the stake and no unit.  Guessing printed
        "$5 a point" on a skins round — true of the figure, false of the game.

        Exercised against a game with NO formatter rather than a real one:
        every Group A game has registered a stake label now, so using one of
        them would test the formatter instead of the fallback it is here for.
        """
        from services.receipt_build import _sub
        rnd, fs, ids = _skins_round()
        sub = _sub(rnd, [{'game': 'not_a_real_game', 'label': 'X',
                          'nets': {}}])
        self.assertIn('stake', sub)
        self.assertNotIn('a point', sub)

    def test_the_fallback_row_names_a_whole_group(self):
        """Capping at three dropped the fourth golfer of a four-ball with
        nothing saying so, which reads as a bug rather than a summary."""
        from services.receipt_build import _summary_rows
        rnd, fs, ids = _skins_round()
        names = {pid: {'short_name': f'P{pid}'} for pid in ids}
        entry = {'game': 'not_a_real_game', 'label': 'X',
                 'nets': {pid: (10 if i == 0 else -3) for i, pid in enumerate(ids)}}
        value = _summary_rows(rnd, [entry], names)[0][1]
        for pid in ids:
            self.assertIn(f'P{pid}', value, f'{pid} was dropped from the row')

    def test_the_fallback_collapses_past_four(self):
        """It never truncates silently — the same rule the preview's "13 more"
        follows."""
        from services.receipt_build import _summary_rows
        rnd, fs, ids = _skins_round()
        nets = {i: (100 if i == 1 else -10) for i in range(1, 12)}
        names = {i: {'short_name': f'G{i}'} for i in nets}
        value = _summary_rows(rnd, [{'game': 'not_a_real_game', 'label': 'X',
                                     'nets': nets}], names)[0][1]
        self.assertIn('more', value)

    def test_a_caption_is_gross_and_net(self):
        """§3's default, read off the stored card rather than recomputed — it
        is the one thing a golfer checks the receipt against."""
        payload = build_round_receipt(_skins_round()[0]).payload
        self.assertTrue(any('net' in (n['caption'] or '')
                            for n in payload['nets']))

    def test_re_settling_the_same_money_returns_the_same_receipt(self):
        """An ordinary double tap must not mint a second code for figures
        nobody has changed."""
        rnd, fs, ids = _skins_round()
        first = build_round_receipt(rnd)
        self.assertEqual(build_round_receipt(rnd).code, first.code)
        self.assertEqual(Receipt.objects.filter(round=rnd).count(), 1)

    def test_a_changed_score_mints_a_NEW_code_and_keeps_the_old_link(self):
        """The case the old guard refused and the newer one swallowed.

        Guarding on "a receipt already exists" refused to re-settle at all.
        Guarding in the CALLER — settling only on the status flip — looked
        right because a double tap cannot flip twice, and was wrong about
        Tilden on 7 Nov 2026: the first tap settled while the last holes
        were still in the sync queue, the second found the round already
        complete, and four golfers kept a receipt stamped Final whose every
        figure was $10 out.
        """
        rnd, fs, ids = _skins_round()
        first = build_round_receipt(rnd)
        before = {n['name']: n['net'] for n in first.payload['nets']}

        # A hole arrives late — exactly what the sync queue delivers after a
        # slow Finish round.
        submit_hole(fs, 18, [(ids[1], 2)] + [(p, 5) for p in ids[2:]]
                            + [(ids[0], 5)])
        calculate_skins(fs)

        second = build_round_receipt(rnd)
        self.assertNotEqual(second.code, first.code)
        self.assertEqual(Receipt.objects.filter(round=rnd).count(), 2)
        self.assertNotEqual(
            {n['name']: n['net'] for n in second.payload['nets']}, before,
            'the money did not move, so this fixture proves nothing')

        # The old link still resolves and still says what it said — that is
        # the point of storing a frozen payload rather than updating one.
        first.refresh_from_db()
        self.assertEqual({n['name']: n['net'] for n in first.payload['nets']},
                         before)
        # ...and every reader takes the NEWEST.
        self.assertEqual(Receipt.objects.filter(round=rnd).first().code,
                         second.code)

    def test_a_round_that_settles_to_nothing_gets_none(self):
        """Everyone square: four "+$0 to collect" lines and a link saying
        nothing is worse than no link."""
        rnd = make_round(active_games=['skins'])
        fs = make_foursome(rnd, [('A', 10), ('B', 10), ('C', 10), ('D', 10)])
        setup_skins(fs, handicap_mode='gross', carryover=False)
        ids = [m.player_id for m in fs.memberships.all()]
        for hole in range(1, 19):                 # every hole halved
            submit_hole(fs, hole, [(pid, 4) for pid in ids])
        calculate_skins(fs)
        self.assertIsNone(build_round_receipt(rnd))
        self.assertFalse(Receipt.objects.filter(round=rnd).exists())

    def test_a_tournament_round_is_left_to_the_field_receipt(self):
        """§4 Group C: one receipt for the WHOLE field, several pots, built
        when the TD settles.  A per-round hook cannot produce that."""
        from tournament.models import Tournament
        t = Tournament.objects.create(account=_test_account(), name='T',
                                      start_date='2026-11-01')
        rnd, fs, ids = _skins_round(tournament=t)
        self.assertIsNone(build_round_receipt(rnd))

    def test_it_never_raises(self):
        """A round must close whatever happens to the document."""
        rnd = make_round(active_games=['skins'])
        self.assertIsNone(build_round_receipt(rnd))


class RecipientTests(TestCase):

    def _with_logins(self):
        from accounts.models import User
        from core.models import Player
        rnd, fs, ids = _skins_round()
        winner = Player.objects.get(id=ids[0])
        loser = Player.objects.get(id=ids[1])
        for i, p in enumerate((winner, loser)):
            u = User.objects.create_user(username=f'u{i}{p.id}',
                                         password='x',
                                         account=_test_account())
            u.phone = f'+1310555{p.id:04d}'
            u.save()
            p.user = u
            p.phone = u.phone
            p.save()
        return rnd, fs, ids, winner, loser

    def test_the_note_names_who_gets_what(self):
        rnd, fs, ids, winner, loser = self._with_logins()
        payload = build_round_receipt(rnd).payload
        self.assertIn('have it in Halved', payload['note'])
        self.assertIn('no mobile on file', payload['note'])
        self.assertEqual(sorted(payload['recipients']['push']),
                         sorted([winner.id, loser.id]))

    def test_the_scorer_is_left_out(self):
        rnd, fs, ids, winner, loser = self._with_logins()
        payload = build_round_receipt(rnd, scorer=winner).payload
        self.assertNotIn(winner.id, payload['recipients']['push'])

    def test_a_winner_is_told_the_figure_and_everybody_else_the_place(self):
        """§1.  Telling a man who lost $18 that he "won −$18" is the trap."""
        rnd, fs, ids, winner, loser = self._with_logins()
        receipt = build_round_receipt(rnd)
        bodies = {}
        with self.settings(SMS_BACKEND='console'):
            import services.push as push
            real = push.send_push
            push.send_push = lambda tokens, title, body, data=None, **k: (
                bodies.setdefault(data.get('code'), []).append(body) or [])
            try:
                from accounts.models import DeviceToken
                for p in (winner, loser):
                    DeviceToken.objects.create(user=p.user, token=f't{p.id}',
                                               platform='ios')
                notify_receipt(receipt)
            finally:
                push.send_push = real
        sent = bodies.get(receipt.code, [])
        self.assertTrue(any(b.startswith('You won') for b in sent),
                        f'no winner body in {sent}')
        self.assertTrue(any(rnd.course.name in b for b in sent),
                        f'no course body in {sent}')

    def test_a_golfer_is_pushed_once(self):
        """Finish round is idempotent, so the push must be too — nobody is
        told twice that the money settled."""
        from accounts.models import DeviceToken
        rnd, fs, ids, winner, loser = self._with_logins()
        receipt = build_round_receipt(rnd)
        for p in (winner, loser):
            DeviceToken.objects.create(user=p.user, token=f't{p.id}',
                                       platform='ios')
        first = notify_receipt(receipt)
        self.assertEqual(notify_receipt(receipt), 0)
        self.assertEqual(first, 2)


class EndpointTests(APITestCase):

    def _login(self):
        from accounts.models import User
        from rest_framework.authtoken.models import Token
        u = User.objects.create_user(username='td', password='x',
                                     account=_test_account())
        u.is_account_admin = True
        u.save()
        token, _ = Token.objects.get_or_create(user=u)
        self.client.credentials(HTTP_AUTHORIZATION=f'Token {token.key}')
        return u

    def test_finishing_the_round_returns_the_receipt(self):
        self._login()
        rnd, fs, ids = _skins_round()
        resp = self.client.post(f'/api/rounds/{rnd.id}/complete/', {},
                                content_type='application/json')
        self.assertEqual(resp.status_code, 200)
        block = resp.json().get('receipt')
        self.assertIsNotNone(block, 'Round over has nothing to draw')
        self.assertIn('/r/', block['url'])
        self.assertEqual(block['payload']['code'], block['code'])

    def test_the_link_in_the_response_actually_serves_the_receipt(self):
        """The one check that spans the whole feature: the code Finish round
        hands back opens the page step 2 built."""
        self._login()
        rnd, fs, ids = _skins_round()
        code = self.client.post(f'/api/rounds/{rnd.id}/complete/', {},
                                content_type='application/json'
                                ).json()['receipt']['code']
        self.client.credentials()          # the link needs no sign-in
        page = self.client.get(f'/r/{code}/')
        self.assertEqual(page.status_code, 200)
        self.assertIn('Skins', page.content.decode())

    def test_completing_twice_keeps_one_receipt(self):
        """Where idempotency actually lives.  `RoundCompleteView` only settles
        inside `status != 'complete'`, so the second tap never reaches the
        builder — which is why the builder itself does not need (and must not
        have) an "already has one" guard."""
        self._login()
        rnd, fs, ids = _skins_round()
        for _ in range(2):
            self.client.post(f'/api/rounds/{rnd.id}/complete/', {},
                             content_type='application/json')
        self.assertEqual(Receipt.objects.filter(round=rnd).count(), 1)

    def test_finishing_again_corrects_a_receipt_settled_too_early(self):
        """Tilden, 7 Nov 2026, end to end.

        Finish round while a hole is still unsent, let it arrive, press
        Finish round again — which is what a scorer does when the first tap
        is slow and the dialog comes back.  The second press must fix the
        money, and before this it did nothing at all.
        """
        self._login()
        rnd, fs, ids = _skins_round()
        url = f'/api/rounds/{rnd.id}/complete/'
        self.client.post(url, {}, content_type='application/json')
        first = Receipt.objects.get(round=rnd)
        stale = {n['name']: n['net'] for n in first.payload['nets']}

        # The queue drains after the round was closed.
        submit_hole(fs, 18, [(ids[1], 2)] + [(p, 5) for p in ids[2:]]
                            + [(ids[0], 5)])
        calculate_skins(fs)

        r = self.client.post(url, {}, content_type='application/json')
        self.assertEqual(r.status_code, 200)
        fixed = Receipt.objects.filter(round=rnd).first()
        self.assertNotEqual(fixed.code, first.code)
        self.assertNotEqual({n['name']: n['net'] for n in fixed.payload['nets']},
                            stale)
        # The response hands back the one the scorer is about to be shown.
        self.assertEqual(r.data['receipt']['code'], fixed.code)

    def test_finishing_again_with_nothing_changed_keeps_one_receipt(self):
        self._login()
        rnd, fs, ids = _skins_round()
        url = f'/api/rounds/{rnd.id}/complete/'
        for _ in range(3):
            self.client.post(url, {}, content_type='application/json')
        self.assertEqual(Receipt.objects.filter(round=rnd).count(), 1)

    def test_reopening_and_finishing_again_re_settles(self):
        """The round trip a scorer makes to fix a wrong score."""
        self._login()
        rnd, fs, ids = _skins_round()
        url = f'/api/rounds/{rnd.id}/complete/'
        self.client.post(url, {}, content_type='application/json')
        first = Receipt.objects.get(round=rnd)

        self.client.post(f'/api/rounds/{rnd.id}/reopen/', {},
                         content_type='application/json')
        submit_hole(fs, 4, [(ids[1], 2)] + [(p, 5) for p in ids[2:]]
                           + [(ids[0], 5)])
        calculate_skins(fs)
        r = self.client.post(url, {}, content_type='application/json')
        self.assertEqual(r.status_code, 200)
        codes = list(Receipt.objects.filter(round=rnd)
                     .values_list('code', flat=True))
        self.assertEqual(len(codes), 2, codes)
        self.assertNotEqual(r.data['receipt']['code'], first.code)

    def test_an_open_multi_group_round_is_not_settled_by_a_complete_tap(self):
        """Settling moved outside the status flip, so this is the thing that
        now has to hold: a Complete tap that does NOT close the round must
        not freeze money for groups still on the course."""
        self._login()
        rnd, fs, ids = _skins_round()
        from scoring.tests._helpers import make_foursome
        make_foursome(rnd, [('Zoe', 10), ('Yan', 10)], group_number=2)
        r = self.client.post(f'/api/rounds/{rnd.id}/complete/', {},
                             content_type='application/json')
        self.assertEqual(r.status_code, 200)
        rnd.refresh_from_db()
        self.assertNotEqual(rnd.status, 'complete')
        self.assertEqual(Receipt.objects.filter(round=rnd).count(), 0)
