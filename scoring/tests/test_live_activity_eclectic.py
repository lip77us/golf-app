"""
scoring/tests/test_live_activity_eclectic.py
--------------------------------------------
Eclectic on the lock screen.

It has no card of its own — side games never do — so what is tested is when it
takes the tournament Stroke Play card's quiet slot and when it stays silent.
The silences are the subject: **round 1 never shows it**, and a hole that
improved nothing says nothing.
"""
from datetime import date

from django.test import TestCase

from core.models import RoundStatus
from games.models import EclecticConfig, LowNetChampionshipConfig
from services.live_activity_eclectic import eclectic_news, footer_line
from services.live_activity_stroke_play import stroke_play_activity_state
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
        self.tourn.active_games = ['low_net', 'eclectic']
        self.tourn.save()
        LowNetChampionshipConfig.objects.create(tournament=self.tourn)

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

        self.cfg = EclecticConfig.objects.create(
            tournament=self.tourn, gross_entry_fee=10,
            gross_payouts=[{'place': 1, 'amount': 160}],
            net_entry_fee=10, net_payouts=[{'place': 1, 'amount': 160}])

    def play(self, idx, player, upto=18, offsets=None):
        for h in range(1, upto + 1):
            submit_hole(self.foursomes[idx], h,
                        [(player.id, PAR[h] + (offsets or {}).get(h, 0))])

    def news(self, idx, hole, player=None):
        return eclectic_news(self.tourn, self.rounds[idx],
                             (player or self.ann).id, hole)


class SilenceTests(_Base):
    def test_round_one_never_shows_it(self):
        # Every hole of the first round improves a card with nothing in it.
        # An announcement that fires eighteen times is a status bar.
        self.play(0, self.ann, upto=7)
        block = self.news(0, 7)
        self.assertIsNone(block['improved_hole'])
        self.assertEqual(footer_line(block), '')

    def test_a_hole_that_improved_nothing_says_nothing(self):
        self.play(0, self.ann)                      # level par round 1
        self.play(1, self.ann, upto=7, offsets={7: 2})   # a double on the 7th
        self.assertIsNone(self.news(1, 7)['improved_hole'])

    def test_a_golfer_not_entered_gets_no_block(self):
        cal = make_player('Cal', handicap_index=0)
        self.assertEqual(eclectic_news(self.tourn, self.rounds[1], cal.id, 7),
                         {})

    def test_no_eclectic_means_no_block(self):
        self.cfg.delete()
        self.tourn.refresh_from_db()
        self.assertEqual(self.news(1, 7), {})

    def test_a_one_round_event_has_nothing_to_improve_on(self):
        self.rounds[1].delete()
        self.tourn.refresh_from_db()
        self.assertEqual(
            eclectic_news(self.tourn, self.rounds[0], self.ann.id, 7), {})


class ImprovementTests(_Base):
    def test_a_better_score_on_a_later_round_is_news(self):
        self.play(0, self.ann)                           # level par
        self.play(1, self.ann, upto=7, offsets={7: -1})  # birdie the 7th
        block = self.news(1, 7)
        self.assertEqual(block['improved_hole'], 7)
        self.assertEqual(block['pool'], 'gross')
        self.assertIn('Improved on 7', footer_line(block))

    def test_an_equal_score_is_not_an_improvement(self):
        # The engine keeps the EARLIER round on a tie, so an equal score on a
        # later round is not kept — and nothing happened.
        self.play(0, self.ann)
        self.play(1, self.ann, upto=7)
        self.assertIsNone(self.news(1, 7)['improved_hole'])

    def test_the_line_names_the_hole_the_place_and_the_pool(self):
        self.play(0, self.ann)
        self.play(0, self.bea, offsets={2: -1})
        self.play(1, self.ann, upto=7, offsets={7: -1})
        self.play(1, self.bea, upto=7)
        line = footer_line(self.news(1, 7))
        self.assertRegex(line, r'^Improved on 7 · \w+ gross$')

    def test_a_tie_reads_T_in_the_line(self):
        self.play(0, self.ann)
        self.play(0, self.bea)
        self.play(1, self.ann, upto=7, offsets={7: -1})
        self.play(1, self.bea, upto=7, offsets={7: -1})
        line = footer_line(self.news(1, 7))
        self.assertIn('T1', line)

    def test_an_improvement_that_changes_NO_PLACE_still_shows(self):
        # **Ruled 26 Sep 2026**, settling the packet's one open question.
        #
        # The eclectic is the one game a golfer cannot see on his own card: the
        # score he just made either went onto it or it did not, and only the
        # server knows which. Gating on a place change would mean a golfer who
        # just birdied a hole he had been carrying a double on is told nothing,
        # because nobody else moved.
        #
        # Here Ann is alone at the top before and after — rank 1 both times —
        # and the line fires anyway.
        self.play(0, self.ann, offsets={7: 2})   # a double on the 7th
        self.play(1, self.ann, upto=6)
        self.play(0, self.bea, offsets={h: 3 for h in range(1, 19)})
        self.play(1, self.bea, upto=6, offsets={h: 3 for h in range(1, 7)})

        before = self.news(1, 6)
        self.assertEqual(before['place'], 1)

        # Now par the 7th — better than the double, so it is kept. His place
        # does not move: he was 1st and he is still 1st.
        self.play(1, self.ann, upto=7)
        self.play(1, self.bea, upto=7, offsets={7: 3})
        after = self.news(1, 7)
        self.assertEqual(after['place'], 1)
        self.assertEqual(after['improved_hole'], 7)
        self.assertIn('Improved on 7', footer_line(after))

    def test_nothing_in_the_block_compares_places_before_and_after(self):
        # A guard on the RULE rather than on one case: the module must not
        # grow a "did the place move" test, because that is the behaviour the
        # ruling rejected.
        import inspect
        from services import live_activity_eclectic as mod
        src = inspect.getsource(mod)
        for banned in ('previous_place', 'place_changed', 'prev_rank',
                       'last_place'):
            self.assertNotIn(banned, src)

    def test_the_higher_place_picks_the_pool(self):
        # Ann is off 18, so the net pool flatters her. With both improved, the
        # pool she places higher in is the one named.
        cal = make_player('Cal', handicap_index=18)
        for fs in self.foursomes:
            fs.memberships.create(player=cal, tee=self.tee,
                                  course_handicap=18, playing_handicap=18)
        self.play(0, self.ann, offsets={h: -1 for h in range(1, 19)})
        self.play(1, self.ann)
        self.play(0, cal)
        self.play(1, cal, upto=7, offsets={7: -1})
        block = eclectic_news(self.tourn, self.rounds[1], cal.id, 7)
        # He is last gross and leads net, so the card names net.
        self.assertEqual(block['pool'], 'net')


