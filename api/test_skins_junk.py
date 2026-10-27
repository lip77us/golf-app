"""
api/test_skins_junk.py
----------------------
Skins junk, set up like Spots: types, the greenie pick and its carry, through
the serializer/view/urls.

**A junk is worth a skin** — one share of the same pot — so what these check
is that the types reach `total_skins`, not that junk settles on its own. The
vocabulary itself is `services/spot_types.py`, shared with Spots.
"""
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.test import TestCase
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account
from core.models import Course, Player, Tee
from scoring.models import HoleScore
from tournament.models import Foursome, FoursomeMembership, Round

User = get_user_model()

#: 3 and 7 are par 3s, because a greenie exists on nothing else.
HOLES = [{'number': n, 'par': (3 if n in (3, 7) else 4),
          'stroke_index': n, 'yards': 400} for n in range(1, 19)]


class _Base(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name='Junk Club')
        self.user = User.objects.create_user(username='td', account=self.acct)
        course = Course.objects.create(account=self.acct, name='Pebble')
        self.tee = Tee.objects.create(
            course=course, tee_name='White', slope=113,
            course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.round = Round.objects.create(
            account=self.acct, course=course, status='in_progress',
            active_games=['skins'], bet_unit=Decimal('1.00'))
        self.fs = Foursome.objects.create(round=self.round, group_number=1)
        self.ids = []
        for n in ('A', 'B', 'C', 'D'):
            p = Player.objects.create(account=self.acct, name=n,
                                      handicap_index=Decimal('0'))
            FoursomeMembership.objects.create(
                foursome=self.fs, player=p, tee=self.tee,
                course_handicap=0, playing_handicap=0)
            self.ids.append(p.id)
        self.client = APIClient()
        self.client.force_authenticate(self.user)

    def setup_skins(self, **over):
        body = {'handicap_mode': 'gross', 'carryover': True,
                'allow_junk': True}
        body.update(over)
        return self.client.post(
            reverse('api-skins-setup', args=[self.fs.id]), body, format='json')

    def junk(self, hole, pid, types):
        return self.client.post(
            reverse('api-skins-junk', args=[self.fs.id]),
            {'hole_number': hole,
             'junk_entries': [{'player_id': pid, 'types': types}]},
            format='json')

    def greenie(self, hole, pid):
        return self.client.post(
            reverse('api-skins-greenie', args=[self.fs.id]),
            {'hole_number': hole, 'player_id': pid}, format='json')

    def junk_of(self, data, pid):
        return next(p['junk_skins'] for p in data['players']
                    if p['player_id'] == pid)


class TypesTests(_Base):

    def test_setup_round_trips_junks_own_settings(self):
        r = self.setup_skins(junk_types=['greenie', 'sandy', 'birdie'],
                             junk_birdie_basis='net_so',
                             junk_net_percent=90,
                             junk_greenie_carry=False)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual([t['type'] for t in r.data['junk_in_play']],
                         ['greenie', 'sandy', 'birdie'])
        self.assertEqual(r.data['junk_birdie_basis'], 'net_so')
        self.assertFalse(r.data['junk_greenie']['carry'])

    def test_the_sheet_excludes_the_greenie_and_the_derived_ones(self):
        r = self.setup_skins(junk_types=['greenie', 'sandy', 'birdie',
                                         'eagle', 'snake'])
        self.assertEqual([t['type'] for t in r.data['junk_sheet_types']],
                         ['sandy', 'snake'])

    def test_junk_OFF_reports_nothing_in_play(self):
        r = self.setup_skins(allow_junk=False, junk_types=['sandy'])
        self.assertEqual(r.data['junk_in_play'], [])
        self.assertEqual(r.data['junk_sheet_types'], [])

    def test_a_tick_lands_in_the_total(self):
        self.setup_skins(junk_types=['sandy', 'chippy'])
        r = self.junk(5, self.ids[1], ['sandy', 'chippy'])
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self.junk_of(r.data, self.ids[1]), 2)
        entry = next(e for h in r.data['holes'] if h['hole'] == 5
                     for e in h['junk'] if e['player_id'] == self.ids[1])
        self.assertEqual([t['label'] for t in entry['types']],
                         ['Sandy', 'Chippy'])

    def test_an_empty_list_clears_the_hole(self):
        self.setup_skins(junk_types=['sandy'])
        self.junk(5, self.ids[1], ['sandy'])
        r = self.junk(5, self.ids[1], [])
        self.assertEqual(self.junk_of(r.data, self.ids[1]), 0)

    def test_a_birdie_needs_no_tally(self):
        self.setup_skins(junk_types=['birdie'])
        HoleScore.objects.create(foursome=self.fs, player_id=self.ids[0],
                                 hole_number=1, gross_score=3)   # par 4
        got = self.client.get(reverse('api-skins-result', args=[self.fs.id]))
        self.assertEqual(self.junk_of(got.data, self.ids[0]), 1)


    def test_junk_ON_with_nothing_ticked_is_refused(self):
        """A switch that counts nothing is a switch that does nothing, and
        the handoff asks for at least one."""
        r = self.setup_skins(junk_types=[])
        self.assertEqual(r.status_code, 400, r.data)
        self.assertIn('at least one', r.data['detail'].lower())

    def test_junk_OFF_with_nothing_ticked_is_fine(self):
        """Off keeps whatever was last picked, so turning it back on does
        not lose the group's agreement."""
        r = self.setup_skins(allow_junk=False, junk_types=[])
        self.assertEqual(r.status_code, 201, r.data)

    def test_the_catalogue_names_every_type(self):
        """The setup checklist draws the UNTICKED rows too, so it needs the
        whole list — and must not keep its own copy of the names."""
        from core.models import SpotType
        r = self.setup_skins(junk_types=['sandy'])
        self.assertEqual([t['type'] for t in r.data['junk_catalogue']],
                         [str(t) for t in SpotType])


