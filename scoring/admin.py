from django.contrib import admin

from .models import HoleScore, StablefordResult, SkinsResult, LowNetResult


# ---------------------------------------------------------------------------
# Hole Scores — the source of truth
# ---------------------------------------------------------------------------

@admin.register(HoleScore)
class HoleScoreAdmin(admin.ModelAdmin):
    list_display  = ('player', 'foursome', 'hole_number', 'gross_score', 'handicap_strokes', 'net_score', 'stableford_points')
    list_filter   = ('foursome__round__tournament', 'foursome__round')
    search_fields = ('player__name',)
    ordering      = ('foursome', 'hole_number', 'player')


# ---------------------------------------------------------------------------
# Stableford
# ---------------------------------------------------------------------------

@admin.register(StablefordResult)
class StablefordResultAdmin(admin.ModelAdmin):
    list_display  = ('player', 'round', 'total_points', 'rank')
    list_filter   = ('round__tournament', 'round')
    search_fields = ('player__name',)
    ordering      = ('round', 'rank')


# ---------------------------------------------------------------------------
# Skins
# ---------------------------------------------------------------------------

@admin.register(SkinsResult)
class SkinsResultAdmin(admin.ModelAdmin):
    list_display  = ('foursome', 'hole_number', 'winner', 'skins_value', 'is_carryover')
    list_filter   = ('is_carryover', 'foursome__round__tournament')
    ordering      = ('foursome', 'hole_number')


# ---------------------------------------------------------------------------
# Low Net Championship
# ---------------------------------------------------------------------------

@admin.register(LowNetResult)
class LowNetResultAdmin(admin.ModelAdmin):
    list_display  = ('player', 'tournament', 'final_net', 'rank')
    list_filter   = ('tournament',)
    search_fields = ('player__name',)
    ordering      = ('tournament', 'rank')
