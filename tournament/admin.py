from django import forms
from django.contrib import admin, messages
from django.shortcuts import get_object_or_404, redirect
from django.template.response import TemplateResponse
from django.urls import path

from core.models import GameType
from .models import (
    Tournament, Round, Foursome, FoursomeMembership,
    MatchPlayChampionship, ChampionshipSeed,
)


# ---------------------------------------------------------------------------
# Checkbox widget for active_games JSONField
# ---------------------------------------------------------------------------

class ActiveGamesWidget(forms.Widget):
    """Renders GameType choices as checkboxes; stores as JSON list."""

    def render(self, name, value, attrs=None, renderer=None):
        import json
        from django.utils.safestring import mark_safe

        if isinstance(value, str):
            try:
                selected = set(json.loads(value))
            except (json.JSONDecodeError, TypeError):
                selected = set()
        elif isinstance(value, list):
            selected = set(value)
        else:
            selected = set()

        html = '<div style="line-height:2;">'
        for val, label in GameType.choices:
            checked = 'checked' if val in selected else ''
            html += (
                f'<label style="margin-right:20px;font-weight:normal;">'
                f'<input type="checkbox" name="{name}" value="{val}" {checked} '
                f'style="margin-right:4px;">{label}'
                f'</label>'
            )
        html += '</div>'
        return mark_safe(html)

    def value_from_datadict(self, data, files, name):
        import json
        return json.dumps(data.getlist(name))


class TournamentAdminForm(forms.ModelForm):
    class Meta:
        model   = Tournament
        fields  = '__all__'
        widgets = {'active_games': ActiveGamesWidget}


class RoundAdminForm(forms.ModelForm):
    class Meta:
        model   = Round
        fields  = '__all__'
        widgets = {'active_games': ActiveGamesWidget}


# ---------------------------------------------------------------------------
# Inlines
# ---------------------------------------------------------------------------

class RoundInline(admin.TabularInline):
    model            = Round
    extra            = 0
    fields           = ('round_number', 'date', 'course', 'status', 'bet_unit')
    show_change_link = True


class FoursomeMembershipInline(admin.TabularInline):
    model  = FoursomeMembership
    extra  = 0
    fields = ('player', 'course_handicap', 'playing_handicap')


class FoursomeInline(admin.TabularInline):
    model            = Foursome
    extra            = 0
    fields           = ('group_number', 'has_phantom')
    show_change_link = True


class ChampionshipSeedInline(admin.TabularInline):
    model  = ChampionshipSeed
    extra  = 0
    fields = ('seed_number', 'player', 'source_foursome')


# ---------------------------------------------------------------------------
# Foursome admin — includes custom scorecard view
# ---------------------------------------------------------------------------

