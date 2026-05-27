"""
scoring/tests/test_round_setup.py
---------------------------------
Tests for services/round_setup.py — specifically the explicit-group
path used by Multi-Foursome Skins where each player picks a group
manually and groups may be size 1–4 (no phantom padding).
"""
from django.test import TestCase

from services.round_setup import setup_round

from ._helpers import (
    make_player,
    make_round,
    make_tee,
)


class ExplicitGroupSetupTests(TestCase):
    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course)
        self.players = [
            make_player(f'P{i}', handicap_index=10) for i in range(1, 6)
        ]

    def _entries(self, *group_assignments):
        """Build a setup_round players list from (player_index, group_no)
        pairs.  player_index is 1-based to match the P1..P5 naming."""
        return [
            {
                'player_id'   : self.players[i - 1].id,
                'tee_id'      : self.tee.id,
                'group_number': g,
            }
            for (i, g) in group_assignments
        ]

    # ── 5 players → 2/2/1 (no phantom) ─────────────────────────────────────

    def test_explicit_groups_create_one_foursome_per_group(self):
        """User assigns 5 players to 3 groups (sizes 2/2/1).  Server
        builds exactly 3 foursomes with the requested sizes and does NOT
        add a phantom to the single-player group."""
        fs_list = setup_round(
            self.round,
            players=self._entries(
                (1, 1), (2, 1),         # group 1 = P1, P2
                (3, 2), (4, 2),         # group 2 = P3, P4
                (5, 3),                 # group 3 = P5 alone
            ),
        )
        assert len(fs_list) == 3, [f.group_number for f in fs_list]
        sizes = sorted(fs.real_players().count() for fs in fs_list)
        assert sizes == [1, 2, 2], sizes
        # No phantom anywhere — single-player groups must keep their own
        # cards uncorrupted by a phantom row.
        for fs in fs_list:
            assert fs.has_phantom is False, fs
            assert all(not m.player.is_phantom for m in fs.memberships.all())

    # ── 4 players, all in one group → single foursome no phantom ──────────

    def test_explicit_groups_full_foursome_no_phantom(self):
        """4-player group via explicit assignment behaves the same as
        auto-grouping: no phantom needed."""
        fs_list = setup_round(
            self.round,
            players=self._entries(
                (1, 1), (2, 1), (3, 1), (4, 1),
            ),
        )
        assert len(fs_list) == 1
        assert fs_list[0].has_phantom is False
        assert fs_list[0].real_players().count() == 4

    # ── Missing group_number on some entries is rejected ──────────────────

    def test_partial_group_number_raises(self):
        """If any entry has group_number, every entry must — otherwise
        the caller would get a half-explicit / half-auto split, which
        is ambiguous."""
        players = [
            {'player_id': self.players[0].id, 'tee_id': self.tee.id,
             'group_number': 1},
            {'player_id': self.players[1].id, 'tee_id': self.tee.id},
        ]
        with self.assertRaises(ValueError):
            setup_round(self.round, players=players)

    # ── Auto-group fallback still works (no group_number anywhere) ────────

    def test_auto_group_path_unchanged_for_legacy_callers(self):
        """No group_number → original auto-partition behaviour.  5 real
        players auto-partition into 2 groups (size 3 + 2 via the
        even-distribution fallback).  This Round has no parent Tournament,
        so the smaller groups DO NOT get a phantom — casual rounds keep
        the user's exact roster."""
        players_no_groups = [
            {'player_id': p.id, 'tee_id': self.tee.id}
            for p in self.players  # 5 players
        ]
        fs_list = setup_round(self.round, players=players_no_groups,
                              randomise=False)
        assert len(fs_list) >= 1
        # Casual rounds: never pad with a phantom.
        for fs in fs_list:
            assert fs.has_phantom is False, fs

    def test_tournament_auto_group_still_pads_with_phantom(self):
        """Tournament rounds keep the old behaviour: any auto-grouped
        foursome smaller than 4 real players gets a phantom 4th to fill
        the team for games that require exactly 4 (Sixes, Pink Ball)."""
        from tournament.models import Tournament
        from datetime import date
        from ._helpers import _test_account
        tournament = Tournament.objects.create(
            account=_test_account(),
            name='T1', start_date=date.today(),
        )
        t_round = make_round(self.tee.course)
        t_round.tournament = tournament
        t_round.save(update_fields=['tournament'])

        players_no_groups = [
            {'player_id': p.id, 'tee_id': self.tee.id}
            for p in self.players  # 5 players
        ]
        fs_list = setup_round(t_round, players=players_no_groups,
                              randomise=False)
        for fs in fs_list:
            real_count = fs.real_players().count()
            assert fs.has_phantom == (real_count < 4), (real_count, fs.has_phantom)
