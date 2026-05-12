"""
management command: fix_singles_1v2

Diagnoses and optionally repairs a cup-singles bracket where a 1v2 (or 2v1)
singles match was set up with only ONE MatchPlayMatch instead of two.

Usage
-----
# List ALL cup_singles foursomes across every round/tournament:
python manage.py fix_singles_1v2

# Filter by player name (case-insensitive, partial match):
python manage.py fix_singles_1v2 --player ryan

# Filter to a specific round number (e.g. round 6):
python manage.py fix_singles_1v2 --round-number 6

# Inspect a specific foursome:
python manage.py fix_singles_1v2 --foursome 42

# Fix a specific foursome — supply explicit player pairs:
python manage.py fix_singles_1v2 --foursome 42 \\
    --pair "RYAN_ID:P1_ID" --pair "RYAN_ID:P2_ID" --apply
"""

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction


class Command(BaseCommand):
    help = (
        'Diagnose / fix cup-singles brackets where a 1v2 group was '
        'set up with only one match instead of two.'
    )

    def add_arguments(self, parser):
        parser.add_argument(
            '--foursome', type=int, default=None,
            help='Foursome ID to inspect/fix.',
        )
        parser.add_argument(
            '--player', type=str, default=None,
            help='Filter foursomes by player name (partial, case-insensitive).',
        )
        parser.add_argument(
            '--round-number', type=int, default=None, dest='round_number',
            help='Filter to a specific round number (e.g. 6 for day 6).',
        )
        parser.add_argument(
            '--pair', action='append', dest='pairs', default=[],
            metavar='P1_ID:P2_ID',
            help='Explicit match pairing as "player1_id:player2_id". '
                 'Repeat for each match. Required with --apply.',
        )
        parser.add_argument(
            '--apply', action='store_true', default=False,
            help='Actually fix the bracket (default: dry-run / inspect only).',
        )

    def handle(self, *args, **options):
        from games.models import MatchPlayBracket
        from tournament.models import Foursome, FoursomeMembership

        foursome_id  = options['foursome']
        player_name  = options['player']
        round_number = options['round_number']
        apply        = options['apply']
        raw_pairs    = options['pairs']

        # ── Locate foursomes ────────────────────────────────────────────────
        if foursome_id:
            foursomes = Foursome.objects.filter(pk=foursome_id)
            if not foursomes.exists():
                raise CommandError(f'No foursome with id={foursome_id}')
        else:
            # Start from foursomes that have a cup_singles bracket
            bracket_fs_ids = MatchPlayBracket.objects.filter(
                bracket_type='cup_singles'
            ).values_list('foursome_id', flat=True)
            foursomes = Foursome.objects.filter(pk__in=bracket_fs_ids)

            # Also catch singles_18 foursomes that may have no bracket yet
            singles_fs_ids = Foursome.objects.filter(
                active_games__contains=['singles_18']
            ).values_list('id', flat=True)
            all_ids = set(bracket_fs_ids) | set(singles_fs_ids)
            foursomes = Foursome.objects.filter(pk__in=all_ids)

            if round_number is not None:
                foursomes = foursomes.filter(round__round_number=round_number)

            if player_name:
                member_fs_ids = FoursomeMembership.objects.filter(
                    player__name__icontains=player_name,
                    player__is_phantom=False,
                ).values_list('foursome_id', flat=True)
                foursomes = foursomes.filter(pk__in=member_fs_ids)

            if not foursomes.exists():
                self.stdout.write(
                    'No cup_singles / singles_18 foursomes found'
                    + (f' for player "{player_name}"' if player_name else '')
                    + (f' in round {round_number}' if round_number else '')
                    + '.'
                )
                return

        foursomes = foursomes.select_related('round__tournament').order_by(
            'round__round_number', 'group_number'
        )

        for fs in foursomes:
            self._inspect_foursome(fs, apply=apply, raw_pairs=raw_pairs)

    # ── Per-foursome logic ──────────────────────────────────────────────────

    def _inspect_foursome(self, foursome, apply, raw_pairs):
        from games.models import MatchPlayBracket
        from tournament.models import FoursomeMembership

        round_obj = foursome.round
        tournament_name = getattr(
            getattr(round_obj, 'tournament', None), 'name', '?'
        )
        round_num = getattr(round_obj, 'round_number', '?')

        self.stdout.write(
            self.style.MIGRATE_HEADING(
                f'\n=== Foursome {foursome.id} | '
                f'{tournament_name} — Round {round_num} '
                f'(Group {foursome.group_number}) ==='
            )
        )

        # Real players in this foursome
        members = list(
            FoursomeMembership.objects
            .filter(foursome=foursome, player__is_phantom=False)
            .select_related('player')
        )
        self.stdout.write(
            'Players: ' + ', '.join(
                f'{m.player.name} (id={m.player_id}, hcp={m.playing_handicap})'
                for m in members
            )
        )
        self.stdout.write(f'active_games: {foursome.active_games}')

        # Current bracket
        try:
            bracket = (
                MatchPlayBracket.objects
                .prefetch_related(
                    'matches__player1',
                    'matches__player2',
                    'matches__hole_results',
                )
                .get(foursome=foursome, bracket_type='cup_singles')
            )
        except MatchPlayBracket.DoesNotExist:
            self.stdout.write(self.style.WARNING('  No cup_singles bracket found.'))
            return

        matches = list(bracket.matches.all())
        self.stdout.write(
            f'Bracket id={bracket.id}  status={bracket.status}  '
            f'matches={len(matches)}'
        )

        for m in matches:
            holes_played = m.hole_results.count()
            hcp1 = self._get_hcp(foursome, m.player1_id)
            hcp2 = self._get_hcp(foursome, m.player2_id)
            try:
                diff_p1 = max(0, int(hcp1) - int(hcp2))
                diff_p2 = max(0, int(hcp2) - int(hcp1))
                stroke_str = (
                    f'{m.player1.short_name} gets {diff_p1} strokes, '
                    f'{m.player2.short_name} gets {diff_p2} strokes'
                )
            except (TypeError, ValueError):
                stroke_str = 'handicap unknown'

            self.stdout.write(
                f'  Match {m.id}: {m.player1.name}(hcp {hcp1}) vs '
                f'{m.player2.name}(hcp {hcp2})  '
                f'→ {stroke_str}  '
                f'holes={holes_played}  result={m.result or "pending"}'
            )

        # Flag players not appearing in any match
        player_ids_in_matches = set()
        for m in matches:
            player_ids_in_matches.add(m.player1_id)
            player_ids_in_matches.add(m.player2_id)
        missing = [
            m.player for m in members
            if m.player_id not in player_ids_in_matches
        ]
        if missing:
            self.stdout.write(
                self.style.WARNING(
                    '  ⚠  Players NOT in any match: '
                    + ', '.join(f'{p.name}(id={p.id})' for p in missing)
                )
            )

        # Flag solo players appearing in multiple matches (expected for 1v2)
        from collections import Counter
        all_player_match_counts = Counter()
        for m in matches:
            all_player_match_counts[m.player1_id] += 1
            all_player_match_counts[m.player2_id] += 1
        for pid, cnt in all_player_match_counts.items():
            if cnt > 1:
                name = next(
                    (m.player.name for m in members if m.player_id == pid),
                    str(pid),
                )
                self.stdout.write(
                    f'  ℹ  {name}(id={pid}) plays {cnt} matches (1v2 solo player).'
                )

        # Flag duplicate opponent pairings (both matches vs same person)
        p2_ids = [m.player2_id for m in matches]
        p1_ids = [m.player1_id for m in matches]
        if len(set(p2_ids)) < len(p2_ids):
            self.stdout.write(
                self.style.WARNING(
                    '  ⚠  Duplicate player2 across matches — both matches '
                    'may be against the same opponent (wrong strokes bug).'
                )
            )
        if len(set(p1_ids)) < len(p1_ids) and len(matches) > 1:
            # Multiple matches with same player1 is expected in 1v2
            pass

        # ── Apply fix if requested ──────────────────────────────────────────
        if not apply:
            if raw_pairs:
                self.stdout.write(
                    '  (dry-run) Would re-create bracket with pairs: '
                    + str(raw_pairs)
                )
            return

        if not raw_pairs:
            self.stdout.write(
                self.style.ERROR(
                    '  --apply requires --pair arguments. '
                    'Example: --pair "7:3" --pair "7:11"'
                )
            )
            return

        # Parse pairs
        explicit_matchups = []
        for raw in raw_pairs:
            try:
                a, b = raw.split(':')
                explicit_matchups.append({
                    'player1_id': int(a.strip()),
                    'player2_id': int(b.strip()),
                })
            except ValueError:
                raise CommandError(
                    f'Invalid --pair format "{raw}". Expected "P1_ID:P2_ID".'
                )

        self.stdout.write(
            f'  Re-creating bracket with {len(explicit_matchups)} explicit pairs…'
        )

        with transaction.atomic():
            from services.cup_singles import setup_cup_singles, calculate_cup_singles
            setup_cup_singles(
                foursome, None, None,
                singles_matchups=explicit_matchups,
            )
            calculate_cup_singles(foursome)

            # Show new results
            bracket_new = (
                MatchPlayBracket.objects
                .prefetch_related(
                    'matches__player1', 'matches__player2', 'matches__hole_results'
                )
                .get(foursome=foursome, bracket_type='cup_singles')
            )
            self.stdout.write(
                self.style.SUCCESS(
                    f'  ✓ Bracket re-created: id={bracket_new.id}  '
                    f'status={bracket_new.status}  '
                    f'matches={bracket_new.matches.count()}'
                )
            )
            for m in bracket_new.matches.all():
                holes_played = m.hole_results.count()
                hcp1 = self._get_hcp(foursome, m.player1_id)
                hcp2 = self._get_hcp(foursome, m.player2_id)
                try:
                    diff_p1 = max(0, int(hcp1) - int(hcp2))
                    diff_p2 = max(0, int(hcp2) - int(hcp1))
                    stroke_str = (
                        f'{m.player1.short_name} gets {diff_p1} strokes, '
                        f'{m.player2.short_name} gets {diff_p2} strokes'
                    )
                except (TypeError, ValueError):
                    stroke_str = 'handicap unknown'
                self.stdout.write(
                    self.style.SUCCESS(
                        f'    Match {m.id}: {m.player1.name}(hcp {hcp1}) vs '
                        f'{m.player2.name}(hcp {hcp2})  → {stroke_str}  '
                        f'holes={holes_played}  result={m.result or "pending"}'
                    )
                )

        # Rebuild Ryder Cup points
        self.stdout.write('  Refreshing Ryder Cup standings…')
        try:
            from services.ryder_cup import calculate_ryder_cup_points
            calculate_ryder_cup_points(foursome.round)
            self.stdout.write(self.style.SUCCESS('  ✓ Cup standings updated.'))
        except Exception as exc:
            self.stdout.write(
                self.style.WARNING(f'  Cup standings update skipped: {exc}')
            )

    def _get_hcp(self, foursome, player_id):
        from tournament.models import FoursomeMembership
        try:
            m = FoursomeMembership.objects.get(
                foursome=foursome, player_id=player_id
            )
            return m.playing_handicap
        except FoursomeMembership.DoesNotExist:
            return '?'
