"""
console/views.py
----------------
The TD console: sign in, then import a Golf Genius roster.

Plain Django views and server-rendered templates on the existing backend —
the same session and account resolution the rest of the app already has.  No
front-end build step; the console is a tool a TD opens on a laptop the night
before a tournament, not an application.

The import is a UI over ``services/genius_import``, not a second importer.
The command is dry-run by default and needs ``--apply`` to write, and that
shape carries over exactly: **the preview is the only step**, and Apply is the
second, deliberate press.  There is no confirm dialog, because the preview
*is* the confirm.
"""

from __future__ import annotations

import csv
import io

import logging

from django.conf import settings
from django.contrib.auth import logout as django_logout
from django.core.mail import send_mail
from django.db import transaction
from django.http import HttpResponse
from django.shortcuts import get_object_or_404, redirect, render
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_POST

from core.models import Course, Player, Tee
from services import genius_import as gi
from tournament.models import Round

from services.tee_revisions import update_tee_geometry

from . import auth, courses as courselib, custom_tees as custom, \
    plan as planlib
from .models import CourseCheck, ImportRun

logger = logging.getLogger(__name__)


# A Golf Genius roster is a few hundred rows of text.  Anything past these is
# the wrong file, and saying so beats parsing it for thirty seconds first.
MAX_UPLOAD_BYTES = 4 * 1024 * 1024
MAX_DATA_ROWS    = 4000


# ---------------------------------------------------------------------------
# Sign in
# ---------------------------------------------------------------------------

def sign_in(request):
    """Number entry.  Public."""
    if request.user.is_authenticated and request.user.account_id:
        return redirect(reverse('console:import'))

    typed, error = request.POST.get('phone', ''), ''
    if request.method == 'POST':
        try:
            auth.start(request, typed)
            return redirect(reverse('console:sign-in-code'))
        except auth.SignInError as exc:
            error = str(exc)

    # "Not you?" — drop the remembered number and the route it was going back
    # to, so a second person on the same laptop starts clean.
    if request.GET.get('fresh'):
        for key in (auth.PENDING_PHONE, auth.PENDING_TYPED,
                    auth.RETURN_TO, auth.RETURN_LABEL):
            request.session.pop(key, None)
        return redirect(reverse('console:sign-in'))

    # A lapsed session names the screen it threw the TD off, and pre-fills the
    # number, so getting back is one code rather than a re-navigation.  Read
    # and put straight back: the notice has to survive a failed attempt.
    return_to, return_label = auth.take_return_to(request)
    if return_to:
        request.session[auth.RETURN_TO] = return_to
        request.session[auth.RETURN_LABEL] = return_label

    return render(request, 'console/sign_in.html', {
        'typed': typed or request.session.get(auth.PENDING_TYPED, ''),
        'error': error,
        'expired_label': return_label,
    })


def sign_in_code(request):
    """Code entry.  The pending number is held server-side, never in the URL."""
    if request.user.is_authenticated and request.user.account_id:
        return redirect(reverse('console:import'))
    if not request.session.get(auth.PENDING_PHONE):
        return redirect(reverse('console:sign-in'))

    error = ''
    if request.method == 'POST':
        if request.POST.get('action') == 'resend':
            try:
                auth.resend(request)
            except auth.SignInError as exc:
                error = str(exc)
        else:
            # Six separate boxes on screen, one value on the wire.
            code = ''.join(request.POST.getlist('digit')) or request.POST.get('code', '')
            try:
                auth.finish(request, code,
                            remember=bool(request.POST.get('remember')))
                target, _ = auth.take_return_to(request)
                # Verify lands on Import roster, not a dashboard: a TD opens a
                # laptop to move a field of forty golfers in without typing
                # forty names.  Everything else is one click in the sidebar.
                return redirect(target or reverse('console:import'))
            except auth.SignInError as exc:
                error = str(exc)

    return render(request, 'console/sign_in_code.html', {
        'typed':        request.session.get(auth.PENDING_TYPED, ''),
        'error':        error,
        'resend_wait':  auth.resend_wait(request),
        'attempts_left': auth.attempts_left(request),
    })