class GreenieTests(_Base):

    def test_a_winner_who_pars_takes_it(self):
        self.setup_skins(junk_types=['greenie'])
        HoleScore.objects.create(foursome=self.fs, player_id=self.ids[0],
                                 hole_number=3, gross_score=3)
        r = self.greenie(3, self.ids[0])
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self.junk_of(r.data, self.ids[0]), 1)

    def test_NOBODY_rolls_it_and_a_carried_greenie_is_worth_2_JUNK(self):
        self.setup_skins(junk_types=['greenie'])
        self.client.post(reverse('api-skins-greenie', args=[self.fs.id]),
                         {'hole_number': 3, 'player_id': None}, format='json')
        HoleScore.objects.create(foursome=self.fs, player_id=self.ids[1],
                                 hole_number=7, gross_score=3)
        r = self.greenie(7, self.ids[1])
        self.assertEqual(self.junk_of(r.data, self.ids[1]), 2)
        g7 = next(h for h in r.data['junk_greenie']['holes'] if h['hole'] == 7)
        self.assertEqual((g7['worth'], g7['carried_from']), (2, 3))

    def test_DELETE_puts_it_back_to_undecided(self):
        self.setup_skins(junk_types=['greenie'])
        self.client.post(reverse('api-skins-greenie', args=[self.fs.id]),
                         {'hole_number': 3, 'player_id': None}, format='json')
        r = self.client.delete(
            reverse('api-skins-greenie', args=[self.fs.id]),
            {'hole_number': 3}, format='json')
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data['junk_greenie']['next']['worth'], 1)

    def test_a_golfer_from_another_group_is_refused(self):
        self.setup_skins(junk_types=['greenie'])
        other = Player.objects.create(account=self.acct, name='Z',
                                      handicap_index=Decimal('0'))
        self.assertEqual(self.greenie(3, other.id).status_code, 400)


class TheShippedAppTests(_Base):
    """The same window Spots has, and the same rule.

    The app release goes through review on Apple's schedule, so production
    runs this backend while phones run 2.11.2. Unlike Spots, junk HAS been
    played — sixteen rows in four completed rounds — so the stakes are a
    little higher and the behaviour is pinned rather than reasoned about.
    """

    def test_the_old_setup_body_still_works(self):
        r = self.client.post(reverse('api-skins-setup', args=[self.fs.id]),
                             {'handicap_mode': 'gross', 'carryover': True,
                              'allow_junk': True}, format='json')
        self.assertEqual(r.status_code, 201, r.data)

    def test_it_is_NOT_paid_for_junk_it_cannot_show(self):
        """Birdie and Eagle are read off the scores. On a phone with no
        notion of them they would move money for a reason nobody on that
        screen can see — and here that money is a share of the skins pot,
        so it moves everybody else's payout too."""
        self.client.post(reverse('api-skins-setup', args=[self.fs.id]),
                         {'handicap_mode': 'gross', 'allow_junk': True},
                         format='json')
        HoleScore.objects.create(foursome=self.fs, player_id=self.ids[0],
                                 hole_number=1, gross_score=3)   # a birdie
        got = self.client.get(reverse('api-skins-result', args=[self.fs.id]))
        self.assertEqual(self.junk_of(got.data, self.ids[0]), 0)
        slugs = [t['type'] for t in got.data['junk_in_play']]
        self.assertNotIn('birdie', slugs)
        self.assertNotIn('eagle', slugs)
        self.assertIn('sandy', slugs)

    def test_the_old_junk_body_is_refused_rather_than_guessed_at(self):
        """`junk_count: 2` cannot become ticks — one of each type per hole —
        so it fails loudly instead of paying the wrong number quietly."""
        self.setup_skins(junk_types=['sandy'])
        r = self.client.post(
            reverse('api-skins-junk', args=[self.fs.id]),
            {'hole_number': 5,
             'junk_entries': [{'player_id': self.ids[0], 'junk_count': 2}]},
            format='json')
        self.assertEqual(r.status_code, 400, r.data)


