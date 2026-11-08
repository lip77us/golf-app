"""Play for fun — the receipt becomes RESULTS (settle-up handoff).

A round with no stake settles to nothing, so the money rule refused it a
receipt — which meant finishing one produced no Round over, no link and no
text at all.  The handoff's own reason for building it anyway is that **the
results link is the invite**, so these pin that it exists, that it says
RESULTS rather than RECEIPT, and that nothing on it claims money moved.
"""
import re

from django.test import TestCase

from games.models import LowNetRoundConfig
from scoring.tests._helpers import (DEFAULT_HOLES, make_course, make_foursome,
                                    make_round, make_tee, submit_hole)
from services.receipt_build import build_round_receipt
from services.skins import calculate_skins, setup_skins


def _stroke_play_round(*, entry_fee=0, payouts=None, bet_unit=0,
                       short_last=False, mode='gross', handicaps=None):
    """Four golfers, Stroke Play, each one shot worse than the last.

    ``handicaps`` with ``mode='net'`` is what makes the NET order differ from
    the gross one — the only fixture that can tell a caption read off the
    game's basis from one read off the round's.
    """
    course = make_course()
    tee = make_tee(course=course, holes=DEFAULT_HOLES)
    rnd = make_round(course=course, active_games=['low_net_round'])
    rnd.primary_game = 'low_net_round'
    rnd.bet_unit = bet_unit
    rnd.save(update_fields=['primary_game', 'bet_unit'])
    hcp = handicaps or [0, 0, 0, 0]
    fs = make_foursome(rnd, list(zip(('Ann', 'Bea', 'Cal', 'Dot'), hcp)),
                       tee=tee)
    LowNetRoundConfig.objects.create(
        round=rnd, handicap_mode=mode, net_percent=100,
        entry_fee=entry_fee, payouts=payouts or [])
    par = {h['number']: h['par'] for h in DEFAULT_HOLES}
    ids = {m.player.name: m.player_id for m in fs.memberships.all()}
    for h in range(1, 19):
        row = []
        for i, name in enumerate(('Ann', 'Bea', 'Cal', 'Dot')):
            if short_last and name == 'Dot' and h > 13:
                continue          # went in after thirteen
            row.append((ids[name], par[h] + (1 if h <= i else 0)))
        submit_hole(fs, h, row)
    return rnd, fs, ids


class ItExistsAtAllTests(TestCase):

    def test_a_round_with_no_stake_gets_a_receipt(self):
        """The failure this feature is: before it, Finish round on a for-fun
        round produced nothing to open and nothing to send."""
        rnd, _fs, _ids = _stroke_play_round()
        receipt = build_round_receipt(rnd)
        self.assertIsNotNone(receipt, 'a for-fun round got no document at all')
        self.assertTrue(receipt.payload['forFun'])

    def test_everyone_square_at_a_REAL_stake_still_gets_nothing(self):
        """The refusal that stands.  Four "+$0" lines on a round played for
        money say nothing, and that is a different thing from a round that
        was never played for money."""
        course = make_course()
        tee = make_tee(course=course, holes=DEFAULT_HOLES)
        rnd = make_round(course=course, active_games=['skins'])
        rnd.primary_game = 'skins'
        rnd.bet_unit = 5
        rnd.save(update_fields=['primary_game', 'bet_unit'])
        fs = make_foursome(rnd, [('Ann', 0), ('Bea', 0)], tee=tee)
        setup_skins(fs, handicap_mode='gross', carryover=False)
        ids = [m.player_id for m in fs.memberships.all()]
        for h in range(1, 19):               # every hole halved
            submit_hole(fs, h, [(pid, 4) for pid in ids])
        calculate_skins(fs)
        self.assertIsNone(build_round_receipt(rnd))


