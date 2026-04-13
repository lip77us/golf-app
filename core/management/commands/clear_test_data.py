"""
management command: clear_test_data
--------------------------------------
Removes all test objects created by seed_test_data.

Identifies test data by the "Test_" prefix on Player names and
Tournament names.  Safe to run even if seed_test_data was never run.

Usage
-----
    python manage.py clear_test_data
    python manage.py clear_test_data --yes   # skip the confirmation prompt
"""

from django.core.management.base import BaseCommand

from core.models import Player, Tee
from tournament.models import Tournament, Round, Foursome


class Command(BaseCommand):
    help = "Remove all test data created by seed_test_data."

    def add_arguments(self, parser):
        parser.add_argument(
            '--yes',
            action='store_true',
            default=False,
            help='Skip the confirmation prompt.',
        )

    def handle(self, *args, **options):
        # Summarise what will be deleted
        test_tournaments = Tournament.objects.filter(name__startswith='Test_')
        test_rounds      = Round.objects.filter(tournament__in=test_tournaments)
        test_players     = Player.objects.filter(name__startswith='Test_')
        test_tees        = Tee.objects.filter(course_name='Cypress Ridge')

        self.stdout.write("The following test data will be removed:")
        self.stdout.write(f"  Tournaments : {test_tournaments.count()}")
        self.stdout.write(f"  Rounds      : {test_rounds.count()}")
        self.stdout.write(
            f"  Foursomes   : {Foursome.objects.filter(round__in=test_rounds).count()} "
            f"(+ all scores, game results)"
        )
        self.stdout.write(f"  Players     : {test_players.count()} (+ Django users)")
        self.stdout.write(f"  Tees        : {test_tees.count()}")

        if not options['yes']:
            confirm = input("\nProceed? [y/N] ").strip().lower()
            if confirm not in ('y', 'yes'):
                self.stdout.write("Aborted.")
                return

        from django.contrib.auth import get_user_model
        User = get_user_model()

        # Delete in dependency order.
        # Foursomes cascade: FoursomeMembership, HoleScore, SkinsResult,
        #                    NassauGame, SixesSegment, PinkBallResult, etc.
        Foursome.objects.filter(round__in=test_rounds).delete()
        test_rounds.delete()
        test_tournaments.delete()

        # Players + linked Django users (which also cascade to auth_token)
        user_pks = list(
            test_players.exclude(user=None).values_list('user_id', flat=True)
        )
        test_players.delete()
        if user_pks:
            User.objects.filter(pk__in=user_pks).delete()

        test_tees.delete()

        self.stdout.write(self.style.SUCCESS("Test data cleared."))
