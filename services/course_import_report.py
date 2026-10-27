"""Announce a REFUSED course import — to the log, and to the operator.

A refused import writes nothing.  `CourseImportView` runs the quality gate
before any DB write, inside its own ``@transaction.atomic``, so a course with
broken (or absent) hole data never reaches the shared catalog or the caller's
account.  That is the whole point of the gate, and it is also why nobody ever
found out a refusal had happened.

The first time it mattered, a golf club emailed to say one of their members
could not add their own course, and the database had no record at all: no
``Course`` row, no ``CatalogCourse`` row, no audit row, and nothing in the
view's own log line — which sits *below* the gate and therefore only ever
described imports that succeeded.  The member could not be identified.

So a refusal is now announced twice, because the two readers want different
things:

* **the log** names the user by **id and account id, never by phone.**  A phone
  number is this app's cross-account identity key and does not belong in a
  retained platform log; an id is enough to find the row, as whoever is reading
  has database access by definition.
* **the email** names the phone as well, because it is a direct message to the
  operator about one person to help, not a record that sits around.

A member who cannot add his home course is the most churn-prone moment in the
app, which is the argument for the email: the alternative is hearing about it
from a pro shop, or not at all.
"""

import logging

from django.conf import settings
from django.core.cache import cache
from django.core.mail import send_mail

logger = logging.getLogger(__name__)

# One email per course per day.  A broken course is a property of the COURSE,
# so the second golfer to try it tells the operator nothing new — while three
# taps from one frustrated member must not send three emails.  The log line is
# never throttled: it is cheap, and it is what answers "who tried".
#
# The cache is Django's default LocMemCache (no CACHES block is configured), so
# this is per worker process rather than exact.  That is deliberate and
# sufficient: it turns a flood into a handful, and a throttle that silently
# dropped the FIRST report would be worse than one that occasionally repeats.
EMAIL_THROTTLE_SECONDS = 24 * 60 * 60


def _alert_address():
    """Where refusals are emailed.  Empty string = don't email at all.

    Defaults to ``COURSE_REPORT_EMAIL`` — the console's upstream course-report
    address — because this is the same kind of problem arriving by a different
    door, and one inbox for "a course record is wrong" is the right number.
    """
    addr = getattr(settings, 'COURSE_IMPORT_ALERT_EMAIL', None)
    if addr is None:
        addr = getattr(settings, 'COURSE_REPORT_EMAIL', '')
    return (addr or '').strip()


def _who(user):
    """Identify the caller without assuming a fully-populated user."""
    return {
        'user_id': getattr(user, 'id', None),
        'account_id': getattr(user, 'account_id', None),
        'phone': getattr(user, 'phone', '') or '',
        'username': getattr(user, 'username', '') or '',
    }


def log_refusal(user, course_id, course_name, problems,
                served_from_catalog=False):
    """Record the event.  No phone number — see the module docstring.

    `served_from_catalog` distinguishes the two outcomes, because they are not
    the same incident: one golfer was blocked, the other got his course from a
    copy we already held while the upstream record stayed broken.  Both need
    fixing upstream; only one is urgent for the person.
    """
    w = _who(user)
    logger.warning(
        'CourseImportView %s: course_id=%s name=%r user=%s account=%s '
        'problems=%s',
        'SERVED-FROM-CATALOG' if served_from_catalog else 'REFUSED',
        course_id, course_name, w['user_id'], w['account_id'], list(problems),
    )


def refusal_email(user, course_id, course_name, problems,
                  served_from_catalog=False):
    """Compose (subject, body).  Pure — no sending, no settings beyond the address.

    The two outcomes get different words on purpose.  An email saying "a golfer
    could not add this course" about a golfer who DID add it is the kind of
    false line that makes an operator distrust the whole alert.
    """
    w = _who(user)
    if served_from_catalog:
        subject = f'Halved: upstream course data broken — {course_name}'
        head = [
            f'A golfer added "{course_name}" from OUR OWN catalog copy, '
            f'because the upstream record is broken.',
            '',
            'He was not blocked — but the upstream record still needs fixing,',
            'and our copy may be missing tees that have been added since.',
            '',
            'What is wrong upstream:',
        ]
    else:
        subject = f'Halved: course import refused — {course_name}'
        head = [
            f'A golfer could not add "{course_name}" to Halved.',
            '',
            'Why it was refused:',
        ]

    lines = list(head)
    lines += [f'  - {p}' for p in (problems or ['(no reason recorded)'])]
    lines += [
        '',
        'Who tried:',
        f'  user id    {w["user_id"]}',
        f'  account    {w["account_id"]}',
        f'  phone      {w["phone"] or "(none on file)"}',
        '',
        'Course:',
        f'  GolfCourseAPI id   {course_id}',
        f'  name               {course_name}',
        '',
    ]
    if served_from_catalog:
        lines += [
            'Fix the upstream record at GolfCourseAPI, then re-import to',
            'refresh the shared catalog.',
        ]
    else:
        lines += [
            'Nothing was written — the quality gate runs before any database',
            'write, so there is no course to clean up and no partial data in',
            'the catalog.',
            '',
            'To fix it: fill the missing data in upstream at GolfCourseAPI and',
            'have them search again, or have them paste the scorecard (Courses',
            '-> the paste-a-scorecard button), which stays private to their own',
            'account.',
        ]
    return subject, '\n'.join(lines)


def report_import_refusal(user, course_id, course_name, problems,
                          served_from_catalog=False):
    """Log the event, and email the operator at most once per course per day.

    Returns True when an email was actually sent.  Never raises: the caller is
    in the middle of returning a response the golfer needs to see, and a mail
    outage must not turn a clear refusal into a 500.
    """
    try:
        log_refusal(user, course_id, course_name, problems,
                    served_from_catalog=served_from_catalog)
    except Exception:          # pragma: no cover - logging must never fail a request
        pass

    addr = _alert_address()
    if not addr:
        return False

    key = f'course-import-refusal:{course_id}'
    try:
        # add() is atomic-ish and only succeeds when the key is absent, so the
        # first caller wins and the rest are silent.
        if not cache.add(key, 1, EMAIL_THROTTLE_SECONDS):
            return False
    except Exception:
        # A cache outage should not cost us the notification.
        logger.exception('course-import refusal throttle unavailable')

    subject, body = refusal_email(user, course_id, course_name, problems,
                                  served_from_catalog=served_from_catalog)
    try:
        send_mail(subject, body, settings.DEFAULT_FROM_EMAIL, [addr],
                  fail_silently=False)
        return True
    except Exception:
        # The 422 already went back to the golfer and is the part that matters.
        logger.exception('course-import refusal email failed for %s', course_id)
        return False