class NothingClaimsMoneyMovedTests(TestCase):

    def test_there_is_nothing_to_settle(self):
        rnd, _fs, _ids = _stroke_play_round()
        self.assertEqual(build_round_receipt(rnd).payload['pays'], [])

    def test_the_sub_says_for_fun_instead_of_a_stake(self):
        rnd, _fs, _ids = _stroke_play_round()
        self.assertTrue(
            build_round_receipt(rnd).payload['sub'].endswith('· for fun'))

    def test_the_ticket_says_RESULTS_and_drops_the_settle_block(self):
        from services.receipt_ticket import ticket_html
        rnd, _fs, _ids = _stroke_play_round()
        html = ticket_html(build_round_receipt(rnd).payload, 'web')
        self.assertIn('<em>RESULTS</em>', html)
        self.assertNotIn('RECEIPT', html)
        self.assertNotIn('Simplest way to settle', html)

    def test_a_staked_round_is_untouched(self):
        """The whole money path has to read exactly as it did."""
        from services.receipt_ticket import ticket_html
        rnd, _fs, _ids = _stroke_play_round(
            entry_fee=10, payouts=[{'place': 1, 'amount': 40}], bet_unit=10)
        payload = build_round_receipt(rnd).payload
        self.assertNotIn('forFun', payload)
        self.assertTrue(payload['pays'], 'the money still has to move')
        html = ticket_html(payload, 'web')
        self.assertIn('<em>RECEIPT</em>', html)
        self.assertIn('Simplest way to settle', html)

    def test_the_push_names_no_figure_and_no_win(self):
        """Nobody won anything, so there is no figure to name — and a push
        claiming somebody did would be about a round not played for it."""
        from accounts.models import DeviceToken, User
        from core.models import Player
        from scoring.tests._helpers import _test_account
        from services.receipt_build import notify_receipt
        import services.push as push

        rnd, _fs, ids = _stroke_play_round()
        for i, pid in enumerate(ids.values()):
            player = Player.objects.get(id=pid)
            user = User.objects.create_user(username=f'ff{i}{pid}',
                                            password='x',
                                            account=_test_account())
            user.phone = f'+1310556{pid:04d}'
            user.save()
            player.user, player.phone = user, user.phone
            player.save()
            DeviceToken.objects.create(user=user, token=f'ff{pid}',
                                       platform='ios')
        receipt = build_round_receipt(rnd)
        self.assertTrue(receipt.payload['recipients']['push'],
                        'nobody to push: the fixture proves nothing')

        seen = []
        real = push.send_push
        push.send_push = lambda tokens, title, body, data=None, **k: (
            seen.append((title, body)) or [])
        try:
            notify_receipt(receipt)
        finally:
            push.send_push = real

        self.assertTrue(seen)
        for title, body in seen:
            self.assertEqual(title, 'Round over')
            self.assertIn('View results', body)
            self.assertNotIn('won', body)
            self.assertNotIn('$', body)


class TheChipCarriesTheResultTests(TestCase):

    def test_it_is_the_place_and_the_leader_reads_up(self):
        rnd, _fs, _ids = _stroke_play_round()
        chips = build_round_receipt(rnd).payload['nets']
        self.assertEqual([c['net'] for c in chips],
                         ['1st', '2nd', '3rd', '4th'])
        self.assertEqual([c['tone'] for c in chips],
                         ['up', 'ev', 'ev', 'ev'])

    def test_nobody_reads_DOWN_on_a_round_played_for_nothing(self):
        """A counting game has no loss to report — second of four is neither
        a win nor a loss, and colouring three golfers red would say it was."""
        rnd, _fs, _ids = _stroke_play_round()
        tones = {c['tone'] for c in build_round_receipt(rnd).payload['nets']}
        self.assertNotIn('dn', tones)

    def test_the_chips_are_in_the_games_own_ranking_order(self):
        """Ordering by tone alone left a document reading 1st, 3rd, 3rd,
        2nd — every figure right and the sequence nonsense."""
        rnd, _fs, _ids = _stroke_play_round()
        places = [c['net'] for c in build_round_receipt(rnd).payload['nets']]
        self.assertEqual(places, sorted(places, key=lambda p: int(p[:-2])))