@require_POST
def sign_out(request):
    django_logout(request)
    return redirect(reverse('console:sign-in'))


# ---------------------------------------------------------------------------
# Shell context
# ---------------------------------------------------------------------------

def _shell(request, *, nav, account_label='ACCOUNT'):
    """Everything the sidebar needs.

    The account is stated on every page that writes, and not in a menu — a
    user belongs to exactly one Account, so this is a fact rather than a
    picker, which is also why the import page can never resolve the wrong one.
    """
    return {
        'nav': nav,
        'account': request.user.account,
        'account_label': account_label,
        'me': request.user,
    }


def _can_write(request) -> bool:
    """Whether this golfer can change the account's roster.

    The portal is open — anyone may sign in, there is no TD role to grant.
    But an import writes eighty golfers into a roster the whole account
    shares, so the write itself is an admin act.  A golfer who runs nothing
    gets an empty state naming what would fill it, not a rejection.
    """
    return bool(request.user.is_account_admin or request.user.is_superuser)


def _no_events(request):
    return render(request, 'console/no_events.html',
                  _shell(request, nav='import'), status=200)


# ---------------------------------------------------------------------------
# Import — drop
# ---------------------------------------------------------------------------

@auth.td_required('Import roster')
def import_start(request):
    """The empty state, and the file drop.

    Nothing is loaded, so the page states what the importer reads and how it
    matches *before* a file is committed to it.
    """
    if not _can_write(request):
        return _no_events(request)

    error = ''
    if request.method == 'POST':
        upload = request.FILES.get('file')
        try:
            run = _ingest(request, upload)
            return redirect(reverse('console:import-preview', args=[run.pk]))
        except ValueError as exc:
            error = str(exc)

    ctx = _shell(request, nav='import')
    ctx.update({
        'error': error,
        'recent': _recent_runs(request.user.account),
    })
    return render(request, 'console/import_start.html', ctx)


def _ingest(request, upload) -> ImportRun:
    """Read and parse an upload into a preview run.  Writes no golfers."""
    if upload is None:
        raise ValueError('Choose a Golf Genius roster export to import.')
    if upload.size > MAX_UPLOAD_BYTES:
        raise ValueError(
            f'That file is {upload.size // 1024} KB — larger than a roster '
            f'export should be. Check it is the right file.')

    data = upload.read()
    try:
        rows = gi.read_rows(upload.name, data)
        header = gi.header_line(rows)
        parsed, _ = gi.parse_rows(rows)
    except ValueError as exc:
        # Unsupported extension, or no First Name / Last Name header anywhere.
        raise ValueError(str(exc)) from exc

    if len(parsed) > MAX_DATA_ROWS:
        raise ValueError(
            f'That sheet has {len(parsed):,} data rows. The importer caps at '
            f'{MAX_DATA_ROWS:,} — split the file or check it is a roster export.')
    if not parsed:
        raise ValueError(
            f'The header was found on row {header}, but there are no data rows '
            f'under it. Is this the right sheet?')

    account = request.user.account
    return ImportRun.objects.create(
        account=account,
        user=request.user,
        filename=upload.name,
        file_size=upload.size,
        header_line=header,
        data_rows=len(parsed),
        roster_size=Player.objects.filter(account=account,
                                          is_phantom=False).count(),
        parsed=planlib.serialize_rows(parsed),
    )


# ---------------------------------------------------------------------------
# Import — the dry run
# ---------------------------------------------------------------------------

