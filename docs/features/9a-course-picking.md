# 9A — Course picking: "Suggested is not selected"

Status: **CONFIRMED — ready to implement.**
Source: design deck `Halved App.dc.html` turn 09 / 9a (the RECOMMENDED variant;
9b, the conservative pre-fill-with-confirm option, is NOT chosen), plus notes
from Paul's earlier (lost) implementation. Captured 2026-07-24.

## Problem

The home course is silently **pre-filled** into a field that looks identical to
a confirmed choice, so people tee off at the wrong course. A pinned home course
above a single recent both read as "already picked."

The pre-select bug lives in `casual_round_screen.dart` (~lines 201–204):
`if (_selectedCourse == null && homeCourseId != null) _selectedCourse = c;`
— and the collapsed `CourseSearchField` renders the selection as a plain filled
field, reinforcing "already chosen."

## 9a behavior

1. **Never pre-select.** Nothing starts selected; the **Next button stays
   disabled** until the user makes a real choice.
2. **Home course = an explicit suggestion**, not a selection. Its own card
   labelled "YOUR HOME COURSE" with a **"Play here"** affordance; tapping it
   selects.
3. **Chosen course = a distinct mint-checked "Playing today" card** with a
   **"Change"** action (replaces the current plain single-line collapsed field).
4. **Recents = pills matching the home-course look** (Paul's shipped version —
   this SUPERSEDES the deck's "plain list rows" note). Under a "RECENT" heading;
   tap to select. The home course is not repeated in recents.
5. **Search + recents always visible** so choosing elsewhere is one tap, not a
   hunt-and-edit.
6. **One flat search list.** No "in your courses" vs global split — drop the
   "In your courses" label and the source-hint trailing icons. Tap any result to
   pick it; cloning a catalog course / importing an API course (with tees)
   happens invisibly behind the selection. (Backend already unified via
   `CourseFindView` / `findCourses`.)
7. **After a course is chosen**, still show "OR SWITCH TO" (home + recents) so a
   one-tap switch is possible without re-searching.

## Where it applies

`widgets/course_search_field.dart` is the shared picker. Round-creation entry
points that use it and/or pre-select:
- `screens/casual_round_screen.dart` (has the pre-select — remove it)
- `screens/new_round_wizard.dart`
- `screens/onboarding_wizard.dart`
- (`confirm_tees_screen.dart`, `settings_screen.dart` also reference courses —
  confirm scope.)

## Resolved (confirmed with Paul)

- **Q1. Scope = FULL.** All round-creation entry points that use
  `CourseSearchField`: casual round, new-round wizard, and onboarding. Remove the
  pre-select and gate Next in each.
- **Q2. "OR SWITCH TO" = lighter treatment**, and **de-duplicated**: never show
  the course currently being played, and don't repeat the home course in recents.
- **Q3. Drop source hints entirely** — no "In your courses" label, no add/check
  trailing icons. A neutral flat list; tap picks, import is invisible.
- **Q4. Wording = per this spec** ("Play here" / "Playing today" / "Change").
  Paul's shipped wording differed slightly but isn't remembered; the spec wording
  stands unless a clearly better option surfaces.