class SkinValidationEndpointTests(_Base):
    """The two validation rules through the serializer / view / urls.

    `services/skin_rules.py` owns the semantics and `scoring/tests/` prove the
    engines; what these cover is the boundary — that the settings round-trip,
    that the summary reports them, and that a client which says nothing keeps
    playing plain skins.
    """

    def _score(self, hole, scores):
        """scores: {player_index: gross}."""
        for idx, gross in scores.items():
            HoleScore.objects.update_or_create(
                foursome=self.fs, player_id=self.ids[idx],
                hole_number=hole, defaults={'gross_score': gross},
            )

    def _summary(self):
        r = self.client.get(reverse('api-skins-result', args=[self.fs.id]))
        self.assertEqual(r.status_code, 200, r.data)
        return r.data

    def test_the_settings_round_trip(self):
        r = self.setup_skins(skin_minimum='gross_par', birdie_steal=True)
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data['skin_minimum'], 'gross_par')
        self.assertTrue(r.data['birdie_steal'])
        s = self._summary()
        self.assertEqual(s['skin_minimum'], 'gross_par')
        self.assertTrue(s['birdie_steal'])

    def test_the_summary_carries_a_phrase_for_the_board(self):
        self.setup_skins(skin_minimum='net_par', birdie_steal=True)
        line = self._summary()['skin_rules']
        self.assertIn('net par', line)
        self.assertIn('steal', line)

    def test_plain_skins_gets_an_empty_phrase_not_a_sentence(self):
        """So a client can test it rather than print "no minimum" at a group
        that never asked for one."""
        self.setup_skins()
        s = self._summary()
        self.assertEqual(s['skin_rules'], '')
        self.assertEqual(s['skin_minimum'], 'none')
        self.assertFalse(s['birdie_steal'])

    def test_a_client_that_sends_nothing_plays_plain_skins(self):
        """The shipped app sends neither field; it must not start validating."""
        r = self.client.post(
            reverse('api-skins-setup', args=[self.fs.id]),
            {'handicap_mode': 'gross', 'carryover': True}, format='json')
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data['skin_minimum'], 'none')
        self.assertFalse(r.data['birdie_steal'])

    def test_a_bad_minimum_is_a_400_not_a_silent_rule(self):
        r = self.setup_skins(skin_minimum='eagle_or_better')
        self.assertEqual(r.status_code, 400, r.data)

    def test_gross_par_changes_who_the_endpoint_pays(self):
        """Everybody over par on hole 1: with the minimum nobody wins it."""
        # A is scratch, all four are — so gross == net and nobody can validate
        # a 5 on a par 4.
        self.setup_skins(handicap_mode='gross', skin_minimum='gross_par')
        self._score(1, {0: 5, 1: 6, 2: 6, 3: 6})
        self.client.post(reverse('api-skins-setup', args=[self.fs.id]),
                         {'handicap_mode': 'gross', 'carryover': True,
                          'skin_minimum': 'gross_par'}, format='json')
        hole1, = [h for h in self._summary()['holes'] if h['hole'] == 1]
        self.assertIsNone(hole1['winner_id'])

    def test_without_the_minimum_that_same_hole_is_won(self):
        self.setup_skins(handicap_mode='gross')
        self._score(1, {0: 5, 1: 6, 2: 6, 3: 6})
        self.client.post(reverse('api-skins-setup', args=[self.fs.id]),
                         {'handicap_mode': 'gross', 'carryover': True},
                         format='json')
        hole1, = [h for h in self._summary()['holes'] if h['hole'] == 1]
        self.assertEqual(hole1['winner_id'], self.ids[0])
