"""
scoring/tests/test_messaging_events.py
--------------------------------------
Slice 3, increment 1 — server-generated event messages: birdies/eagles/aces,
withdrawal, round started/complete, and the gross scorecard recap. Calls the
`services.messaging_events` detectors directly (the HTTP hooks just forward to
them) and asserts the event Messages landed in the round thread.
"""
from services import messaging
from services import messaging_events as ev
from tournament.models import Message

from ._helpers import (
    make_course, make_tee, make_round, make_foursome, make_player,
    submit_round, submit_hole,
)
from django.test import TestCase


def _events(round_obj, etype=None):
    thread = messaging.get_or_create_thread(round_obj)
    qs = thread.messages.filter(kind=Message.KIND_EVENT)
    if etype:
        qs = [m for m in qs if (m.data or {}).get('type') == etype]
    return list(qs)


# DEFAULT_HOLES: hole 1 = par 4, hole 3 = par 3, hole 4 = par 5.
class BirdieEventTests(TestCase):
    def setUp(self):
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['skins'])
        self.paul = make_player('Paul Lipkin', 0, short_name='Paul')
        dana = make_player('Dana Wu', 0, short_name='Dana')
        self.fs = make_foursome(self.round, [(self.paul, 0), (dana, 0)],
                                tee=self.tee)

    def _submit(self, hole, gross):
        ev.emit_score_events(
            self.fs, hole, [{'player_id': self.paul.id, 'gross_score': gross}])

    def test_birdie_on_par4(self):
        self._submit(1, 3)  # par 4 → birdie
        birdies = _events(self.round, 'birdie')
        self.assertEqual(len(birdies), 1)
        self.assertIn('Paul', birdies[0].body)
        self.assertEqual(birdies[0].data['hole'], 1)

    def test_eagle_and_albatross_on_par5(self):
        self._submit(4, 3)  # par 5 → eagle (-2)
        self.assertEqual(len(_events(self.round, 'eagle')), 1)
        self.assertEqual(len(_events(self.round, 'albatross')), 0)

    def test_albatross_on_par5(self):
        self._submit(4, 2)  # par 5 → albatross (-3)
        self.assertEqual(len(_events(self.round, 'albatross')), 1)

    def test_ace_is_hole_in_one_not_eagle(self):
        self._submit(3, 1)  # par 3, gross 1 → ace (not eagle)
        self.assertEqual(len(_events(self.round, 'hole_in_one')), 1)
        self.assertEqual(len(_events(self.round, 'eagle')), 0)

    def test_par_emits_nothing(self):
        self._submit(1, 4)  # par
        self.assertEqual(len(_events(self.round)), 0)

    def test_idempotent_no_reannounce(self):
        self._submit(1, 3)              # birdie posts
        self._submit(1, 3)              # same submit again → no duplicate
        self._submit(1, 2)             # later edit (eagle) → key exists, no new card
        self.assertEqual(len(_events(self.round, 'birdie')), 1)
        self.assertEqual(len(_events(self.round, 'eagle')), 0)

    def test_phantom_excluded(self):
        phantom = make_player('Ghost', 0, is_phantom=True)
        from tournament.models import FoursomeMembership
        FoursomeMembership.objects.create(
            foursome=self.fs, player=phantom, tee=self.tee,
            course_handicap=0, playing_handicap=0)
        ev.emit_score_events(
            self.fs, 1, [{'player_id': phantom.id, 'gross_score': 3}])
        self.assertEqual(len(_events(self.round)), 0)


class SkinsEventTests(TestCase):
    def setUp(self):
        from services.skins import setup_skins
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['skins'])
        self.paul = make_player('Paul Lipkin', 0, short_name='Paul')
        self.dana = make_player('Dana Wu', 0, short_name='Dana')
        self.fs = make_foursome(self.round, [(self.paul, 0), (self.dana, 0)],
                                tee=self.tee)
        setup_skins(self.fs, carryover=True)

    def _play(self, hole, paul_gross, dana_gross):
        from services.skins import calculate_skins
        submit_hole(self.fs, hole, [(self.paul, paul_gross), (self.dana, dana_gross)])
        calculate_skins(self.fs)  # _recalculate_games does this in the real flow
        ev.emit_score_events(self.fs, hole, [
            {'player_id': self.paul.id, 'gross_score': paul_gross},
            {'player_id': self.dana.id, 'gross_score': dana_gross},
        ])

    def test_skin_won(self):
        self._play(1, 4, 5)  # par 4 — Paul lower, no birdie noise
        skins = _events(self.round, 'skin')
        self.assertEqual(len(skins), 1)
        self.assertIn('Paul Lipkin won the skin on hole 1', skins[0].body)

    def test_carryover(self):
        self._play(2, 4, 4)  # tie on par 4 → carries
        carries = _events(self.round, 'carryover')
        self.assertEqual(len(carries), 1)
        self.assertIn('Hole 2 halved', carries[0].body)

    def test_carry_accumulates_value(self):
        self._play(2, 4, 4)   # tie → carry
        self._play(3, 4, 5)   # par 3, Paul wins the carried pot (2 skins)
        won = _events(self.round, 'skin')
        self.assertEqual(len(won), 1)
        self.assertIn('Paul Lipkin won 2 skins on hole 3', won[0].body)

    def test_idempotent(self):
        self._play(1, 4, 5)
        self._play(1, 4, 5)  # re-scan same hole
        self.assertEqual(len(_events(self.round, 'skin')), 1)


