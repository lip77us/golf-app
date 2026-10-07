"""
management command: clear_round_scores
--------------------------------------
Put a round back to its pre-play state WITHOUT touching its setup.

Built for the night before a tournament: post some scores, check the board
gives the answers you expect, then wipe them and hand the group a clean card
in the morning. The draw, the groups, the tee times, the teams and every game
setting survive — only what was SCORED goes.

Dry run by default, like `import_genius_roster` and `seed_demo`; pass
`--apply` to commit. Everything happens in one transaction.

Usage
-----
    python manage.py clear_round_scores --round 417
    python manage.py clear_round_scores --tournament TPSGC
    python manage.py clear_round_scores --round 417 --apply

What it clears
~~~~~~~~~~~~~~
* Every `HoleScore` on the round's foursomes, phantoms included — a donor
  phantom's borrowed scores are scores.
* Mid-round withdrawal marks (`withdrew_after_hole`,
  `withdrew_killed_next_hole`), so a golfer tested as a WD is playing again.
* Derived results, by RE-RUNNING the calculators rather than deleting rows by
  hand. `calculate_triple_cup` and `calculate_ryder_cup_points` both wipe and
  rebuild from the scores, so with no scores left they rebuild to nothing.
  That matters: hand-deleting would mean naming every per-game result table
  here and silently missing the next one added.
* The round's status, back to in_progress.

What it does NOT touch
~~~~~~~~~~~~~~~~~~~~~~
Foursomes, memberships, tees, handicaps, teams, tee times, match plans or
game configuration. If you want those gone, you want a different command.
"""
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction


class Command(BaseCommand):
    help = "Delete a round's scores, keeping its setup intact."

    def add_arguments(self, parser):
        parser.add_argument('--round', type=int, dest='round_id',
                            help='Round id to clear.')
        parser.add_argument('--tournament', dest='tournament',
                            help='Clear every round of tournaments whose name '
                                 'contains this (case-insensitive).')
        parser.add_argument('--apply', action='store_true', default=False,
                            help='Commit. Without it this is a dry run.')

    def handle(self, *args, **o):
        from scoring.models import HoleScore
        from tournament.models import FoursomeMembership, Round, RoundStatus

        if not o['round_id'] and not o['tournament']:
            raise CommandError('Give --round <id> or --tournament <name>.')

        rounds = (Round.objects.filter(pk=o['round_id']) if o['round_id']
                  else Round.objects.filter(
                      tournament__name__icontains=o['tournament']))
        rounds = list(rounds.select_related('tournament'))
        if not rounds:
            raise CommandError('No matching round.')

        apply = o['apply']
        head = 'CLEARING' if apply else 'DRY RUN — nothing will change'
        self.stdout.write(self.style.WARNING(head))

        with transaction.atomic():
            for r in rounds:
                fs_ids = list(r.foursomes.values_list('id', flat=True))
                scores = HoleScore.objects.filter(foursome_id__in=fs_ids)
                n_scores = scores.count()
                wds = FoursomeMembership.objects.filter(
                    foursome_id__in=fs_ids, withdrew_after_hole__isnull=False)
                n_wd = wds.count()
                label = r.tournament.name if r.tournament else 'casual'
                self.stdout.write(
                    f'  round {r.id} "{label}" — {len(fs_ids)} groups, '
                    f'{n_scores} scores, {n_wd} withdrawals, '
                    f'status={r.status}')
                if not apply:
                    continue

                scores.delete()
                wds.update(withdrew_after_hole=None,
                           withdrew_killed_next_hole=False)
                if r.status != RoundStatus.IN_PROGRESS:
                    r.status = RoundStatus.IN_PROGRESS
                    r.save(update_fields=['status'])

                # Rebuild derived results from the (now empty) scores.
                for fs in r.foursomes.all():
                    if getattr(fs, 'triple_cup_game', None) is not None:
                        from services.triple_cup import calculate_triple_cup
                        calculate_triple_cup(fs)
                if getattr(r, 'ryder_cup_config', None) is not None:
                    from services.ryder_cup import calculate_ryder_cup_points
                    calculate_ryder_cup_points(r)

                left = HoleScore.objects.filter(
                    foursome_id__in=fs_ids).count()
                self.stdout.write(self.style.SUCCESS(
                    f'    cleared — {left} scores remain, status={r.status}'))

            if not apply:
                self.stdout.write(
                    'Re-run with --apply to commit.')