@admin.register(Foursome)
class FoursomeAdmin(admin.ModelAdmin):
    list_display  = ('__str__', 'round', 'group_number', 'has_phantom')
    list_filter   = ('has_phantom', 'round__tournament')
    search_fields = ('round__course__course_name',)
    ordering      = ('round', 'group_number')
    inlines       = [FoursomeMembershipInline]
    change_form_template = 'admin/tournament/foursome/change_form.html'

    def get_urls(self):
        urls = super().get_urls()
        custom = [
            path(
                '<int:foursome_id>/scorecard/',
                self.admin_site.admin_view(self.scorecard_view),
                name='tournament_foursome_scorecard',
            ),
        ]
        return custom + urls

    def scorecard_view(self, request, foursome_id):
        from scoring.models import HoleScore
        from games.models import PinkBallHoleResult

        foursome    = get_object_or_404(Foursome, pk=foursome_id)
        tee         = foursome.round.course
        holes       = tee.holes
        active      = foursome.round.active_games or []
        pink_active = 'pink_ball' in active

        memberships = (
            foursome.memberships
            .filter(player__is_phantom=False)
            .select_related('player')
            .order_by('player__name')
        )
        players           = [m.player for m in memberships]
        membership_by_pid = {m.player_id: m for m in memberships}

        # Pink ball rotation: hole index (0-based) → player PK
        pink_order = foursome.pink_ball_order or []
        def pink_pid_for_hole(hole_number):
            if not pink_order:
                return None
            return pink_order[(hole_number - 1) % len(pink_order)]

        # Existing hole scores keyed by (player_id, hole_number)
        existing = {
            (hs.player_id, hs.hole_number): hs
            for hs in HoleScore.objects.filter(foursome=foursome).select_related('player')
        }

        # Existing pink ball hole results keyed by hole_number
        existing_pb = {
            pbhr.hole_number: pbhr
            for pbhr in PinkBallHoleResult.objects.filter(round=foursome.round, foursome=foursome)
        }

        if request.method == 'POST':
            # ---- Save hole scores ----
            saved = 0
            for player in players:
                membership = membership_by_pid[player.pk]
                for hole_data in holes:
                    hole_number = hole_data['number']
                    raw = request.POST.get(f'score_{player.pk}_{hole_number}', '').strip()
                    if not raw:
                        continue
                    try:
                        gross = int(raw)
                    except ValueError:
                        continue

                    strokes = membership.handicap_strokes_on_hole(hole_data['stroke_index'])
                    key     = (player.pk, hole_number)
                    if key in existing:
                        hs = existing[key]
                        hs.gross_score      = gross
                        hs.handicap_strokes = strokes
                        hs.save()
                    else:
                        HoleScore.objects.create(
                            foursome         = foursome,
                            player           = player,
                            hole_number      = hole_number,
                            gross_score      = gross,
                            handicap_strokes = strokes,
                        )
                    saved += 1

            # ---- Pink ball: auto-record from hole scores ----
            if pink_active:
                from services.red_ball import record_hole, calculate_red_ball
                # Refresh scores after save
                fresh_scores = {
                    (hs.player_id, hs.hole_number): hs
                    for hs in HoleScore.objects.filter(foursome=foursome)
                }
                for hole_data in holes:
                    hole_number = hole_data['number']
                    pid         = pink_pid_for_hole(hole_number)
                    if pid is None:
                        continue
                    ball_lost = request.POST.get(f'ball_lost_{hole_number}') == 'on'
                    hs        = fresh_scores.get((pid, hole_number))
                    net_score = hs.net_score if hs and not ball_lost else None
                    # Only record if we have a score or a ball-lost flag
                    if hs or ball_lost:
                        record_hole(foursome.round, foursome, hole_number, net_score, ball_lost)
                calculate_red_ball(foursome.round)

            # ---- Skins ----
            if 'skins' in active:
                from services.skins import calculate_skins
                calculate_skins(foursome)

            messages.success(request, f'{saved} score(s) saved for {foursome}.')
            return redirect('.')

        # ---- Build grid for template ----
        grid = []
        for player in players:
            membership = membership_by_pid[player.pk]
            row_holes  = []
            front_gross = front_net = back_gross = back_net = 0
            front_complete = back_complete = True

            for hole_data in holes:
                hole_number = hole_data['number']
                hs          = existing.get((player.pk, hole_number))
                gross       = hs.gross_score if hs else None
                net         = hs.net_score   if hs else None
                front       = hole_number <= 9
                pid         = pink_pid_for_hole(hole_number)
                is_pink     = pink_active and (player.pk == pid)
                pbhr        = existing_pb.get(hole_number) if is_pink else None
                ball_lost   = pbhr.ball_lost if pbhr else False

                if gross is not None:
                    if front: front_gross += gross
                    else:     back_gross  += gross
                else:
                    if front: front_complete = False
                    else:     back_complete  = False

                if net is not None:
                    if front: front_net += net
                    else:     back_net  += net

                row_holes.append({
                    'hole_data' : hole_data,
                    'gross'     : gross if gross is not None else '',
                    'net'       : net   if net   is not None else '',
                    'strokes'   : hs.handicap_strokes if hs else membership.handicap_strokes_on_hole(hole_data['stroke_index']),
                    'is_pink'   : is_pink,
                    'ball_lost' : ball_lost,
                })

            grid.append({
                'player'       : player,
                'membership'   : membership,
                'holes'        : row_holes,
                'front_gross'  : front_gross if front_complete else '',
                'front_net'    : front_net   if front_complete else '',
                'back_gross'   : back_gross  if back_complete  else '',
                'back_net'     : back_net    if back_complete  else '',
                'gross_total'  : (front_gross + back_gross) if (front_complete and back_complete) else '',
                'net_total'    : (front_net   + back_net)   if (front_complete and back_complete) else '',
            })

        front9    = holes[:9]
        back9     = holes[9:]
        front9_par = sum(h['par'] for h in front9)
        back9_par  = sum(h['par'] for h in back9)

        context = {
            **self.admin_site.each_context(request),
            'title'     : f'Scorecard — {foursome}',
            'foursome'  : foursome,
            'holes'     : holes,
            'grid'      : grid,
            'front9'    : front9,
            'back9'     : back9,
            'front9_par': front9_par,
            'back9_par' : back9_par,
            'total_par' : front9_par + back9_par,
            'opts'      : self.model._meta,
        }
        return TemplateResponse(
            request,
            'admin/tournament/foursome/scorecard.html',
            context,
        )


# ---------------------------------------------------------------------------
# Remaining ModelAdmins
# ---------------------------------------------------------------------------

@admin.register(Tournament)
class TournamentAdmin(admin.ModelAdmin):
    form          = TournamentAdminForm
    list_display  = ('name', 'start_date', 'end_date', 'total_rounds', 'rounds_to_count')
    search_fields = ('name',)
    ordering      = ('-start_date',)
    inlines       = [RoundInline]


@admin.register(Round)
class RoundAdmin(admin.ModelAdmin):
    form          = RoundAdminForm
    list_display  = ('__str__', 'tournament', 'status', 'bet_unit', 'date')
    list_filter   = ('status', 'tournament')
    search_fields = ('course__course_name',)
    ordering      = ('-date',)
    inlines       = [FoursomeInline]


@admin.register(FoursomeMembership)
class FoursomeMembershipAdmin(admin.ModelAdmin):
    list_display  = ('player', 'foursome', 'course_handicap', 'playing_handicap')
    search_fields = ('player__name',)
    list_filter   = ('foursome__round__tournament',)


@admin.register(MatchPlayChampionship)
class MatchPlayChampionshipAdmin(admin.ModelAdmin):
    list_display  = ('tournament', 'status', 'champion')
    list_filter   = ('status',)
    inlines       = [ChampionshipSeedInline]
