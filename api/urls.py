"""
api/urls.py
-----------
URL patterns for the Golf App REST API.
All routes are mounted under /api/ in the project urls.py.
"""

from django.urls import path
from . import views

urlpatterns = [
    # ---- Auth ----
    path('auth/login/',   views.LoginView.as_view(),  name='api-login'),
    path('auth/logout/',  views.LogoutView.as_view(), name='api-logout'),
    path('auth/me/',      views.MeView.as_view(),     name='api-me'),

    # ---- Reference data ----
    path('players/',           views.PlayerListView.as_view(),   name='api-players'),
    path('players/<int:pk>/',  views.PlayerDetailView.as_view(), name='api-player-detail'),
    path('courses/',           views.CourseListView.as_view(),   name='api-courses'),
    path('tees/',              views.TeeListView.as_view(),      name='api-tees'),

    # ---- Tournaments ----
    path('tournaments/',                              views.TournamentListView.as_view(),        name='api-tournament-list'),
    path('tournaments/<int:pk>/',                     views.TournamentDetailView.as_view(),      name='api-tournament-detail'),
    path('tournaments/<int:pk>/leaderboard/',         views.TournamentLeaderboardView.as_view(), name='api-tournament-leaderboard'),
    path('tournaments/<int:pk>/low-net/',             views.TournamentLowNetView.as_view(),      name='api-tournament-low-net'),
    path('tournaments/<int:pk>/low-net/setup/',       views.TournamentLowNetSetupView.as_view(), name='api-tournament-low-net-setup'),

    # ---- Rounds ----
    path('rounds/',                      views.RoundCreateView.as_view(),     name='api-round-create'),
    path('rounds/casual/',               views.CasualRoundListView.as_view(), name='api-casual-rounds'),
    path('rounds/<int:pk>/',             views.RoundDetailView.as_view(),     name='api-round-detail'),
    path('rounds/<int:pk>/setup/',       views.RoundSetupView.as_view(),    name='api-round-setup'),
    path('rounds/<int:pk>/complete/',    views.RoundCompleteView.as_view(), name='api-round-complete'),
    path('rounds/<int:pk>/leaderboard/', views.LeaderboardView.as_view(),   name='api-leaderboard'),

    # ---- Foursomes ----
    path('foursomes/<int:pk>/',              views.FoursomeDetailView.as_view(),      name='api-foursome-detail'),
    path('foursomes/<int:pk>/active-games/', views.FoursomeActiveGamesView.as_view(), name='api-foursome-active-games'),
    path('foursomes/<int:pk>/phantom/init/', views.PhantomInitView.as_view(),         name='phantom-init'),
    path('foursomes/<int:pk>/scorecard/',    views.ScorecardView.as_view(),           name='api-scorecard'),
    path('foursomes/<int:pk>/scores/',       views.ScoreSubmitView.as_view(),         name='api-score-submit'),

    # ---- Nassau ----
    path('foursomes/<int:pk>/nassau/',        views.NassauResultView.as_view(), name='api-nassau-result'),
    path('foursomes/<int:pk>/nassau/setup/',  views.NassauSetupView.as_view(),  name='api-nassau-setup'),
    path('foursomes/<int:pk>/nassau/press/',  views.NassauPressView.as_view(),  name='api-nassau-press'),

    # ---- Six's ----
    path('foursomes/<int:pk>/sixes/',              views.SixesResultView.as_view(),     name='api-sixes-result'),
    path('foursomes/<int:pk>/sixes/setup/',        views.SixesSetupView.as_view(),      name='api-sixes-setup'),
    path('foursomes/<int:pk>/sixes/extra-teams/',  views.SixesExtraTeamsView.as_view(), name='api-sixes-extra-teams'),

    # ---- Points 5-3-1 ----
    path('foursomes/<int:pk>/points_531/',       views.Points531ResultView.as_view(), name='api-points-531-result'),
    path('foursomes/<int:pk>/points_531/setup/', views.Points531SetupView.as_view(),  name='api-points-531-setup'),

    # ---- Skins ----
    path('foursomes/<int:pk>/skins/',        views.SkinsResultView.as_view(), name='api-skins-result'),
    path('foursomes/<int:pk>/skins/setup/',  views.SkinsSetupView.as_view(),  name='api-skins-setup'),
    path('foursomes/<int:pk>/skins/junk/',   views.SkinsJunkView.as_view(),   name='api-skins-junk'),

    # ---- Match Play ----
    path('foursomes/<int:pk>/match-play/',        views.MatchPlayResultView.as_view(), name='api-match-play-result'),
    path('foursomes/<int:pk>/match-play/setup/',  views.MatchPlaySetupView.as_view(),  name='api-match-play-setup'),

    # ---- Three-Person Match ----
    path('foursomes/<int:pk>/three-person-match/',        views.ThreePersonMatchResultView.as_view(), name='api-three-person-match-result'),
    path('foursomes/<int:pk>/three-person-match/setup/',  views.ThreePersonMatchSetupView.as_view(),  name='api-three-person-match-setup'),

    # ---- Irish Rumble setup (round-level) ----
    path('rounds/<int:pk>/irish-rumble/setup/', views.IrishRumbleSetupView.as_view(), name='api-irish-rumble-setup'),

    # ---- Low Net setup (round-level) ----
    path('rounds/<int:pk>/low-net/setup/', views.LowNetSetupView.as_view(), name='api-low-net-setup'),

    # ---- Pink Ball setup (round-level) + per-foursome order ----
    path('rounds/<int:pk>/pink-ball/setup/',      views.PinkBallSetupView.as_view(),          name='api-pink-ball-setup'),
    path('foursomes/<int:pk>/pink-ball/order/',   views.PinkBallFoursomeOrderView.as_view(),  name='api-pink-ball-order'),

    # ---- Health check ----
    path('health/', views.health_check, name='api-health'),

    # ---- Course import from GolfCourseAPI ----
    path('courses/golf-api/search/',                   views.GolfApiSearchView.as_view(),        name='api-golf-api-search'),
    path('courses/golf-api/courses/<int:course_id>/',  views.GolfApiCourseDetailView.as_view(),  name='api-golf-api-course-detail'),
    path('courses/import/',                            views.CourseImportView.as_view(),          name='api-course-import'),
]