@auth.td_required('Import preview')
def import_preview(request, pk):
    """The dry run, which is the whole screen.

    Handles three posts: a TD typing an index into a skipped row (rebuilds the
    plan and re-renders — nothing is written), Discard, and Apply.
    """
    if not _can_write(request):
        return _no_events(request)

    run = get_object_or_404(ImportRun, pk=pk, account=request.user.account)
    if run.status == ImportRun.STATUS_APPLIED:
        return redirect(reverse('console:import-run', args=[run.number]))
    if run.status == ImportRun.STATUS_DISCARDED:
        return redirect(reverse('console:import'))

    error = ''
    if request.method == 'POST':
        action = request.POST.get('action')
        if action == 'discard':
            run.status = ImportRun.STATUS_DISCARDED
            run.save(update_fields=['status'])
            return redirect(reverse('console:import'))
        if action == 'index':
            _set_override(run, request.POST.get('line', ''),
                          request.POST.get('index', ''))
            return redirect(reverse('console:import-preview', args=[run.pk]))
        if action == 'apply':
            try:
                _apply(run, request.user)
                return redirect(reverse('console:import-run', args=[run.number]))
            except ValueError as exc:
                error = str(exc)

    plan = planlib.build(run)
    ctx = _shell(request, nav='import', account_label='IMPORTING INTO')
    ctx.update({
        'run':  run,
        'plan': planlib.view(plan, run.overrides),
        'error': error,
    })
    return render(request, 'console/import_preview.html', ctx)


def _set_override(run, line: str, raw_index: str) -> None:
    """Record (or clear) an index the TD typed into a skipped row.

    Inline index entry is the console's one addition to the importer, and the
    reason it beats the CLI: no re-export, no round trip to Golf Genius.  The
    value is stored against the source line, and the plan is rebuilt from it.
    """
    try:
        line_no = int(line)
    except (TypeError, ValueError):
        return
    overrides = dict(run.overrides or {})
    if planlib.parse_typed_index(raw_index) is None:
        overrides.pop(str(line_no), None)      # blank or unusable clears it
    else:
        overrides[str(line_no)] = raw_index.strip()
    run.overrides = overrides
    run.save(update_fields=['overrides'])


def _apply(run, user) -> None:
    """Commit a preview run.

    One transaction over the golfer writes and the run record together: a
    failure writes nothing, and the footer says so before the press.  The plan
    is rebuilt inside the transaction, so what is applied is what the roster
    looks like now — not what it looked like when the file was dropped.
    """
    with transaction.atomic():
        # Lock the run so a double-submit can't apply the same file twice.
        locked = ImportRun.objects.select_for_update().get(pk=run.pk)
        if locked.status != ImportRun.STATUS_PREVIEW:
            raise ValueError('That import has already been applied.')

        plan = planlib.build(locked)
        created, updated = gi.apply_plan(locked.account, plan)

        locked.status     = ImportRun.STATUS_APPLIED
        locked.number     = locked.next_number()
        locked.applied_at = timezone.now()
        locked.user       = user
        locked.result     = {
            'counts': {
                'create':    created,
                'update':    updated,
                'unchanged': len(plan.unchanged),
                'skipped':   len(plan.skipped),
                'td_index':  sum(1 for r in plan.to_create if r.td_index),
            },
            # Counted after the writes, so the receipt's "the roster is now
            # N golfers" is a fact rather than arithmetic.
            'roster_after': Player.objects.filter(
                account=locked.account, is_phantom=False).count(),
            'log': planlib.change_log(plan),
        }
        locked.save()
    run.refresh_from_db()


# ---------------------------------------------------------------------------
# Import — the receipt
# ---------------------------------------------------------------------------

@auth.td_required('Import receipt')
def import_run(request, number):
    """What changed, what is still wrong, and the run kept as a record.

    No undo button, because the importer has no undo.  The stored change log
    is what a future reversal would be built from; drawing the button before
    the code exists would be a promise the page can't keep.
    """
    run = get_object_or_404(ImportRun, number=number,
                            account=request.user.account,
                            status=ImportRun.STATUS_APPLIED)
    log = (run.result or {}).get('log', {})
    ctx = _shell(request, nav='import')
    ctx.update({
        'run':     run,
        'counts':  (run.result or {}).get('counts', {}),
        'roster_after': (run.result or {}).get('roster_after'),
        'log':     log,
        'updates': planlib.receipt_updates(log),
        'still_wrong': _still_wrong(log),
        'recent':  _recent_runs(request.user.account),
    })
    return render(request, 'console/import_receipt.html', ctx)


