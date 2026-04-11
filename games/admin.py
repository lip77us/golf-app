from django.contrib import admin

from .models import (
    # Six's (rotating-team best ball)
    SixesSegment, SixesTeam, SixesHoleResult,
    # Nassau 9-9-18 (fixed teams + auto-press)
    NassauGame, NassauTeam, NassauHoleScore, NassauPress,
    # Irish Rumble
    IrishRumbleConfig, IrishRumbleSegmentResult,
    # Pink / Red Ball survivor pool
    PinkBallHoleResult, PinkBallResult,
    # Scramble
    ScrambleHoleScore, ScrambleResult,
    # Match Play
    MatchPlayBracket, MatchPlayMatch, MatchPlayHoleResult,
)


# ---------------------------------------------------------------------------
# Six's inlines
# ---------------------------------------------------------------------------

class SixesTeamInline(admin.TabularInline):
    model             = SixesTeam
    extra             = 0
    filter_horizontal = ('players',)


class SixesHoleResultInline(admin.TabularInline):
    model    = SixesHoleResult
    extra    = 0
    fields   = ('hole_number', 'team1_best_net', 'team2_best_net', 'winning_team', 'holes_up_after')
    ordering = ('hole_number',)


# ---------------------------------------------------------------------------
# Nassau 9-9-18 inlines
# ---------------------------------------------------------------------------

class NassauTeamInline(admin.TabularInline):
    model             = NassauTeam
    extra             = 0
    filter_horizontal = ('players',)


class NassauHoleScoreInline(admin.TabularInline):
    model    = NassauHoleScore
    extra    = 0
    fields   = ('hole_number', 'team1_best_net', 'team2_best_net', 'winner',
                'front9_up_after', 'back9_up_after')
    ordering = ('hole_number',)


class NassauPressInline(admin.TabularInline):
    model    = NassauPress
    extra    = 0
    fields   = ('nine', 'triggered_on_hole', 'start_hole', 'end_hole', 'result', 'holes_up')
    ordering = ('triggered_on_hole',)


# ---------------------------------------------------------------------------
# Match Play inlines
# ---------------------------------------------------------------------------

class MatchPlayMatchInline(admin.TabularInline):
    model             = MatchPlayMatch
    extra             = 0
    fields            = ('round_number', 'start_hole', 'player1', 'player2', 'status', 'result')
    show_change_link  = True


class MatchPlayHoleResultInline(admin.TabularInline):
    model    = MatchPlayHoleResult
    extra    = 0
    fields   = ('hole_number', 'p1_net', 'p2_net', 'winner', 'holes_up_after')
    ordering = ('hole_number',)


# ---------------------------------------------------------------------------
# Scramble inlines
# ---------------------------------------------------------------------------

class ScrambleHoleScoreInline(admin.TabularInline):
    model    = ScrambleHoleScore
    extra    = 0
    fields   = ('hole_number', 'gross_score', 'handicap_strokes', 'net_score', 'chosen_player')
    ordering = ('hole_number',)


# ---------------------------------------------------------------------------
# Six's admins
# ---------------------------------------------------------------------------

@admin.register(SixesSegment)
class SixesSegmentAdmin(admin.ModelAdmin):
    list_display  = ('__str__', 'foursome', 'segment_number', 'start_hole', 'end_hole',
                     'status', 'is_extra')
    list_filter   = ('status', 'is_extra', 'foursome__round__tournament')
    ordering      = ('foursome', 'segment_number', 'start_hole')
    inlines       = [SixesTeamInline, SixesHoleResultInline]


@admin.register(SixesTeam)
class SixesTeamAdmin(admin.ModelAdmin):
    list_display      = ('__str__', 'segment', 'team_number', 'team_select_method', 'is_winner')
    list_filter       = ('is_winner', 'team_select_method')
    filter_horizontal = ('players',)


# ---------------------------------------------------------------------------
# Nassau 9-9-18 admins
# ---------------------------------------------------------------------------

@admin.register(NassauGame)
class NassauGameAdmin(admin.ModelAdmin):
    list_display  = ('__str__', 'foursome', 'status', 'front9_result', 'back9_result',
                     'overall_result', 'press_pct')
    list_filter   = ('status', 'foursome__round__tournament')
    inlines       = [NassauTeamInline, NassauHoleScoreInline, NassauPressInline]


@admin.register(NassauTeam)
class NassauTeamAdmin(admin.ModelAdmin):
    list_display      = ('__str__', 'game', 'team_number')
    filter_horizontal = ('players',)


# ---------------------------------------------------------------------------
# Irish Rumble
# ---------------------------------------------------------------------------

@admin.register(IrishRumbleConfig)
class IrishRumbleConfigAdmin(admin.ModelAdmin):
    list_display  = ('round',)
    search_fields = ('round__course__course_name',)


@admin.register(IrishRumbleSegmentResult)
class IrishRumbleSegmentResultAdmin(admin.ModelAdmin):
    list_display  = ('foursome', 'round', 'segment_index', 'balls_counted', 'total_net_score', 'rank')
    list_filter   = ('round__tournament',)
    ordering      = ('round', 'segment_index', 'rank')


# ---------------------------------------------------------------------------
# Pink Ball (Red Ball) — survivor pool
# ---------------------------------------------------------------------------

@admin.register(PinkBallHoleResult)
class PinkBallHoleResultAdmin(admin.ModelAdmin):
    list_display  = ('round', 'foursome', 'hole_number', 'pink_ball_player',
                     'net_score', 'ball_lost', 'is_winner')
    list_filter   = ('ball_lost', 'is_winner', 'round__tournament')
    ordering      = ('round', 'foursome', 'hole_number')


@admin.register(PinkBallResult)
class PinkBallResultAdmin(admin.ModelAdmin):
    list_display  = ('rank', 'foursome', 'round', 'eliminated_on_hole', 'total_net_score')
    list_filter   = ('round__tournament',)
    ordering      = ('round', 'rank')


# ---------------------------------------------------------------------------
# Scramble
# ---------------------------------------------------------------------------

@admin.register(ScrambleHoleScore)
class ScrambleHoleScoreAdmin(admin.ModelAdmin):
    list_display  = ('foursome', 'hole_number', 'gross_score', 'handicap_strokes',
                     'net_score', 'chosen_player')
    list_filter   = ('foursome__round__tournament',)
    ordering      = ('foursome', 'hole_number')


@admin.register(ScrambleResult)
class ScrambleResultAdmin(admin.ModelAdmin):
    list_display  = ('foursome', 'round', 'total_gross', 'total_net', 'rank')
    list_filter   = ('round__tournament',)
    ordering      = ('round', 'rank')


# ---------------------------------------------------------------------------
# Match Play (within foursome)
# ---------------------------------------------------------------------------

@admin.register(MatchPlayBracket)
class MatchPlayBracketAdmin(admin.ModelAdmin):
    list_display  = ('__str__', 'foursome', 'bracket_type', 'status', 'winner')
    list_filter   = ('status', 'bracket_type', 'foursome__round__tournament')
    inlines       = [MatchPlayMatchInline]


@admin.register(MatchPlayMatch)
class MatchPlayMatchAdmin(admin.ModelAdmin):
    list_display  = ('__str__', 'bracket', 'round_number', 'start_hole', 'status', 'result')
    list_filter   = ('status', 'result')
    inlines       = [MatchPlayHoleResultInline]
