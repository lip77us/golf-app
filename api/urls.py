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
    path('players/',      views.PlayerListView.as_view(), name='api-players'),
    path('tees/',         views.TeeListView.as_view(),    name='api-tees'),

    # ---- Tournaments ----
    path('tournaments/',        views.TournamentListView.as_view(),   name='api-tournament-list'),
    path('tournaments/<int:pk>/', views.TournamentDetailView.as_view(), name='api-tournament-detail'),

    # ---- Rounds ----
    path('rounds/<int:pk>/',         views.RoundDetailView.as_view(),  name='api-round-detail'),
    path('rounds/<int:pk>/setup/',   views.RoundSetupView.as_view(),   name='api-round-setup'),
    path('rounds/<int:pk>/leaderboard/', views.LeaderboardView.as_view(), name='api-leaderboard'),

    # ---- Foursomes ----
    path('foursomes/<int:pk>/',             views.FoursomeDetailView.as_view(), name='api-foursome-detail'),
    path('foursomes/<int:pk>/scorecard/',   views.ScorecardView.as_view(),      name='api-scorecard'),
    path('foursomes/<int:pk>/scores/',      views.ScoreSubmitView.as_view(),    name='api-score-submit'),

    # ---- Nassau ----
    path('foursomes/<int:pk>/nassau/',        views.NassauResultView.as_view(), name='api-nassau-result'),
    path('foursomes/<int:pk>/nassau/setup/',  views.NassauSetupView.as_view(),  name='api-nassau-setup'),

    # ---- Six's ----
    path('foursomes/<int:pk>/sixes/',        views.SixesResultView.as_view(), name='api-sixes-result'),
    path('foursomes/<int:pk>/sixes/setup/',  views.SixesSetupView.as_view(),  name='api-sixes-setup'),

    # ---- Match Play ----
    path('foursomes/<int:pk>/match-play/',   views.MatchPlayResultView.as_view(), name='api-match-play-result'),
]