def _still_wrong(log: dict) -> list[str]:
    """The file errors that stayed skipped, as sentences a TD can act on.

    A receipt that only counts what changed leaves the four rows that didn't
    for the TD to rediscover next time.
    """
    out, dupes = [], 0
    for s in log.get('skipped', []):
        code, name = s.get('code'), s.get('name') or f'Row {s.get("line")}'
        if code == gi.SKIP_NO_NAME:
            out.append(f'Row {s.get("line")} has no name — fix it in Golf Genius '
                       f'and re-import, or add the golfer by hand.')
        elif code == gi.SKIP_INDEX_RANGE:
            out.append(f'{name}: {s.get("reason", "").lower()} — allowed −10 to 54.')
        elif code == gi.SKIP_NO_INDEX:
            out.append(f'{name} still has no index, so no golfer was created.')
        elif code in (gi.SKIP_DUP_PHONE, gi.SKIP_DUP_GHIN):
            dupes += 1
        elif code == gi.SKIP_ALREADY_MATCHED:
            out.append(f'Row {s.get("line")} pointed at a golfer another row had '
                       f'already claimed.')
    if dupes == 1:
        out.append('1 duplicate row was ignored; the row it repeats was imported.')
    elif dupes:
        out.append(f'{dupes} duplicate rows were ignored; the first of each '
                   f'was imported.')
    return out


def _recent_runs(account, limit=6):
    return list(ImportRun.objects
                .filter(account=account, status=ImportRun.STATUS_APPLIED)
                .order_by('-number')[:limit])


@auth.td_required('Import receipt')
def import_run_csv(request, number):
    """The run as a CSV — one line per source row, with what happened to it."""
    run = get_object_or_404(ImportRun, number=number,
                            account=request.user.account,
                            status=ImportRun.STATUS_APPLIED)
    log = (run.result or {}).get('log', {})

    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(['row', 'name', 'outcome', 'detail'])
    for c in log.get('created', []):
        detail = f'index {planlib.fmt_index(c["index"])}'
        if c.get('td_index'):
            detail += ' (typed in the console)'
        w.writerow([c['line'], c['name'], 'created', detail])
    for u in log.get('updated', []):
        changes = '; '.join(
            f'{k} {u["before"].get(k, "") or "blank"} -> {v}'
            for k, v in u['after'].items())
        w.writerow([u['line'], u['name'], f'updated (matched on {u["matched_by"]})',
                    changes])
    for s in log.get('skipped', []):
        w.writerow([s['line'], s['name'], 'skipped',
                    ' · '.join(p for p in (s['reason'], s.get('detail')) if p)])
    for r in log.get('unchanged', []):
        w.writerow([r['line'], r['name'], 'unchanged', ''])

    resp = HttpResponse(buf.getvalue(), content_type='text/csv')
    resp['Content-Disposition'] = (
        f'attachment; filename="halved-import-run-{run.number}.csv"')
    return resp


# ---------------------------------------------------------------------------
# Nav placeholder
# ---------------------------------------------------------------------------

@auth.td_required()
def home(request):
    return redirect(reverse('console:import'))


# ---------------------------------------------------------------------------
# Courses
# ---------------------------------------------------------------------------

@auth.td_required('Course library')
def course_library(request):
    """Every course this account owns, most-played first.

    Carries how many of your rounds used it, when the record last changed, and
    whether anybody has ever checked it — because a course played six times and
    never checked is the one worth the printed card before a tournament.
    """
    ctx = _shell(request, nav='courses')
    ctx['rows'] = courselib.library(request.user.account)
    return render(request, 'console/course_library.html', ctx)


