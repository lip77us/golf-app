from django.core.management.base import BaseCommand
from django.contrib.auth import get_user_model
from django.db import transaction
from core.models import Course, Tee, Player

User = get_user_model()

class Command(BaseCommand):
    help = 'Seeds the database with initial dummy data (Tilden Park, Tees, and some Players). Can be rurun'

    def handle(self, *args, **options):
        self.stdout.write(self.style.WARNING("Starting database Tilden seeder..."))

        with transaction.atomic():
            self._create_courses_and_tees()
           # self._create_players()

        self.stdout.write(self.style.SUCCESS("Database seeded successfully!"))

    def _create_courses_and_tees(self):

        # Generic 18 hole layouts
        tilden_white = [
            [1, 4, 1, 404],
            [2, 4,  4, 385],
            [3, 4,  12, 377],
            [4, 3, 15, 137],
            [5, 4,  2, 327],
            [6, 4, 16, 297],
            [7, 3,  13, 201],
            [8, 5, 9, 467],
            [9, 4,  10, 320],
            [10, 4,  5, 387],
            [11, 3, 7, 199],
            [12, 4,  8, 300],
            [13, 5, 18, 438],
            [14, 4,  14, 311],
            [15, 4, 17, 322],
            [16, 3,  11, 186],
            [17, 4, 3, 395],
            [18, 4, 6, 370],
        ]

        tilden_red_m = [
        
            [1, 4, 1, 401],
            [2, 4,  11, 376],
            [3, 4,  15, 356],
            [4, 3, 9, 123],
            [5, 4,  5, 316],
            [6, 4, 17, 270],
            [7, 3,  13, 170],
            [8, 5, 3, 460],
            [9, 4,  7, 286],
            [10, 4,  4, 381],
            [11, 3, 18, 120],
            [12, 4,  6, 264],
            [13, 5, 2, 431],
            [14, 4,  14, 284],
            [15, 4, 12, 309],
            [16, 3,  16, 138],
            [17, 4, 8, 379],
            [18, 4, 10, 335],
        ]

        tilden_red_w = [    
          
            [1, 5, 3, 401],
            [2, 4,  11, 376],
            [3, 4,  15, 356],
            [4, 3, 9, 123],
            [5, 4,  5, 316],
            [6, 4, 17, 270],
            [7, 3,  13, 170],
            [8, 5, 1, 460],
            [9, 4,  7, 286],
            [10, 4,  4, 381],
            [11, 3, 18, 120],
            [12, 4,  6, 264],
            [13, 5, 2, 431],
            [14, 4,  14, 284],
            [15, 4, 12, 309],
            [16, 3,  16, 138],
            [17, 4, 8, 379],
            [18, 4, 10, 335],
        ]
        tilden_white_holes_m = []
        tilden_red_holes_m = []
        tilden_red_holes_w = []

        def _get_or_create_white_tee(g_course) -> Tee:
                tee, created = Tee.objects.get_or_create(
                    course=g_course,
                    tee_name='White',
                    defaults={
                        'slope'        : 124,
                        'course_rating': '69.5',
                        'par'          : 70,
                        'holes'        : tilden_white_holes_m,
                        'sex'          : 'M',
                        'sort_priority': 10,   # default men's tee at this course
                    },
                )
                status = "Created" if created else "Found"
                self.stdout.write(f"  {status} tee: {tee}")
                return tee

        def _get_or_create_red_m_tee(g_course) -> Tee:
                tee, created = Tee.objects.get_or_create(
                    course=     g_course,
                    tee_name='Red M',
                    defaults={
                        'slope'        : 120,
                        'course_rating': '67.8',
                        'par'          : 70,
                        'holes'        : tilden_red_holes_m,
                        'sex'          : 'M',
                        'sort_priority': 40,   # forward men's tee — behind White
                    },
                )
                status = "Created" if created else "Found"
                self.stdout.write(f"  {status} tee: {tee}")
                return tee

        def _get_or_create_red_w_tee(g_course) -> Tee:
                tee, created = Tee.objects.get_or_create(
                    course=g_course,
                    tee_name='Red W',
                    defaults={
                        'slope'        : 124,
                        'course_rating': '71.6',
                        'par'          : 71,
                        'holes'        : tilden_red_holes_w,
                        'sex'          : 'W',
                        'sort_priority': 10,   # default women's tee at this course
                    },
                )
                status = "Created" if created else "Found"
                self.stdout.write(f"  {status} tee: {tee}")
                return tee



        for i in range(1, 19):
            tilden_white_holes_m.append({
                "number": i,
                "par": tilden_white[i-1][1],
                "stroke_index": tilden_white[i-1][2],
                "yards": tilden_white[i-1][3]
            })
            tilden_red_holes_m.append({
                "number": i,
                "par": tilden_red_m[i-1][1],
                "stroke_index": tilden_red_m[i-1][2],
                "yards": tilden_red_m[i-1][3]
            })
            tilden_red_holes_w.append({
                "number": i,
                "par": tilden_red_w[i-1][1],
                "stroke_index": tilden_red_w[i-1][2],
                "yards": tilden_red_w[i-1][3]
            })

        tilden, status = Course.objects.get_or_create(name="Tilden Park")
        print(f"Tilden Park Created: {tilden}")
      
        _get_or_create_white_tee(tilden)
        _get_or_create_red_m_tee(tilden)
        _get_or_create_red_w_tee(tilden)
   

        
        self.stdout.write(self.style.SUCCESS("Created Tilden Park with 3 tees."))

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
