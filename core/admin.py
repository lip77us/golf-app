import json

from django import forms
from django.contrib import admin
from django.utils.safestring import mark_safe

from .models import Player, Tee, Course


# ---------------------------------------------------------------------------
# Custom widget: renders 18-hole table instead of raw JSON box
# ---------------------------------------------------------------------------

class HolesWidget(forms.Widget):
    """
    Renders the holes JSONField as a tidy 18-row table.
    Each row: Hole | Par | Stroke Index | Yards
    """

    def render(self, name, value, attrs=None, renderer=None):
        # Normalise incoming value (may be string, list, or None)
        if isinstance(value, str):
            try:
                holes = json.loads(value)
            except (json.JSONDecodeError, TypeError):
                holes = []
        elif isinstance(value, list):
            holes = value
        else:
            holes = []

        # json.loads('null') returns None — guard against it
        if not isinstance(holes, list):
            holes = []

        by_number = {h['number']: h for h in holes}

        th = 'style="padding:5px 10px;text-align:center;background:#417690;color:#fff;font-size:12px;"'
        td_num = 'style="padding:4px 8px;text-align:center;font-weight:bold;background:#f8f8f8;"'
        td = 'style="padding:3px 4px;text-align:center;"'
        inp = 'style="width:55px;text-align:center;"'

        rows = []
        for i in range(1, 19):
            h = by_number.get(i, {})
            par   = h.get('par', 4)
            si    = h.get('stroke_index', i)
            yards = h.get('yards', '') or ''
            bg = 'background:#eef4fb;' if i <= 9 else ''
            rows.append(
                f'<tr style="{bg}">'
                f'<td {td_num}>{i}</td>'
                f'<td {td}><input type="number" name="{name}_par_{i}"   value="{par}"   min="3" max="6"  {inp} required /></td>'
                f'<td {td}><input type="number" name="{name}_si_{i}"    value="{si}"    min="1" max="18" {inp} required /></td>'
                f'<td {td}><input type="number" name="{name}_yards_{i}" value="{yards}" min="0"          {inp} /></td>'
                f'</tr>'
            )

        html = (
            '<table style="border-collapse:collapse;font-size:13px;">'
            '<thead><tr>'
            f'<th {th}>Hole</th>'
            f'<th {th}>Par</th>'
            f'<th {th}>Stroke Index</th>'
            f'<th {th}>Yards</th>'
            '</tr></thead>'
            '<tbody>' + ''.join(rows) + '</tbody>'
            '</table>'
            '<p style="color:#999;font-size:11px;margin-top:4px;">'
            'Stroke Index: 1 = hardest hole, 18 = easiest (from the scorecard "Hdcp" column).'
            '</p>'
        )
        return mark_safe(html)

    def value_from_datadict(self, data, files, name):
        holes = []
        for i in range(1, 19):
            try:
                par = int(data.get(f'{name}_par_{i}') or 4)
            except (ValueError, TypeError):
                par = 4
            try:
                si = int(data.get(f'{name}_si_{i}') or i)
            except (ValueError, TypeError):
                si = i
            yards_raw = data.get(f'{name}_yards_{i}', '')
            try:
                yards = int(yards_raw) if yards_raw else 0
            except (ValueError, TypeError):
                yards = 0
            holes.append({'number': i, 'par': par, 'stroke_index': si, 'yards': yards})
        return json.dumps(holes)


class TeeAdminForm(forms.ModelForm):
    class Meta:
        model = Tee
        fields = '__all__'
        widgets = {'holes': HolesWidget}


# ---------------------------------------------------------------------------
# Admin registrations
# ---------------------------------------------------------------------------

@admin.register(Player)
class PlayerAdmin(admin.ModelAdmin):
    list_display  = ('name', 'handicap_index', 'is_phantom', 'email', 'created_at')
    list_filter   = ('is_phantom',)
    search_fields = ('name', 'email')
    ordering      = ('name',)


@admin.register(Course)
class CourseAdmin(admin.ModelAdmin):
    list_display  = ('name', 'created_at')
    search_fields = ('name',)
    ordering      = ('name',)


@admin.register(Tee)
class TeeAdmin(admin.ModelAdmin):
    form          = TeeAdminForm
    list_display  = ('course', 'tee_name', 'slope', 'course_rating', 'par')
    list_filter   = ('course',)
    search_fields = ('course__name', 'tee_name')
    ordering      = ('course__name', 'tee_name')
    fieldsets     = (
        (None, {
            'fields': ('course', 'tee_name', 'slope', 'course_rating', 'par'),
        }),
        ('Hole-by-Hole Data', {
            'fields': ('holes',),
        }),
    )