@auth.td_required('Course')
def course_detail(request, pk):
    """The whole course in one grid — par, yards and stroke index across
    eighteen holes, per tee — plus the two things you can do about it."""
    course = get_object_or_404(Course, pk=pk, account=request.user.account)

    error = ''
    if request.method == 'POST' and _can_write(request):
        action = request.POST.get('action')
        if action == 'verify':
            courselib.mark_verified(course, request.user)
            return redirect(reverse('console:course', args=[course.pk]))
        if action == 'report':
            try:
                check = _send_report(request, course)
                return redirect(reverse('console:course-check',
                                        args=[course.pk, check.number]))
            except ValueError as exc:
                error = str(exc)

    ctx = _shell(request, nav='courses')
    ctx.update({
        'course':  course,
        'tees':    courselib.current_tees(course),
        'history': CourseCheck.objects.filter(course=course)[:8],
        'rounds':  Round.objects.filter(account=request.user.account,
                                        course=course).count(),
        'can_write': _can_write(request),
        'sources': CourseCheck.SOURCE_CHOICES,
        'error':   error,
    })
    return render(request, 'console/course_detail.html', ctx)


def _send_report(request, course):
    """Push a correction at the shared catalog, and mail it either way.

    The pending diff is whatever this account has already corrected locally
    since the last push — the console does not ask a TD to retype a change they
    have already made on the screen in front of them.
    """
    source = request.POST.get('source', '')
    if source not in dict(CourseCheck.SOURCE_CHOICES):
        raise ValueError('Say where the correction came from — that is what '
                         'tells the difference between a re-rating and a typo.')

    diff = []
    for check in CourseCheck.objects.filter(
            course=course, kind=CourseCheck.KIND_EDITED).order_by('created_at'):
        diff.extend(check.changes)
    if not diff:
        raise ValueError('Nothing to send — correct the record first, then '
                         'push it upstream.')

    check = courselib.send_upstream(
        course, request.user, source=source,
        note=(request.POST.get('note') or '').strip(),
        diff=diff, is_staff=bool(request.user.is_staff))

    subject, body = courselib.report_email(course, check, request.user)
    try:
        send_mail(subject, body, settings.DEFAULT_FROM_EMAIL,
                  [settings.COURSE_REPORT_EMAIL], fail_silently=False)
    except Exception:
        # The record and the catalog write already happened and are the part
        # that matters; a mail outage should not read as the report failing.
        logger.exception('course report email failed for course %s', course.id)
    return check


@auth.td_required('Course')
def course_check(request, pk, number):
    """The receipt for one push upstream."""
    course = get_object_or_404(Course, pk=pk, account=request.user.account)
    check = get_object_or_404(CourseCheck, course=course, number=number,
                              account=request.user.account)
    subject, body = courselib.report_email(course, check, request.user)
    ctx = _shell(request, nav='courses')
    ctx.update({'course': course, 'check': check,
                'subject': subject, 'body': body})
    return render(request, 'console/course_check.html', ctx)


@auth.td_required('Course')
def tee_edit(request, pk, tee_pk):
    """Edit one tee.

    Everything on the record is editable — you own this copy — but the write
    goes through `update_tee_geometry`, so a tee that has already been played
    is superseded rather than changed underneath the rounds that used it.
    """
    if not _can_write(request):
        return _no_events(request)

    course = get_object_or_404(Course, pk=pk, account=request.user.account)
    tee = get_object_or_404(Tee, pk=tee_pk, course=course,
                            superseded_by__isnull=True)

    problems, diff = [], []
    if request.method == 'POST':
        try:
            attrs, diff = courselib.read_tee_form(request.POST, tee)
            if not attrs:
                problems = ['Nothing changed.']
            elif request.POST.get('confirm') or not courselib.rating_at_risk(diff):
                courselib.apply_edit(course, tee, attrs, diff, request.user)
                return redirect(reverse('console:course', args=[course.pk]))
        except courselib.EditError as exc:
            problems = exc.problems

    ctx = _shell(request, nav='courses')
    ctx.update({
        'course': course, 'tee': tee,
        'problems': problems,
        'diff': diff,
        # Only asked when the edit changed the SHAPE of the course, not when it
        # only moved where the strokes fall.
        'confirm_rating': bool(diff) and courselib.rating_at_risk(diff)
                          and not problems,
        'played': Tee.objects.filter(pk=tee.pk,
                                     memberships__isnull=False).exists(),
        'posted': request.POST if request.method == 'POST' else None,
    })
    return render(request, 'console/tee_edit.html', ctx)


