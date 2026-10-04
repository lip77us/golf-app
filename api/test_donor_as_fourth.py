"""Does the donor act as a full 4th on his hole? Paul's scenario, exactly."""
from decimal import Decimal
from django.test import TestCase
from core.models import Player, PlayerSex
from scoring.tests._helpers import make_tee, make_round, _test_account
from scoring.phantom import CROSS_FOURSOME_ALGORITHM_ID
from services.triple_cup import _whs_so_net_index
from tournament.models import Foursome, FoursomeMembership

# Hole 1 is SI 5 — "the 5th hardest hole".
HOLES = [{'number': 1, 'par': 4, 'stroke_index': 5, 'yards': 400}] + [
    {'number': n, 'par': 4, 'stroke_index': n, 'yards': 400}
    for n in range(2, 19)
]

class _G:                      # stand-in for the TripleCupGame row
    def __init__(self, fb_pct):
        self.group_size = 3
        self.net_percent = 100
        self.fourball_percent = fb_pct
        self.singles_percent = 100
        self.alt_shot_low_pct = 50
        self.alt_shot_high_pct = 50

class DonorAsFourthTests(TestCase):
    def _build(self, live_ph, donor_ph, fb_pct):
        acct = _test_account()
        tee  = make_tee(holes=HOLES)
        rnd  = make_round(tee.course, handicap_mode='strokes_off_low')
        fs   = Foursome.objects.create(round=rnd, group_number=1,
                                       has_phantom=True)
        members = {}
        for i in range(3):
            p = Player.objects.create(account=acct, name=f'L{i}',
                                      short_name=f'L{i}',
                                      handicap_index=live_ph,
                                      sex=PlayerSex.MALE)
            m = FoursomeMembership.objects.create(
                foursome=fs, player=p, tee=tee,
                course_handicap=live_ph, playing_handicap=live_ph)
            members[p.pk] = m
        ph = Player.objects.create(account=acct, name='Phantom',
                                   short_name='Ph', handicap_index=0,
                                   sex=PlayerSex.MALE, is_phantom=True)
        donor = Player.objects.create(account=acct, name='Donor',
                                      short_name='Dn',
                                      handicap_index=donor_ph,
                                      sex=PlayerSex.MALE)
        pm = FoursomeMembership.objects.create(
            foursome=fs, player=ph, tee=tee,
            course_handicap=0, playing_handicap=0,
            phantom_algorithm=CROSS_FOURSOME_ALGORITHM_ID,
            phantom_config={'rotation': [donor.pk],
                            'donor_names': {str(donor.pk): 'Donor'},
                            'donor_handicaps': {str(donor.pk): donor_ph}})
        members[ph.pk] = pm
        gross = {pid: {1: 5} for pid in members}
        net = _whs_so_net_index(fs, _G(fb_pct), members, gross,
                                include_phantom=True, fourball_holes={1,2,3,4,5,6})
        # strokes = gross - net, for the three live players
        return sorted(5 - net[pid][1] for pid, m in members.items()
                      if not m.player.is_phantom)

    def test_donor_three_below_gives_no_stroke_on_si5(self):
        self.assertEqual(self._build(20, 17, 100), [0, 0, 0])

    def test_donor_five_below_gives_each_live_player_a_stroke_on_si5(self):
        self.assertEqual(self._build(20, 15, 100), [1, 1, 1])

    def test_at_90_percent_fourball_the_allowance_scales_first(self):
        # SO 5 x 90% = 4.5 -> round half up -> 5, so SI 5 still strokes.
        self.assertEqual(self._build(20, 15, 90), [1, 1, 1])
        # SO 4 x 90% = 3.6 -> 4, SI 5 > 4 -> none.
        self.assertEqual(self._build(20, 16, 90), [0, 0, 0])

    def test_the_donor_himself_plays_off_scratch_when_he_is_low(self):
        acct_strokes = self._build(20, 15, 100)
        self.assertEqual(acct_strokes, [1, 1, 1])
