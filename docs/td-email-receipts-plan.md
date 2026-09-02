# TD email receipts — scope

**Status: not started. Scoped 2026-09-02, to be built later.**

The personal receipt has been composed server-side since `6d7ad19` and has
never had a way out. SMS was the assumed transport and it dead-ends: Halved
deliberately never sends golfer-facing SMS from the server, the native share
sheet cannot open fourteen threads in one tap, and **10DLC is ruled out**.

Email replaces it. A TD sends every golfer his own receipt, from the TD portal,
in one action.

---

## Why email is the better answer, not just the available one

- **No carrier registration.** No 10DLC, no per-message cost, no TCPA
  exposure from app-initiated bulk SMS to people who never opted in.
- **A receipt is a document, not a notification.** It gets kept, searched,
  forwarded to the man who disputes a skin. Email threads; SMS doesn't.
- **Bulk is one server call**, not fourteen share sheets.
- **The length constraint disappears.** `compose_personal` compresses entries
  into `Entries (3) -$30` *only* because of GSM-7 segments. Email can itemise
  every line. The whole `sms_segments` apparatus — the amber-over-three
  warning, the non-GSM character policing — is irrelevant on this path.

---

## What already exists

| Piece | Where | State |
|---|---|---|
| Transactional email | `my_golf_app/settings.py:367` | Resend SMTP configured; console backend when no API key, so dev never reaches out |
| `send_mail` precedent | `console/views.py:535` | Course reports already email through it |
| TD web auth | `console/auth.py:189` | `@td_required`, phone + OTP, same credential as the app |
| Admin write gate | `console/views.py:155` | `_can_write` → `is_account_admin` |
| Per-golfer message bodies | `services/settlement_receipt.py:186` | `receipt_payload` already composes one per golfer |
| Per-golfer send stamps | `tournament/models.py` | `SettlementSend.player` + `MODE_PERSONAL` (added 2026-09-02) |
| `Player.email` | `core/models.py:252` | Field exists |

Nothing about the money, the gate, or the message bodies needs rewriting. This
is a transport and a surface.

---

## The real cost: the console has no tournament surface

`console/urls.py` routes **roster import and courses only**. There is no
tournament list, no tournament page, no settlement view anywhere in the portal.

So this is not "add a button to the TD portal". It is the portal's first
tournament surface, and that is the bulk of the work:

1. **Tournament list** — settle-able tournaments for this account. Probably
   filtered to ones with money, newest first; a TD with four years of events
   does not want all of them.
2. **Settlement page** — the console's version of
   `tournament_settlement_screen.dart`. A 14-row table is what the console is
   *for*; this is the part that genuinely reads better on a laptop than on a
   phone.
3. **The send flow** below.

Worth deciding early whether steps 1–2 are scoped as their own piece. They have
value without the email send (settlement on a real screen), and the email send
has no value without them.

---

## The constraint that has to be visible: 57% email coverage

Of 316 real (non-phantom) players in the local database, **181 have an email
address (57%)**. 237 have a phone (75%).

A TD who presses "email the field" on a 14-man tournament will silently reach
eight people. That must be **named before the send, not discovered after it** —
the same principle as the existing `excluded_note`, and the same principle the
roster import already follows.

The preview names them:

> **12 of 14 will get this.** Petersen and Gunst have no email on file — add
> one, or hand them a copy from your phone.

Two golfers named is actionable. "12 of 14" alone is not.

---

## Flow: the preview IS the confirm

Inherited wholesale from the roster import, which settled this shape already
(`CLAUDE.md` §Phase 2). No dialog, and the primary button carries counts:

```
Email 12 receipts
```

not `Send`.

**Preview page** — one row per golfer:

| | |
|---|---|
| Name, net | `Petersen  +$45` |
| Where it goes | `pete@example.com`, or `no email on file` in the skip style |
| Already sent? | `Texted 6:12 PM` / `Emailed 6:12 PM` from the per-golfer stamp |
| The message | Expandable, exactly what he will receive |