# ---------------------------------------------------------------------------
# Custom tees — a private re-index
# ---------------------------------------------------------------------------

@auth.td_required('Custom tees')
def custom_tee(request, pk, tee_pk):
    """Build or edit a re-index of one tee.

    `tee_pk` is the SOURCE tee when creating, and the custom set itself when
    editing — a custom set knows what it forked from, so one route serves both
    and the page always has the source row to draw above the editable one.
    """
    if not _can_write(request):
        return _no_events(request)

    course = get_object_or_404(Course, pk=pk, account=request.user.account)
    tee = get_object_or_404(Tee, pk=tee_pk, course=course,
                            superseded_by__isnull=True)
    editing = tee if tee.is_custom_index else None
    source = tee.custom_index_of if editing else tee
    n = len(source.holes)

    if request.method == 'POST':
        name, indexes, changed = custom.read_form(request.POST, source)
        problems = custom.problems(indexes, n)
        if not name:
            problems.insert(0, 'Give the set a name — it sits in a picker beside '
                               'the course’s own tees.')
        if not problems:
            if editing:
                # Same copy-on-write rule as any other tee: a set somebody has
                # already played keeps the ranking those rounds were scored on.
                update_tee_geometry(editing, {
                    'tee_name': name,
                    'holes': custom.build_holes(source, indexes)})
            else:
                custom.create(source, name, indexes)
            return redirect(reverse('console:course', args=[course.pk]))
    else:
        name = editing.tee_name if editing else custom.default_name(source)
        indexes = [h.get('stroke_index')
                   for h in (editing.holes if editing else source.holes)]
        problems, changed = [], None

    ctx = _shell(request, nav='courses')
    ctx.update({
        'course': course, 'source': source, 'editing': editing,
        'name': name,
        # Zipped so the template can draw source-above-yours per hole without
        # index arithmetic in the markup.
        'rows': [{'hole': h, 'source_index': h.get('stroke_index'),
                  'value': v, 'changed': v != h.get('stroke_index')}
                 for h, v in zip(source.holes, indexes)],
        'strip': custom.strip(indexes, n),
        'problems': problems,
        'blocker': custom.blocker(indexes, n),
        'suggestion': custom.suggestion(indexes, n, changed),
        'played': custom.rounds_using(editing) if editing else 0,
    })
    return render(request, 'console/custom_tee.html', ctx)


@auth.td_required('Custom tees')
@require_POST
def custom_tee_delete(request, pk, tee_pk):
    """Remove a custom set.

    Refused once a round has used it — the same PROTECT that guards a golfer's
    history guards the geometry a card was scored against, and Django would
    raise anyway. Saying so beats a 500.
    """
    if not _can_write(request):
        return _no_events(request)
    course = get_object_or_404(Course, pk=pk, account=request.user.account)
    tee = get_object_or_404(Tee, pk=tee_pk, course=course,
                            custom_index_of__isnull=False)
    if custom.rounds_using(tee):
        messages_error = 'That set has been played and cannot be removed.'
        ctx = _shell(request, nav='courses')
        ctx.update({'course': course, 'tees': courselib.current_tees(course),
                    'history': CourseCheck.objects.filter(course=course)[:8],
                    'rounds': Round.objects.filter(
                        account=request.user.account, course=course).count(),
                    'can_write': True, 'sources': CourseCheck.SOURCE_CHOICES,
                    'error': messages_error})
        return render(request, 'console/course_detail.html', ctx)
    tee.delete()
    return redirect(reverse('console:course', args=[course.pk]))