class TheCaptionIsComparableWithTheChipTests(TestCase):
    """The defect a real round exposed.

    A Gross round ranks on gross while the default caption sums the ROUND's
    full-handicap net, so one golfer read "1st" over "net 54" and another
    "3rd" over "net 53" — both correct, and together unreadable.
    """

    def test_a_gross_round_captions_gross(self):
        rnd, _fs, _ids = _stroke_play_round()
        for chip in build_round_receipt(rnd).payload['nets']:
            self.assertTrue(chip['caption'].endswith('gross'),
                            f'{chip["name"]}: {chip["caption"]!r}')

    def test_the_captions_run_the_same_way_as_the_places(self):
        """The property that was broken: a better place must not sit over a
        worse figure.

        **In NET mode, because a gross round cannot pin this.**  There the
        default caption's first figure is the gross, which is also what the
        game ranked on, so the two readings coincide and the test agrees with
        either — the same trap as a fixture whose ids happen to be in order.
        Off a handicap the orders genuinely differ: Dot is last on gross and
        first on net.
        """
        rnd, _fs, _ids = _stroke_play_round(
            mode='net', handicaps=[0, 6, 12, 20])
        chips = build_round_receipt(rnd).payload['nets']
        self.assertEqual(chips[0]['name'][0], 'D',
                         'the fixture must put the gross loser first on net, '
                         'or it cannot tell the two captions apart')
        figures = [int(re.search(r'\d+', c['caption']).group())
                   for c in chips]
        self.assertEqual(figures, sorted(figures),
                         f'a better place sits over a worse figure: {figures}')

    def test_a_golfer_who_played_fewer_holes_says_so(self):
        """Ranking is on net-to-par, so thirteen holes and eighteen compare
        fairly and can tie.  Without the holes said out loud, "1st on 75"
        beside "1st on 94" reads as a fault."""
        rnd, _fs, _ids = _stroke_play_round(short_last=True)
        chips = {c['name']: c['caption']
                 for c in build_round_receipt(rnd).payload['nets']}
        short = next(v for k, v in chips.items() if k.startswith('D'))
        self.assertIn('thru 13', short)
        self.assertTrue(all('thru' not in v for k, v in chips.items()
                            if not k.startswith('D')))


class TheGamesSectionSaysSomethingTests(TestCase):

    def test_it_states_the_results_where_the_money_row_would_be(self):
        """Stroke Play's summary row names who COLLECTED and returns nothing
        without a pot, so a for-fun round would have had an empty section."""
        rnd, _fs, _ids = _stroke_play_round()
        games = build_round_receipt(rnd).payload['games']
        self.assertEqual(len(games), 1)
        label, value = games[0]['rows'][0]
        self.assertEqual(label, 'Stroke Play')
        self.assertIn('1st', value)
        self.assertIn('4th', value)

    def test_a_prize_of_nothing_is_not_listed_as_a_prize(self):
        """A configured table can carry a zero, and "1st  $0" under the
        heading "the pool" describes a pool that does not exist."""
        rnd, _fs, _ids = _stroke_play_round(payouts=[{'place': 1,
                                                      'amount': 0}])
        payload = build_round_receipt(rnd).payload
        for sec in payload.get('webGames') or payload['games']:
            self.assertNotIn('the pool', sec['label'])


class NoFigureOnItIsMoneyTests(TestCase):
    """Several summary rows state money — Banker gives every golfer a
    banked/betting pair, the group pools say "$12 each".  On a round played
    for nothing those read "$0 · $0", which is the "four +$0 lines say
    nothing" failure arriving by the other door."""

    def test_a_money_row_is_dropped_rather_than_printed_as_zero(self):
        """Banker's row is the real case; standing in for it here, because
        building a zero-stake Banker round to make one point is a fixture
        nobody will maintain."""
        # **The registry fills LAZILY.** `receipt_build._load_games()`
        # imports the formatters inside a function, to keep a circular
        # import out of `api.views` — so in a worker where nothing has
        # built a receipt yet, `GAME_SUMMARY` is empty and this read is a
        # KeyError. Shard-order dependent, which is why it passed for
        # months and failed under `--parallel 4` on a different split.
        import services.receipt_games  # noqa: F401
        from services.receipt_build import GAME_SUMMARY, _result_rows
        rnd, _fs, ids = _stroke_play_round()
        key, label = 'low_net_round', 'Stroke Play'
        keep = GAME_SUMMARY[key]
        GAME_SUMMARY[key] = lambda r, e, n: [[label, 'Ann +$0 · Bea +$0']]
        try:
            out = _result_rows(
                rnd, [{'game': key, 'label': label, 'nets': {}}],
                {pid: {'short_name': nm} for nm, pid in ids.items()},
                list(ids.values()))
        finally:
            GAME_SUMMARY[key] = keep
        self.assertTrue(out, 'it should fall back to the results, not vanish')
        self.assertFalse(any('$' in v for _l, v in out), out)

    def test_no_dollar_sign_reaches_a_for_fun_document(self):
        rnd, _fs, _ids = _stroke_play_round()
        payload = build_round_receipt(rnd).payload
        blob = str(payload['nets']) + str(payload['games']) + \
            str(payload.get('webGames') or '') + payload['sub']
        self.assertNotIn('$', blob)


