"""api/test_cup_explicit_groups.py — the TD's groups survive the save.

Reported during a 46-golfer Ryder Cup build-up: the TD composed one foursome,
one threesome and one twosome on the cup round-setup screen — sizes that
screen's OWN team-composition rules accept — pressed save, and got three
threesomes back.

`cup_round_setup_screen.dart` posted a flat player list carrying no
`group_number`, under a comment asserting the backend "groups first-N into
group 1, next-N into group 2". That is only true when N happens to match.
Without the field `setup_round` takes its AUTO-BALANCE path and re-slices by
`_group_players`, which for 9 golfers is [3, 3, 3].

The second half is the trap that made the obvious fix wrong: round-setup pads
a short group with a phantom ONLY on the auto-balance path, so simply sending
group numbers left every Triple Cup threesome unpadded and
`_ensure_phantom_for_2v1` raised. It creates the membership now.
"""
from datetime import date

from django.test import TestCase

from services.round_setup import setup_round
from services.triple_cup import setup_triple_cup
from tournament.models import (
    Tournament, TeamTournament, TournamentTeam, RyderCupRoundConfig,
)
from core.models import Player, PlayerSex
from scoring.tests._helpers import make_tee, make_round, _test_account


class CupExplicitGroupsTests(TestCase):

    def setUp(self):
        self.acct = _test_account()
        self.tee  = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Cup', start_date=date(2026, 10, 8))
        self.round.tournament = self.tourn
        self.round.save(update_fields=['tournament'])
        self.tt = TeamTournament.objects.create(
            tournament=self.tourn, cup_name='Thursday Cup', players_per_team=5)
        # 2v1 needs a real cup round — it draws donor scores from sibling
        # foursomes, which only a cup round is guaranteed to have.
        RyderCupRoundConfig.objects.create(round=self.round, tournament=self.tt)
        self.teams = [
            TournamentTeam.objects.create(
                tournament=self.tt, name=n, team_number=i + 1, colour=c)
            for i, (n, c) in enumerate([('Orange', 'orange'), ('Blue', 'blue')])
        ]
        # Nine golfers, alternating teams so every group can be split evenly.
        self.players = []
        for i in range(9):
            p = Player.objects.create(
                account=self.acct, name=f'G{i}', short_name=f'G{i}',
                handicap_index=10 + i, sex=PlayerSex.MALE,
            )
            self.teams[i % 2].players.add(p)
            self.players.append(p)

    def _setup(self, sizes):
        """Post the roster sliced into `sizes`, the way the cup screen does."""
        entries, idx = [], 0
        for gi, n in enumerate(sizes):
            for _ in range(n):
                entries.append({'player_id': self.players[idx].pk,
                                'tee_id'   : self.tee.pk,
                                'group_number': gi + 1})
                idx += 1
        setup_round(self.round, entries, randomise=False)
        return [f for f in self.round.foursomes.all().order_by('group_number')]

    def test_a_four_a_three_and_a_two_survive_the_save(self):
        """The reported bug: 4 + 3 + 2 came back as 3 + 3 + 3."""
        fs = self._setup([4, 3, 2])
        real = [f.memberships.filter(player__is_phantom=False).count()
                for f in fs]
        self.assertEqual(real, [4, 3, 2],
                         'the TD composed these groups; the save must keep them')

    def test_without_group_numbers_it_still_auto_balances(self):
        """The default path is unchanged — this is what the bug WAS, and it
        remains correct for anyone who has not chosen groups."""
        entries = [{'player_id': p.pk, 'tee_id': self.tee.pk}
                   for p in self.players]
        setup_round(self.round, entries, randomise=False)
        real = [f.memberships.filter(player__is_phantom=False).count()
                for f in self.round.foursomes.all().order_by('group_number')]
        self.assertEqual(real, [3, 3, 3])

    def test_an_explicit_threesome_still_gets_its_phantom(self):
        """Round-setup pads only what it auto-balanced, so the phantom has to
        come from Triple Cup itself or 2v1 cannot be configured at all."""
        fs = self._setup([4, 3, 2])
        threesome = fs[1]
        self.assertFalse(
            threesome.memberships.filter(player__is_phantom=True).exists(),
            'setup: round-setup must NOT have padded an explicit group',
        )
        ids = list(threesome.memberships
                   .filter(player__is_phantom=False)
                   .values_list('player_id', flat=True))
        # 2v1 — the solo is whichever side has one.
        t1 = [i for i in ids if self.teams[0].players.filter(id=i).exists()]
        t2 = [i for i in ids if self.teams[1].players.filter(id=i).exists()]
        setup_triple_cup(threesome, team1_ids=t1, team2_ids=t2,
                         handicap_mode='gross')
        threesome.refresh_from_db()
        self.assertTrue(
            threesome.memberships.filter(player__is_phantom=True).exists(),
            'the 2v1 phantom must be created, not merely required',
        )
        self.assertTrue(threesome.has_phantom)

    def test_the_twosome_is_a_real_triple_cup_shape(self):
        """A 1v1 twosome plays three matches — the shape the TD was asking
        for when he wanted 11 foursomes and a two."""
        fs = self._setup([4, 3, 2])
        twosome = fs[2]
        ids = list(twosome.memberships
                   .filter(player__is_phantom=False)
                   .values_list('player_id', flat=True))
        t1 = [i for i in ids if self.teams[0].players.filter(id=i).exists()]
        t2 = [i for i in ids if self.teams[1].players.filter(id=i).exists()]
        self.assertEqual((len(t1), len(t2)), (1, 1), 'setup: 1 v 1')
        setup_triple_cup(twosome, team1_ids=t1, team2_ids=t2,
                         handicap_mode='gross')
        self.assertEqual(twosome.triple_cup_game.matches.count(), 3)
        self.assertFalse(
            twosome.memberships.filter(player__is_phantom=True).exists(),
            'a 1v1 uses no phantom partner',
        )