Golfers with no email are greyed and inert, exactly like the import's file
errors — not editable inline, because fixing an address belongs in the roster,
not here.

**Receipt page** — what actually went, per golfer, with the address it went to.

---

## Model changes

`SettlementSend` already carries mode (`field` / `personal`), recipients, the
player, who sent it and when. Two additions:

- **`channel`** — `share` | `email`. Not `sms`: the app has never sent an SMS,
  it hands a string to the native share sheet and the human sends it. Naming
  the existing rows `share` keeps that honest. Default `share` for the
  backfill.
- **`to_email`** — the address it was sent to, snapshotted. Addresses change,
  and "which address did it go to" is exactly what gets asked when someone says
  they never got it. Deriving it later from the roster answers the wrong
  question.

**A bulk send writes N rows, one per golfer**, in one transaction — reusing the
per-golfer stamp work rather than inventing a batch record. That is what makes
"have I sent Ben his yet" answerable after a partial send, and what makes a
resend to one man a first-class act.

No new model. No migration beyond those two fields.

---

## Composition

A new `compose_personal_email` — **not** a re-use of `compose_personal`.

- **Itemise fully.** Every entry line, not `Entries (3)`. The compression was
  a segment-budget decision and there is no segment budget here.
- **Plain text first.** The console already sends plain `send_mail`; HTML is a
  second pass, and a plain receipt is never wrong.
- **Reply-To is the TD, not `noreply@halved.golf`.** A golfer disputing a skin
  must be able to press reply and reach a person. This is the single most
  important detail in the whole feature and the easiest to leave out.
- **Subject** carries the outcome: `Tilden Park Invitational — you collect $45`.
  It shows in a lock-screen preview, which is where most of these get read.
- **Self-contained, no app link.** Same rule the SMS composition already
  follows: readable by a man who has not installed Halved.

---

## Gates and rules it inherits

- **`can_send` IS `can_settle`** (rule 6). Provisional money must not leave the
  app. Already true of `receipt_payload`; the console must not weaken it.
- **The server refuses, not just the button.** `POST` while blocking returns
  400 with the reasons, as `TournamentReceiptView` already does.
- **One transaction, `select_for_update` on the tournament.** A double-submit
  must not send 24 emails. The import already solves this exact problem.
- **The receipt must never claim something that did not happen.** The hardest
  lesson of the import build was a receipt that said "row 89 was imported"
  about a row that wasn't. A send row is written *after* the send is accepted,
  per golfer — never optimistically for the whole field.

Console gotchas, already paid for once:

- `{# … #}` is single-line only; use `{% comment %}` blocks.
- `collectstatic` is required at deploy — `{% static %}` raises at render.

---

## Open decisions

1. **Is CAN-SPAM satisfied?** A receipt for a bet the recipient played in reads
   as transactional/relationship content rather than commercial, which is the
   category that does not require an unsubscribe link. Worth confirming
   properly rather than assuming — it is the email analogue of the TCPA
   question that killed the SMS path, and the same instinct that was right
   there applies here. **I am not the right source for this one.**
2. **Reply-To exposes the TD's email address to the whole field.** Correct for
   a club event; confirm it is correct for every event.
3. **Who may send?** `_can_write` (`is_account_admin`), or anyone signed in who
   runs the event? Settlement money is more sensitive than a roster.
4. **Casual rounds too?** They work phone-side today and the group message is
   the useful one for a four-ball. Email may still be wanted for the man who
   keeps records. Not required for v1.
5. **Bounce tracking.** SMTP acceptance is not delivery. Real bounce handling
   needs Resend webhooks — probably a later slice, but it decides whether the
   receipt can claim "delivered" or only "sent".

---

## Explicitly out of scope

- 10DLC and any bulk SMS. Ruled out.
- Golfer-side email preferences.
- Anything that lets a golfer pull his own receipt — a different feature that
  would answer the handoff's second open question, and not this one.
