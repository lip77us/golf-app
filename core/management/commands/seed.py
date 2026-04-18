from django.core.management.base import BaseCommand
from django.contrib.auth import get_user_model
from django.db import transaction
from core.models import Course, Tee, Player

User = get_user_model()

class Command(BaseCommand):
    help = 'Seeds the database with initial dummy data (Courses, Tees, Players, and Superuser).'

    def handle(self, *args, **options):
        self.stdout.write(self.style.WARNING("Starting database seeder..."))

        with transaction.atomic():
            self._create_superuser()
            self._create_courses_and_tees()
            self._create_players()

        self.stdout.write(self.style.SUCCESS("Database seeded successfully!"))

    def _create_superuser(self):
        username = 'admin'
        email = 'admin@example.com'
        password = 'admin'

        if User.objects.filter(username=username).exists():
            self.stdout.write(f"Superuser '{username}' already exists.")
        else:
            User.objects.create_superuser(username=username, email=email, password=password)
            self.stdout.write(self.style.SUCCESS(f"Created superuser '{username}' (password: '{password}')."))

    def _create_courses_and_tees(self):
        # Prevent duplicate seeding if courses exist
        if Course.objects.exists():
            self.stdout.write("Courses already exist. Skipping course/tee creation.")
            return

        # Generic 18 hole layouts
        holes_par_72 = []
        for i in range(1, 19):
            holes_par_72.append({
                "number": i,
                "par": 4 if i not in [3, 8, 12, 16] else 3 if i in [3, 12] else 5,
                "stroke_index": i,
                "yards": 400
            })

        course1 = Course.objects.create(name="Pebble Beach Golf Links")
        course2 = Course.objects.create(name="Augusta National")

        # Pebble Beach Tees
        Tee.objects.create(
            course=course1, tee_name="Blue", slope=144, course_rating=75.4, par=72, holes=holes_par_72
        )
        Tee.objects.create(
            course=course1, tee_name="White", slope=132, course_rating=72.1, par=72, holes=holes_par_72
        )

        # Augusta National Tees
        Tee.objects.create(
            course=course2, tee_name="Masters", slope=148, course_rating=78.1, par=72, holes=holes_par_72
        )
        Tee.objects.create(
            course=course2, tee_name="Members", slope=137, course_rating=74.2, par=72, holes=holes_par_72
        )

        self.stdout.write(self.style.SUCCESS("Created 2 courses with 2 tees each."))

    def _create_players(self):
        if Player.objects.filter(is_phantom=False).exists():
            self.stdout.write("Players already exist. Skipping player creation.")
            return

        # Let's link the first player to the superuser
        admin_user = User.objects.get(username='admin')

        Player.objects.create(
            user=admin_user, name="Paul (Admin)", email="paul@example.com", handicap_index=12.4
        )
        Player.objects.create(
            user=None, name="Tiger Woods", email="tiger@example.com", handicap_index=-5.0
        )
        Player.objects.create(
            user=None, name="Rory McIlroy", email="rory@example.com", handicap_index=-3.2
        )
        Player.objects.create(
            user=None, name="Weekend Hacker", email="hacker@example.com", handicap_index=24.5
        )

        self.stdout.write(self.style.SUCCESS("Created 4 players (1 linked to admin user)."))