class FinalTests(_Base):
    def test_the_final_state_names_both_pools(self):
        self.play(0, self.ann)
        self.play(1, self.ann)
        self.play(0, self.bea)
        self.play(1, self.bea)
        for r in self.rounds:
            r.status = RoundStatus.COMPLETE
            r.save(update_fields=['status'])
        block = self.news(1, 18)
        self.assertIsNotNone(block['final'])
        self.assertEqual(set(block['final']), {'gross', 'net'})
        line = footer_line(block)
        self.assertIn('gross', line)
        self.assertIn('net', line)

    def test_only_the_pool_the_reader_is_in_is_named(self):
        self.cfg.net_on = False
        self.cfg.save(update_fields=['net_on'])
        self.play(0, self.ann)
        self.play(1, self.ann)
        for r in self.rounds:
            r.status = RoundStatus.COMPLETE
            r.save(update_fields=['status'])
        line = footer_line(self.news(1, 18))
        self.assertIn('gross', line)
        self.assertNotIn('net', line)


class CardTests(_Base):
    """What it does to the Stroke Play card it borrows."""

    def _state(self, idx, thru):
        return stroke_play_activity_state(
            self.rounds[idx], self.foursomes[idx],
            player_id=self.ann.id, thru=thru)

    def test_with_no_news_the_footer_is_byte_for_byte_what_it_was(self):
        self.play(0, self.ann, upto=7)
        self.play(0, self.bea, upto=7)
        state = self._state(0, 7)
        self.assertEqual(state['footer'], {'context': 'FIELD 2', 'money': ''})
        self.assertNotIn('eclectic', state)

    def test_with_news_it_takes_the_quiet_slot_and_FIELD_stays(self):
        # **The card does not grow.** `FIELD n` moves one slot right rather
        # than off the card.
        self.play(0, self.ann)
        self.play(0, self.bea)
        self.play(1, self.ann, upto=7, offsets={7: -1})
        self.play(1, self.bea, upto=7)
        state = self._state(1, 7)
        self.assertIn('Improved on 7', state['footer']['context'])
        self.assertEqual(state['footer']['money'], 'FIELD 2')
        self.assertEqual(state['footer']['label'], 'ECLECTIC')
        self.assertEqual(state['eclectic']['improved_hole'], 7)

    def test_the_tag_and_the_line_are_never_the_same_string(self):
        # An installed build does not know `label` and draws the line alone.
        # If the tag were inside the line too, a new build would print
        # `ECLECTIC ECLECTIC · Improved on 7`.
        self.play(0, self.ann)
        self.play(0, self.bea)
        self.play(1, self.ann, upto=7, offsets={7: -1})
        self.play(1, self.bea, upto=7)
        footer = self._state(1, 7)['footer']
        self.assertNotIn('ECLECTIC', footer['context'])

    def test_it_clears_on_the_next_score(self):
        self.play(0, self.ann)
        self.play(0, self.bea)
        self.play(1, self.ann, upto=7, offsets={7: -1})
        self.play(1, self.bea, upto=7)
        self.assertIn('Improved', self._state(1, 7)['footer']['context'])
        # Hole 8 matched round 1 rather than beating it — the line goes.
        self.play(1, self.ann, upto=8)
        self.play(1, self.bea, upto=8)
        state = self._state(1, 8)
        self.assertEqual(state['footer'], {'context': 'FIELD 2', 'money': ''})

    def test_a_casual_round_is_untouched(self):
        # No tournament, so nothing is even looked up.
        casual = make_round(course=self.course)
        fs = make_foursome(casual, [(self.ann, 0), (self.bea, 0)], tee=self.tee)
        for h in range(1, 8):
            submit_hole(fs, h, [(self.ann.id, PAR[h]), (self.bea.id, PAR[h])])
        state = stroke_play_activity_state(casual, fs,
                                           player_id=self.ann.id, thru=7)
        self.assertEqual(state['footer'], {'context': 'FIELD 2', 'money': ''})