class MultiSkinsEventTests(TestCase):
    def test_skin_won_across_groups(self):
        from services.multi_skins import setup_multi_skins, calculate_multi_skins
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['multi_skins'])
        paul = make_player('Paul Lipkin', 0, short_name='Paul')
        dana = make_player('Dana Wu', 0, short_name='Dana')
        fs1 = make_foursome(rnd, [(paul, 0)], tee=tee, group_number=1)
        fs2 = make_foursome(rnd, [(dana, 0)], tee=tee, group_number=2)
        setup_multi_skins(rnd, [paul.id, dana.id])
        # Hole 1: Paul (par, no birdie) lower than Dana → wins the round-wide skin.
        submit_hole(fs1, 1, [(paul, 4)])
        submit_hole(fs2, 1, [(dana, 5)])
        calculate_multi_skins(rnd)
        ev.emit_score_events(fs1, 1, [{'player_id': paul.id, 'gross_score': 4}])

        skins = _events(rnd, 'skin')
        self.assertEqual(len(skins), 1)
        self.assertIn('Paul Lipkin won the skin on hole 1', skins[0].body)


class NassauMatchResultTests(TestCase):
    def test_front_nine_result(self):
        from services.nassau import setup_nassau, calculate_nassau
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['nassau'])
        paul = make_player('Paul Lipkin', 0, short_name='Paul')
        dana = make_player('Dana Wu', 0, short_name='Dana')
        fs = make_foursome(rnd, [(paul, 0), (dana, 0)], tee=tee)
        setup_nassau(fs, [paul.id], [dana.id])
        # Paul lower every hole on the front → wins the front nine.
        for h in range(1, 10):
            submit_hole(fs, h, [(paul, 4), (dana, 5)])
        calculate_nassau(fs)
        ev.emit_score_events(fs, 9, [{'player_id': paul.id, 'gross_score': 4},
                                     {'player_id': dana.id, 'gross_score': 5}])

        results = [m for m in _events(rnd, 'match_result')
                   if m.data.get('game') == 'nassau' and m.data.get('unit') == 'front9']
        self.assertEqual(len(results), 1)
        self.assertIn('Paul Lipkin won the front nine', results[0].body)
        # Back nine isn't done → no back9/overall card yet.
        self.assertEqual(
            len([m for m in _events(rnd, 'match_result')
                 if m.data.get('unit') in ('back9', 'overall')]), 0)


class Front9RecapTests(TestCase):
    def setUp(self):
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['skins'])
        self.paul = make_player('Paul Lipkin', 0, short_name='Paul')
        self.dana = make_player('Dana Wu', 0, short_name='Dana')
        self.fs = make_foursome(self.round, [(self.paul, 0), (self.dana, 0)],
                                tee=self.tee)

    def _play_front(self, upto=9, paul=4, dana=5):
        for h in range(1, upto + 1):
            submit_hole(self.fs, h, [(self.paul, paul), (self.dana, dana)])
            ev.emit_score_events(self.fs, h, [
                {'player_id': self.paul.id, 'gross_score': paul},
                {'player_id': self.dana.id, 'gross_score': dana}])

    def test_recap_posts_after_full_front(self):
        self._play_front(9)
        recaps = _events(self.round, 'front9_recap')
        self.assertEqual(len(recaps), 1)
        body = recaps[0].body
        self.assertIn('Paul Lipkin 36', body)  # 9 × 4
        self.assertIn('Dana Wu 45', body)       # 9 × 5
        self.assertLess(body.index('Paul'), body.index('Dana'))  # lowest first

    def test_no_recap_before_front_complete(self):
        self._play_front(8)
        self.assertEqual(len(_events(self.round, 'front9_recap')), 0)

    def test_recap_idempotent(self):
        self._play_front(9)
        submit_hole(self.fs, 9, [(self.paul, 4), (self.dana, 5)])  # an edit
        ev.emit_score_events(self.fs, 9, [
            {'player_id': self.paul.id, 'gross_score': 4},
            {'player_id': self.dana.id, 'gross_score': 5}])
        self.assertEqual(len(_events(self.round, 'front9_recap')), 1)

    def test_withdrawn_front_player_marked_wd_not_blocking(self):
        # Dana withdraws after hole 4; the recap should still fire (she owes no
        # holes 5-9) and show her as WD.
        for h in range(1, 5):
            submit_hole(self.fs, h, [(self.paul, 4), (self.dana, 5)])
        dana_m = self.fs.memberships.get(player=self.dana)
        dana_m.withdrew_after_hole = 4
        dana_m.save(update_fields=['withdrew_after_hole'])
        for h in range(5, 10):
            submit_hole(self.fs, h, [(self.paul, 4)])
        ev.emit_score_events(self.fs, 9,
                             [{'player_id': self.paul.id, 'gross_score': 4}])
        body = _events(self.round, 'front9_recap')[0].body
        self.assertIn('Paul Lipkin 36', body)
        self.assertIn('Dana Wu WD', body)


