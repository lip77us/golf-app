# When to raise the client floor

`CLIENT_MIN_VERSION` hard-blocks every phone below it: a non-dismissible
dialog, no way into the app, an App Store trip for every user at once. It is
the bluntest instrument in the codebase, so the useful question is not "when
do I bump it" but "what would make me have to".

**It has not moved since 2.1.0, and that is a result, not neglect.** Nearly
every server change here is additive and degrades on its own.

`SERVER_VERSION` is a different thing that happens to sit beside it: nothing
reads it but the About dialog, nothing parses it, and it never needs bumping.
Do not conflate the two.

---

## The rule

> **Raise the floor only when an old client would be WRONG — not when it would
> merely be missing something.**

Missing is the normal case and needs no gate. An old phone that does not know
about a new field draws one fewer row, one fewer tab, one fewer chip. Nothing
it *does* show is false.

Wrong is the case that needs a gate: the client renders a number, and the
number means something else now.

---

## What actually qualifies

### 1. A key changes meaning or type under the same name

The dangerous one, because it fails silently in the direction of looking fine.

A real near-miss, 23 Sep 2026: `field_standing` carries a stroke tournament's
`net_to_par` and a Stableford tournament's `points`. Reusing one key would
have had an old client print a points total as a score against par — **roughly
its opposite**, with no error anywhere. A `metric` discriminator was added
instead, so one key never means two shapes and the floor did not have to move.

A real hit, earlier: `allowance` was a worked block on a team row and a plain
int on a round, and merging the two dicts replaced one with the other. The
Dart client died casting an int to a map. *"A payload key that is a map on one
path and a list on another"* is the phrase in `CLAUDE.md`; `golfers_by_hole`
returns `[]` rather than `{}` for a scramble for exactly this reason.

**Prefer versioning the KEY over versioning the CLIENT.** It costs one field
and locks out nobody.

### 2. A write contract changes, so an old client's POST stores the wrong thing

Not a crash — a lie written to the database.

`zombie_option` is the worked example. Its default flipped to true, and the
client **always sends it explicitly**, so a 2.7.0 phone keeps posting `false`
from its own screen default. The server cannot tell that from a TD deliberately
turning it off, and should not try. Had absence started meaning `true`, every
old phone would have silently opted its round in.

### 3. A removal the client dereferences without a guard

Deleting a key, or an endpoint on a critical path. Usually safe here because
`fromJson` defaults everything — when `effective_handicap_index` and
`handicap_is_authoritative` were removed end to end, the note reads: *"safe for
the shipped 2.1.0 client — its `fromJson` defaults the missing keys to
`''`/`false`, which degrade to exactly the new behavior."* That is the
sentence you want to be able to write. If you cannot, you have found a gate.

### 4. A scoring rule change that moves money under a cached screen

Not an API shape at all. If the same round now settles differently, two phones
on different builds show two answers to one question. Rare, and worth a gate
when it happens.

---

## What does NOT qualify

Everything else, and it is most things. From one day's work, all additive and
all shipped without touching the floor:

- `field_standing`, `player_ids`, `standing`, `scoring` — new keys on existing
  payloads; absent means the client draws no row.
- `holes_to_play` — present, the client uses it; absent, it falls back.
- The Stableford points tab on a round board — a new tab key, appended to
  `active_games`; a client that tabs off that list gains one.
- Ten new watch pages — server-rendered, no client involvement at all.

---

## The practical shape

1. **Add keys, never repurpose them.** A new name costs nothing; a reused one
   costs a forced update.
2. **Give every new field a client default that reproduces the OLD behaviour.**
   That is what makes the server deployable ahead of the app, which is the
   ordering this project actually uses.
3. **If you must break, version the key.** `metric`, not a floor.
4. **If you must raise the floor, raise it to the build that SHIPPED the
   handling** — not to the latest. Raising to "current" locks out users who
   would have been fine.
5. **Deploy the server first, always.** An old app against a new server is the
   designed state. A new app against an old server is the one that shows
   nothing and looks broken — which is why an App Store build should not go
   for review before its server half is live.

## What enforces this — `mobile/test/api_compatibility_test.dart`

Two things, and the shape of them is worth reading before adding a third.

**1. An unknown key changes nothing — all 159 models, no exemptions.** The
server adds a field; a phone built before it existed must behave exactly as it
did. Every model is built twice, with and without a junk key, and the
OUTCOMES are compared — so the models that legitimately reject a payload take
part too: they must fail the same way, not a new way. The registry is checked
against the source, so a model added without an entry fails rather than being
quietly skipped.

**2. Every field designed to be absent degrades to its documented default** —
written one at a time, each with the reason. A default is only correct against
a specific shipped behaviour, so a loop over them would assert the shape and
lose the argument. `FieldPlace.metric` is the one to look at first: it is the
discriminator that keeps one key from meaning two things, and getting it wrong
prints a points total as a score against par.

### The test this doc originally asked for was the wrong one

It said to construct every model from `{}`. Measuring that is what showed why
it is wrong: **80 of the 159 refuse an empty map**, every one of them on an
identity field. `PlayerTotals.playerId` is `j['player_id'] as int` with no
default while every optional field beside it carries `?? 0` — which is the
model written *correctly*. A player row with no `player_id` is not a payload
any server sends, and a test demanding tolerance there needs eighty
exemptions, which is a list nobody maintains.

The bar that matters is not "survives nothing". It is "survives a server that
knows more than it does".

### Still not enforced

One key meaning two shapes on two paths — the `allowance` defect — is caught
by reading, not by tooling. Nothing compares a payload's shape between the
code paths that emit it.
