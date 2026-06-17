"""
api/urls.py
-----------
URL patterns for the Golf App REST API.
All routes are mounted under /api/ in the project urls.py.
"""

from django.urls import include, path
from . import views

urlpatterns = [
    # ---- Auth ----
    path('auth/login/',          views.LoginView.as_view(),         name='api-login'),
    path('auth/otp/request/',    views.OtpRequestView.as_view(),    name='api-otp-request'),
    path('auth/otp/verify/',     views.OtpVerifyView.as_view(),     name='api-otp-verify'),
    path('auth/logout/',         views.LogoutView.as_view(),        name='api-logout'),
    path('invite/',              views.InviteView.as_view(),        name='api-invite'),
    path('auth/me/',             views.MeView.as_view(),            name='api-me'),
    path('auth/delete-account/', views.DeleteAccountView.as_view(), name='api-delete-account'),

    # ---- Account-member management ----
    path('account/', include('accounts.urls')),

    # ---- Reference data ----
    path('players/',           views.PlayerListView.as_view(),   name='api-players'),
    path('halved-users/lookup/', views.HalvedUserLookupView.as_view(), name='api-halved-user-lookup'),
    path('devices/register/',    views.DeviceRegisterView.as_view(),   name='api-device-register'),
    path('devices/unregister/',  views.DeviceUnregisterView.as_view(), name='api-device-unregister'),
    path('notification-prefs/',  views.NotificationPrefsView.as_view(), name='api-notification-prefs'),
    path('players/<int:pk>/',  views.PlayerDetailView.as_view(), name='api-player-detail'),
    path('courses/',           views.CourseListView.as_view(),   name='api-courses'),
    path('courses/<int:pk>/',  views.CourseDetailView.as_view(), name='api-course-detail'),
    path('tees/',              views.TeeListView.as_view(),      name='api-tees'),
    path('tees/<int:pk>/',     views.TeeDetailView.as_view(),    name='api-tee-detail'),

    # ---- Tournaments ----
    path('tournaments/',                              views.TournamentListView.as_view(),        name='api-tournament-list'),
    path('tournaments/<int:pk>/',                     views.TournamentDetailView.as_view(),      name='api-tournament-detail'),
    path('tournaments/<int:pk>/leaderboard/',         views.TournamentLeaderboardView.as_view(),   name='api-tournament-leaderboard'),
    path('tournaments/<int:pk>/watchers/',            views.TournamentWatcherView.as_view(),       name='api-tournament-watchers'),
    path('tournaments/<int:pk>/watcher-candidates/',  views.TournamentWatcherCandidatesView.as_view(), name='api-tournament-watcher-candidates'),
    path('tournaments/<int:pk>/cup-standings/',       views.TournamentCupStandingsView.as_view(), name='api-tournament-cup-standings'),
    path('tournaments/<int:pk>/low-net/',             views.TournamentLowNetView.as_view(),       name='api-tournament-low-net'),
    path('tournaments/<int:pk>/low-net/setup/',       views.TournamentLowNetSetupView.as_view(), name='api-tournament-low-net-setup'),
    path('tournaments/<int:pk>/stableford/',          views.TournamentStablefordView.as_view(),      name='api-tournament-stableford'),
    path('tournaments/<int:pk>/stableford/setup/',    views.TournamentStablefordSetupView.as_view(), name='api-tournament-stableford-setup'),

    # ---- Rounds ----
    path('rounds/',                      views.RoundCreateView.as_view(),     name='api-round-create'),
    path('rounds/casual/',               views.CasualRoundListView.as_view(), name='api-casual-rounds'),
    path('rounds/shared-with-me/',       views.SharedRoundsView.as_view(),    name='api-shared-rounds'),
    path('rounds/scoring-for-me/',       views.ScoringForMeView.as_view(),    name='api-scoring-for-me'),
    path('rounds/playing-for-me/',       views.PlayingRoundsView.as_view(),   name='api-playing-for-me'),
    path('support/round/',               views.SupportRoundLookupView.as_view(), name='api-support-round'),
    path('rounds/<int:pk>/',             views.RoundDetailView.as_view(),     name='api-round-detail'),
    path('rounds/<int:pk>/join/',        views.RoundJoinView.as_view(),       name='api-round-join'),
    path('tournaments/<int:pk>/join/',   views.TournamentJoinView.as_view(),  name='api-tournament-join'),
    path('rounds/<int:pk>/setup/',       views.RoundSetupView.as_view(),    name='api-round-setup'),
    path('rounds/<int:pk>/complete/',    views.RoundCompleteView.as_view(), name='api-round-complete'),
    path('rounds/<int:pk>/reopen/',      views.RoundReopenView.as_view(),   name='api-round-reopen'),
    path('rounds/<int:pk>/move-player/', views.RoundMovePlayerView.as_view(),
         name='api-round-move-player'),
    path('rounds/<int:pk>/leaderboard/', views.LeaderboardView.as_view(),   name='api-leaderboard'),
    path('rounds/<int:pk>/messages/',      views.RoundMessagesView.as_view(),     name='api-round-messages'),
    path('rounds/<int:pk>/messages/read/', views.RoundMessagesReadView.as_view(), name='api-round-messages-read'),
    path('rounds/<int:pk>/watchers/',    views.RoundWatcherView.as_view(),  name='api-round-watchers'),
    path('rounds/<int:pk>/watcher-candidates/', views.RoundWatcherCandidatesView.as_view(), name='api-round-watcher-candidates'),

    # ---- Foursomes ----
    path('foursomes/<int:pk>/',              views.FoursomeDetailView.as_view(),      name='api-foursome-detail'),
    path('foursomes/<int:pk>/active-games/', views.FoursomeActiveGamesView.as_view(), name='api-foursome-active-games'),
    path('foursomes/<int:pk>/tees/',         views.FoursomeTeesView.as_view(),        name='api-foursome-tees'),
    path('foursomes/<int:pk>/remove-player/', views.FoursomeRemovePlayerView.as_view(),
         name='api-foursome-remove-player'),
    path('foursomes/<int:pk>/withdraw-player/', views.WithdrawPlayerView.as_view(),
         name='api-foursome-withdraw-player'),
    path('foursomes/<int:pk>/reinstate-player/', views.ReinstatePlayerView.as_view(),
         name='api-foursome-reinstate-player'),
    path('foursomes/<int:pk>/swap-position/', views.FoursomeSwapPositionView.as_view(),
         name='api-foursome-swap-position'),
    path('foursomes/<int:pk>/phantom/init/', views.PhantomInitView.as_view(),         name='phantom-init'),
    path('foursomes/<int:pk>/scorecard/',    views.ScorecardView.as_view(),           name='api-scorecard'),
    path('foursomes/<int:pk>/scorer/',       views.ScorerDesignateView.as_view(),     name='api-foursome-scorer'),
    path('foursomes/<int:pk>/scores/',       views.ScoreSubmitView.as_view(),         name='api-score-submit'),

    # ---- Nassau ----
    path('foursomes/<int:pk>/nassau/',        views.NassauResultView.as_view(), name='api-nassau-result'),
    path('foursomes/<int:pk>/nassau/setup/',  views.NassauSetupView.as_view(),  name='api-nassau-setup'),
    path('foursomes/<int:pk>/nassau/press/',  views.NassauPressView.as_view(),  name='api-nassau-press'),

    # ---- Sixes ----
    path('foursomes/<int:pk>/sixes/',              views.SixesResultView.as_view(),     name='api-sixes-result'),
    path('foursomes/<int:pk>/sixes/setup/',        views.SixesSetupView.as_view(),      name='api-sixes-setup'),
    path('foursomes/<int:pk>/sixes/extra-teams/',  views.SixesExtraTeamsView.as_view(), name='api-sixes-extra-teams'),

    # ---- Points 5-3-1 ----
    path('foursomes/<int:pk>/points_531/',       views.Points531ResultView.as_view(), name='api-points-531-result'),
    path('foursomes/<int:pk>/points_531/setup/', views.Points531SetupView.as_view(),  name='api-points-531-setup'),

    # ---- Las Vegas ----
    path('foursomes/<int:pk>/vegas/',            views.VegasResultView.as_view(),     name='api-vegas-result'),
    path('foursomes/<int:pk>/vegas/setup/',      views.VegasSetupView.as_view(),      name='api-vegas-setup'),

    # ---- Skins ----
    path('foursomes/<int:pk>/skins/',        views.SkinsResultView.as_view(), name='api-skins-result'),
    path('foursomes/<int:pk>/skins/setup/',  views.SkinsSetupView.as_view(),  name='api-skins-setup'),
    path('foursomes/<int:pk>/skins/junk/',   views.SkinsJunkView.as_view(),   name='api-skins-junk'),

    # ---- Wolf ----
    path('foursomes/<int:pk>/wolf/',          views.WolfResultView.as_view(),   name='api-wolf-result'),
    path('foursomes/<int:pk>/wolf/setup/',    views.WolfSetupView.as_view(),    name='api-wolf-setup'),
    path('foursomes/<int:pk>/wolf/order/',    views.WolfOrderView.as_view(),    name='api-wolf-order'),
    path('foursomes/<int:pk>/wolf/decision/', views.WolfDecisionView.as_view(), name='api-wolf-decision'),

    # ---- Rabbit ----
    path('foursomes/<int:pk>/rabbit/',       views.RabbitResultView.as_view(), name='api-rabbit-result'),
    path('foursomes/<int:pk>/rabbit/setup/', views.RabbitSetupView.as_view(),  name='api-rabbit-setup'),

    # ---- Triple Cup (One-Round Ryder Cup) ----
    path('foursomes/<int:pk>/triple-cup/',                  views.TripleCupResultView.as_view(),         name='api-triple-cup-result'),
    path('foursomes/<int:pk>/triple-cup/setup/',            views.TripleCupSetupView.as_view(),          name='api-triple-cup-setup'),
    path('foursomes/<int:pk>/triple-cup/foursomes-tee-off/', views.TripleCupFoursomesTeeOffView.as_view(), name='api-triple-cup-foursomes-tee-off'),

    # ---- Multi-Foursome Skins (round-level) ----
    path('rounds/<int:pk>/multi-skins/',       views.MultiSkinsResultView.as_view(), name='api-multi-skins-result'),
    path('rounds/<int:pk>/multi-skins/setup/', views.MultiSkinsSetupView.as_view(),  name='api-multi-skins-setup'),

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
    path('rounds/<int:pk>/stableford/setup/', views.StablefordSetupView.as_view(), name='api-stableford-setup'),
    path('rounds/<int:pk>/stableford/',       views.StablefordResultView.as_view(), name='api-stableford-result'),

    # ---- Pink Ball setup (round-level) + per-foursome order ----
    path('rounds/<int:pk>/pink-ball/setup/',      views.PinkBallSetupView.as_view(),          name='api-pink-ball-setup'),
    path('foursomes/<int:pk>/pink-ball/order/',   views.PinkBallFoursomeOrderView.as_view(),  name='api-pink-ball-order'),

    # ---- Team Tournament (Ryder Cup) ----
    path('tournaments/<int:pk>/team-tournament/setup/',                                          views.TeamTournamentSetupView.as_view(),        name='api-team-tournament-setup'),
    path('tournaments/<int:pk>/team-tournament/',                                                views.TeamTournamentDetailView.as_view(),       name='api-team-tournament-detail'),
    path('tournaments/<int:pk>/team-tournament/draft-complete/',                                 views.TeamTournamentDraftCompleteView.as_view(),name='api-team-tournament-draft-complete'),
    path('tournaments/<int:pk>/team-tournament/teams/<int:team_pk>/',                             views.TeamRenameView.as_view(),                name='api-team-rename'),
    path('tournaments/<int:pk>/team-tournament/teams/<int:team_pk>/players/',                    views.TeamPlayerView.as_view(),                name='api-team-player-add'),
    path('tournaments/<int:pk>/team-tournament/teams/<int:team_pk>/players/<int:player_pk>/',    views.TeamPlayerView.as_view(),                name='api-team-player-remove'),

    # ---- Ryder Cup round config ----
    path('rounds/<int:pk>/ryder-cup/setup/',      views.RyderCupRoundSetupView.as_view(),      name='api-ryder-cup-round-setup'),
    path('rounds/<int:pk>/ryder-cup/',            views.RyderCupRoundResultView.as_view(),     name='api-ryder-cup-round-result'),
    path('rounds/<int:pk>/ryder-cup/calculate/',    views.RyderCupRoundCalculateView.as_view(),  name='api-ryder-cup-round-calculate'),
    path('rounds/<int:pk>/ryder-cup/change-game/',  views.RyderCupChangeGameView.as_view(),      name='api-ryder-cup-change-game'),
    path('rounds/<int:pk>/cup-live/',             views.CupRoundLiveView.as_view(),             name='api-cup-round-live'),
    path('rounds/<int:pk>/tee-times/',            views.TeeTimeBulkView.as_view(),             name='api-tee-times-bulk'),

    # ---- Quota Nassau (per-foursome) ----
    path('foursomes/<int:pk>/quota-nassau/',        views.QuotaNassauResultView.as_view(), name='api-quota-nassau-result'),
    path('foursomes/<int:pk>/quota-nassau/setup/',  views.QuotaNassauSetupView.as_view(),  name='api-quota-nassau-setup'),

    # ---- Version check ----
    path('version/', views.VersionCheckView.as_view(), name='api-version'),

    # ---- Health check ----
    path('health/', views.health_check, name='api-health'),

    # ---- Debug / admin helpers ----
    path('debug/singles-matches/', views.debug_singles_matches, name='api-debug-singles'),
    path('debug/singles-matches/<int:foursome_id>/fix/', views.debug_fix_singles_match, name='api-debug-singles-fix'),

    # ---- Shared course catalog ----
    path('catalog/courses/',              views.CatalogCourseListView.as_view(), name='api-catalog-courses'),
    path('catalog/courses/<int:pk>/add/', views.CatalogCourseAddView.as_view(),  name='api-catalog-course-add'),

    # ---- Course import from GolfCourseAPI ----
    path('courses/golf-api/search/',                   views.GolfApiSearchView.as_view(),        name='api-golf-api-search'),
    path('courses/golf-api/courses/<int:course_id>/',  views.GolfApiCourseDetailView.as_view(),  name='api-golf-api-course-detail'),
    path('courses/import/',                            views.CourseImportView.as_view(),          name='api-course-import'),
    path('courses/paste/',                             views.CoursePasteView.as_view(),           name='api-course-paste'),
    path('courses/<int:pk>/tees/paste/',               views.TeePasteView.as_view(),              name='api-tee-paste'),
]