class NassauPressEventTests(TestCase):
    def setUp(self):
        from services.nassau import setup_nassau
        self.tee = make_tee(make_course())
        self.round = make_round(self.tee.course, active_games=['nassau'])
        self.paul = make_player('Paul Lipkin', 0, short_name='Paul')
        self.dana = make_player('Dana Wu', 0, short_name='Dana')
        self.fs = make_foursome(self.round, [(self.paul, 0), (self.dana, 0)],
                                tee=self.tee)
        setup_nassau(self.fs, [self.paul.id], [self.dana.id],
                     handicap_mode='gross', press_mode='manual')

    def test_press_called_names_trailing_side(self):
        from services.nassau import add_manual_press, calculate_nassau
        # Paul wins holes 1-2 → Dana is down and presses at hole 3.
        for h in (1, 2):
            submit_hole(self.fs, h, [(self.paul, 4), (self.dana, 5)])
        calculate_nassau(self.fs)
        add_manual_press(self.fs, 3)
        ev.emit_nassau_press_called(self.fs, 3)
        called = _events(self.round, 'press_called')
        self.assertEqual(len(called), 1)
        self.assertIn('Dana Wu pressed on hole 3', called[0].body)
        self.assertIn('F9 Press 1', called[0].body)

    def test_press_decided_posts_result(self):
        from services.nassau import add_manual_press, calculate_nassau
        for h in (1, 2):
            submit_hole(self.fs, h, [(self.paul, 4), (self.dana, 5)])
        calculate_nassau(self.fs)
        add_manual_press(self.fs, 3)         # press runs holes 3-9
        for h in range(3, 10):               # Paul wins them all → press to Paul
            submit_hole(self.fs, h, [(self.paul, 4), (self.dana, 5)])
        calculate_nassau(self.fs)
        ev.emit_score_events(self.fs, 9, [
            {'player_id': self.paul.id, 'gross_score': 4},
            {'player_id': self.dana.id, 'gross_score': 5}])
        decided = [m for m in _events(self.round, 'match_result')
                   if m.data.get('game') == 'nassau_press']
        self.assertEqual(len(decided), 1)
        self.assertIn('Paul Lipkin won F9 Press 1', decided[0].body)


class SixesMatchResultTests(TestCase):
    def test_segment_result_uses_player_names(self):
        from services.sixes import setup_sixes, calculate_sixes
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['sixes'])
        paul = make_player('Paul Lipkin', 0, short_name='Paul')
        dana = make_player('Dana Wu', 0, short_name='Dana')
        ed = make_player('Ed Stone', 0, short_name='Ed')
        fay = make_player('Fay Ng', 0, short_name='Fay')
        fs = make_foursome(rnd, [(paul, 0), (dana, 0), (ed, 0), (fay, 0)], tee=tee)
        teams = [{'start_hole': s, 'end_hole': e,
                  'team_select_method': 'manual',
                  'team1_player_ids': [paul.id, dana.id],
                  'team2_player_ids': [ed.id, fay.id]}
                 for s, e in ((1, 6), (7, 12), (13, 18))]
        setup_sixes(fs, teams)
        # Segment 1 = holes 1-6: team1 best ball lower every hole → team1 takes it.
        for h in range(1, 7):
            submit_hole(fs, h, [(paul, 4), (dana, 5), (ed, 5), (fay, 5)])
        calculate_sixes(fs)
        ev.emit_score_events(fs, 6, [{'player_id': paul.id, 'gross_score': 4},
                                     {'player_id': dana.id, 'gross_score': 5},
                                     {'player_id': ed.id, 'gross_score': 5},
                                     {'player_id': fay.id, 'gross_score': 5}])

        results = [m for m in _events(rnd, 'match_result')
                   if m.data.get('game') == 'sixes']
        self.assertEqual(len(results), 1)
        body = results[0].body
        self.assertIn('Paul Lipkin', body)
        self.assertIn('Dana Wu', body)
        self.assertIn('holes 1-6', body)
        # Never use team labels.
        self.assertNotIn('Team 1', body)