class EveryActiveGameIsAskedTests(TestCase):
    """Honors carries its own stake and is not in `settlement.NETTABLE`, so
    it never reaches `per_game`.  Asking only the games that SETTLED would
    call such a round "for fun" — in the `sub` line, on a document headed
    RESULTS — while a side game's money was on it."""

    def test_an_active_game_with_no_stake_formatter_refuses_the_claim(self):
        rnd, _fs, _ids = _stroke_play_round()
        rnd.active_games = ['low_net_round', 'honors']
        rnd.save(update_fields=['active_games'])
        self.assertIsNone(build_round_receipt(rnd),
                          'a stake nobody can see is not a stake of zero')

    def test_the_settled_game_alone_is_still_for_fun(self):
        rnd, _fs, _ids = _stroke_play_round()
        self.assertTrue(build_round_receipt(rnd).payload['forFun'])


class TheLongFormIsHeldToTheSameRuleTests(TestCase):
    """`webGames` is the WEB page — the one golfers actually read — and every
    `GAME_DETAIL` formatter carries a money column."""

    def test_a_money_row_goes_and_a_section_that_is_not_about_money_stays(self):
        from services.receipt_build import _no_money
        out = _no_money([
            {'label': 'Sixes · the matches',
             'rows': [['1 · holes 1–4', 'Paul & Larry won 4&2'],
                      ['2 · holes 5–10', 'Halved']]},
            {'label': 'Nassau · the bets',
             'rows': [['Front', 'Lipkin/Kim 2 UP · +$0'],
                      ['Overall', 'Lipkin/Kim 1 UP']]},
            {'label': 'Stroke Play · the pool',
             'rows': [['1st', '$0']]},
        ])
        self.assertEqual([s['label'] for s in out],
                         ['Sixes · the matches', 'Nassau · the bets'],
                         'a section left with no rows should go')
        self.assertEqual(len(out[0]['rows']), 2, 'a clean section is untouched')
        self.assertEqual(out[1]['rows'], [['Overall', 'Lipkin/Kim 1 UP']])

    def test_the_filter_is_WIRED_IN_and_not_merely_written(self):
        """The unit test above proves the function; this proves it is
        reached.  Removing the call left every `_no_money` assertion green,
        because no for-fun round this fixture can build produces a detail
        section with money in it — Stroke Play's pool row is already dropped
        and Skins' is a list of holes.  The formatters that DO carry money
        (Nassau's bets, Rabbit's, Banker's) are reachable in a real for-fun
        round and not in a cheap one, so the detail is injected.
        """
        from services.receipt_build import GAME_DETAIL
        rnd, _fs, _ids = _stroke_play_round()
        key = 'low_net_round'
        keep = GAME_DETAIL.get(key)
        GAME_DETAIL[key] = lambda r, e, n: [
            {'label': 'Stroke Play · the bets',
             'rows': [['Front', 'Ann 2 UP · +$0'], ['Overall', 'Ann 1 UP']]}]
        try:
            payload = build_round_receipt(rnd).payload
        finally:
            if keep is None:
                GAME_DETAIL.pop(key, None)
            else:
                GAME_DETAIL[key] = keep
        web = payload.get('webGames') or []
        self.assertTrue(web, 'the injected section should reach the payload')
        self.assertNotIn('$', str(web))
        self.assertIn('Ann 1 UP', str(web), 'the clean row must survive')

    def test_a_staked_round_keeps_every_detail_row(self):
        """The filter is for-fun only: a receipt's long form IS the money."""
        rnd, _fs, _ids = _stroke_play_round(
            entry_fee=10, payouts=[{'place': 1, 'amount': 40}], bet_unit=10)
        payload = build_round_receipt(rnd).payload
        blob = str(payload.get('webGames') or '')
        self.assertIn('$', blob, 'the money must still be on a real receipt')