class MatchPlayResultTests(TestCase):
    def test_semis_emit_match_results_with_names(self):
        from services.match_play import setup_match_play, calculate_match_play
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['match_play'])
        ps = [make_player(n, 0, short_name=n.split()[0]) for n in
              ('Paul Lipkin', 'Dana Wu', 'Ed Stone', 'Fay Ng')]
        fs = make_foursome(rnd, [(p, 0) for p in ps], tee=tee)
        setup_match_play(fs)
        # Everyone halves every hole on the front → both semis are halved.
        for h in range(1, 10):
            submit_hole(fs, h, [(p, 4) for p in ps])
        calculate_match_play(fs)
        ev.emit_score_events(fs, 9, [{'player_id': p.id, 'gross_score': 4} for p in ps])

        results = [m for m in _events(rnd, 'match_result')
                   if m.data.get('game') == 'match_play']
        self.assertGreaterEqual(len(results), 1)
        self.assertIn('halved', results[0].body)
        self.assertNotIn('Team', results[0].body)


class WithdrawalEventTests(TestCase):
    def test_withdrawal_card(self):
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['skins'])
        paul = make_player('Paul Lipkin', 0, short_name='Paul')
        fs = make_foursome(rnd, [(paul, 0), ('Dana', 0)], tee=tee)
        ev.emit_withdrawal(fs, paul, 9, killed_next=False)
        wd = _events(rnd, 'withdrawal')
        self.assertEqual(len(wd), 1)
        self.assertIn('Paul', wd[0].body)
        self.assertIn('hole 9', wd[0].body)


class RoundLifecycleEventTests(TestCase):
    def test_round_started(self):
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['skins'])
        make_foursome(rnd, [('Paul', 0)], tee=tee)
        ev.emit_round_started(rnd)
        self.assertEqual(len(_events(rnd, 'round_started')), 1)

    def test_round_complete_and_gross_recap(self):
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['skins'])
        paul = make_player('Paul Lipkin', 0, short_name='Paul')
        dana = make_player('Dana Wu', 0, short_name='Dana')
        fs = make_foursome(rnd, [(paul, 0), (dana, 0)], tee=tee)
        # Paul 4s (72), Dana 5s (90).
        submit_round(fs, {h: [(paul, 4), (dana, 5)] for h in range(1, 19)})

        ev.emit_round_complete(rnd)

        self.assertEqual(len(_events(rnd, 'round_complete')), 1)
        report = _events(rnd, 'score_report')
        self.assertEqual(len(report), 1)
        body = report[0].body
        self.assertIn('Paul Lipkin 36-36-72', body)
        self.assertIn('Dana Wu 45-45-90', body)
        # Lowest gross first → Paul before Dana.
        self.assertLess(body.index('Paul'), body.index('Dana'))

    def test_recap_marks_withdrawn_as_wd(self):
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['skins'])
        paul = make_player('Paul Lipkin', 0, short_name='Paul')
        dana = make_player('Dana Wu', 0, short_name='Dana')
        fs = make_foursome(rnd, [(paul, 0), (dana, 0)], tee=tee)
        submit_round(fs, {h: [(paul, 4)] for h in range(1, 19)})
        dana_m = fs.memberships.get(player=dana)
        dana_m.withdrew_after_hole = 5
        dana_m.save(update_fields=['withdrew_after_hole'])

        ev.emit_round_complete(rnd)
        body = _events(rnd, 'score_report')[0].body
        self.assertIn('Paul Lipkin 36-36-72', body)
        self.assertIn('Dana Wu WD', body)

    def test_triple_cup_skips_gross_recap(self):
        tee = make_tee(make_course())
        rnd = make_round(tee.course, active_games=['triple_cup'])
        fs = make_foursome(rnd, [('Paul', 0), ('Dana', 0)], tee=tee)
        paul = fs.memberships.get(player__name='Paul').player
        submit_round(fs, {h: [(paul, 4)] for h in range(1, 19)})
        ev.emit_round_complete(rnd)
        self.assertEqual(len(_events(rnd, 'round_complete')), 1)
        self.assertEqual(len(_events(rnd, 'score_report')), 0)
