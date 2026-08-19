# Scripture Bridge — Backend Roadmap (scripture-bridge-db)

**Status:** Draft
**Companion:** `scripture-bridge-android-app/docs/roadmap.md` — same milestone numbering, different track
**Requirements:** [requirements.md](requirements.md) (referred to as **DB**), and the app's
requirements document (referred to as **APP**)
**Last updated:** 2026-08-11

---

## 1. How to Read This

Milestones **M0–M5** are shared between the two repositories. A milestone number means the same
point in the project in both. This document covers the backend track; the app track is in the
companion roadmap, and §4 lists where they block each other.

**No dates.** Durations depend on team size, which is not yet settled (§9). Each milestone
instead has **exit criteria** — observable, testable conditions — and a **relative size**. A
roadmap with invented dates is worse than one without, because the dates get quoted.

**Sequencing principle: the backend leads the app by roughly one milestone.** APP §20 #7 asks
whether a reference implementation of the API exists so app development can proceed in parallel.
This roadmap answers yes, and makes it a deliverable: at the end of M1 the app team has a
seeded, runnable local Supabase stack to build against, and app work is never blocked waiting for
a hosted environment.

---

## 2. Critical Path

```text
M0  decisions            ──►  M1  schema + RLS  ──►  M2  auth + save path
     (mostly not code)              │                      │
                                    │                      ├──► app M2 unblocked
                                    └──► app M1 can start   │
                                                            ▼
                                              M3  sync + history
                                                            │
                                                            ▼
                                              M4  review + workflow
                                                            │
                                                            ▼
                                              M5  field readiness ──► pilot
```

The three things that can stall this path, in order of likelihood:

1. **The web console has no owner** (§8). Without it nobody can create an account, a project,
   or an assignment — and the app deliberately has no administrative UI (APP §18.2). Dev-time
   scripts cover M1–M4; the pilot cannot happen without a console.
2. **Decisions in M0 that are immutable once made** — region, versification scheme. Both are
   cheap now and expensive after data exists.
3. **USFM round-trip fidelity** (DB R-USFM-2). It determines whether the MVP's vertical slice
   ends in output the partner organisation can actually publish.

---

## 3. Milestones

### M0 — Decisions and verification

**Size:** S (calendar time, not effort — most of this is asking people questions)
**Goal:** close the decisions that get more expensive after code exists.

| Item | Source | Why now |
|---|---|---|
| Confirm Postgres ≥ 15 on the provisioned project | DB §17 #1 | Three requirements depend on it |
| **Region / data residency** | DB §17 #3 | Cannot be changed after the project is created |
| **Versification scheme** for the first cohort | DB §17 #5 | Immutable per project; wrong choice surfaces at export |
| Verify refresh-token settings: rotation on, reuse interval ≥ 300 s, no inactivity timeout, no session time-box | DB §17 #2 / APP §20 #1 | The config most likely to lock a translator out irrecoverably |
| **USFM round-trip: sidecar markup or plain export?** | DB §17 #4 | Determines the shape of M5's export work |
| Amend APP §13.5 with the five new error codes | DB §17 #6 | The app's retry logic is wrong until this lands |
| Console ownership and whether it holds the service key server-side | DB §17 #7 | A browser-bundle console is not deliverable |

**Exit criteria**

- Every row above is answered in writing, and the requirements documents are updated in place
  rather than in a side channel.
- A Supabase project exists in the chosen region, on the chosen plan, with the auth settings
  verified by inspection rather than by assumption.

---

### M1 — Schema, reference data, and RLS

**Size:** L
**Goal:** a database that builds from zero and cannot be read by the wrong person.

**Work**

- Supabase CLI scaffolding; local stack; CI running `supabase db reset` on every commit
  (DB R-MIG-5).
- Schemas `app`, `api`, `ref`; PostgREST exposing `api` only; `public` emptied
  (DB R-SCHEMA-1..4).
- Reference data seeded: `ref.book_canon`, `ref.versification` for the chosen scheme
  (DB R-DATA-1/2).
- Core tables: `profile`, `project`, `project_member`, `book`, `chapter`, `verse`,
  `verse_revision`, `comment` (DB §5), with the NFC check constraints (DB R-TEXT-DB-1) and the
  `profile` indirection that keeps history alive through erasure (DB R-DATA-4).
- Project materialisation: creating a project writes books, chapters, and empty verse rows from
  the versification scheme (DB R-DATA-3).
- RLS enabled **and forced** on every table; helper functions; read and write policies
  (DB §6).
- pgTAP negative policy tests (DB R-TEST-1) and the CI guards for missing RLS and unpinned
  `search_path` (DB R-TEST-6).
- Dev provisioning scripts: create a user, a project, and an assignment with the service key —
  the stand-in for the console through M4.

**Exit criteria**

- `supabase db reset` builds a working database from zero in CI, seeded with one project and
  Matthew fully materialised.
- Negative policy tests pass: a non-member sees nothing; an unassigned translator cannot write;
  `authenticated` holds no DML on any table.
- **The app team can run the stack locally and point a client at it.** This is the deliverable
  that unblocks app M1/M2.

---

### M2 — Auth and the save path

**Size:** M
**Goal:** a translator can sign in and a verse can be saved, correctly, once.

**Work**

- Auth configuration: self-registration disabled, email/password only, no SMTP in the
  translator flow, 1-hour access tokens (DB §7.1).
- Admin provisioning through the GoTrue admin API, pre-confirmed, with the profile trigger
  (DB R-AUTH-DB-5/6).
- `must_change_password` defaulting true, cleared only by verified change, enforced **in RLS**
  rather than by app navigation (DB R-AUTH-DB-7/8).
- `rpc/me` returning profile, memberships, roles, and the flag in one round trip.
- `api` views for projects, books, chapters, and verses — `security_invoker`, explicit columns
  (DB R-RLS-13/14, R-TRANSPORT-5).
- **`save_verse_text`** in full: locking, last-write-wins, no-op on identical text, revision
  capture policy, NFC rejection, `chapter_locked`/`not_assigned` (DB §8.1, §8.2).
- Idempotency infrastructure and its application to the save path (DB §9).

**Exit criteria**

- Sign-in, forced password change, and silent refresh work against the hosted staging project.
- A saved verse increments `rev` once, captures a revision per policy, and returns the new state.
- A replayed `Idempotency-Key` returns the stored response and creates **no** second revision.
- Concurrency test passes: two simultaneous saves produce two distinct `rev` values, one final
  text, and both texts recoverable from history (DB R-TEST-2).

---

### M3 — History and delta sync

**Size:** L
**Goal:** an app that has been offline can catch up without losing anything.

**Work**

- `set_verse_status`, `restore_revision` (forward-only, implemented in terms of
  `save_verse_text` — DB R-FN-10).
- Revision immutability: no grants, plus the trigger that stops a future migration or a
  service-key script (DB R-FN-9).
- Revision list and detail views, paginated, newest first.
- `app.change_log` written inside every write function (DB R-SYNC-1/2).
- **`changes_since` with the `pg_snapshot_xmin` guard** (DB R-SYNC-3) — the piece of this
  project most likely to lose data silently if done the obvious way.
- Retention, watermark, and `cursor_expired` (DB §10.3).
- Counters and their triggers; the progress view; the reconciliation function
  (DB §5.7, R-PERF-4).
- `pg_cron` jobs for pruning, with outcome logging (DB R-OPS-6/7).

**Exit criteria**

- **The out-of-order commit test passes** (DB R-TEST-4): a transaction that takes a lower `seq`
  and commits later is never skipped by a cursor. Constructed deliberately — ordinary use will
  not find this. Lives in `supabase/tests/concurrency/run.sh`, which drives two real psql
  sessions; it carries a control assertion proving the race actually reproduced, so the test
  cannot pass vacuously.
- A cursor below the pruning watermark returns `cursor_expired`, not an empty page.
- Progress reads come from counters, and reconciliation reports zero drift against the scale
  fixture.

---

### M4 — Review loop and workflow

**Size:** M
**Goal:** the full assign → translate → review → approve cycle exists server-side.

**Work**

- `add_comment`, `flag_verse` (comment required — DB R-FN-12), `resolve_comment`.
- `submit_chapter` and `review_chapter`, validating against counters **and** re-verifying
  against source rows in the same transaction (DB R-FN-11).
- Workflow state machine validation with `invalid_transition` (DB R-FN-13).
- Admin-only chapter reopen (DB R-FN-14).
- The complete typed-error surface of DB §11.2, with the mapping tested end to end.
- `app.audit_log`, append-only, covering privileged operations and workflow transitions
  (DB §12.2).

**Exit criteria**

- A chapter cannot be submitted with an empty verse, nor approved with a flagged one, and both
  refusals arrive as typed codes rather than generic 500s.
- Every code in DB §11.2 is produced by a test that asserts both the code and the HTTP status.
- Every privileged operation appears in the audit log with actor and before/after values.

---

### M5 — Field readiness

**Size:** M
**Goal:** the things that are only discoverable under real conditions, done before real
conditions.

**Work**

- Font storage bucket, access policies, `sha256` integrity (DB §12.1).
- `consent_record` and `anonymise_profile`, with the erasure path tested to confirm history
  survives (DB §12.3, DB §17 #10).
- Project-wide search: trigram index, folded column, canonical ordering (DB §5.8).
- Rate limits and the `authenticated` statement timeout (DB §11.3).
- Scale fixture, indexes verified against it, `EXPLAIN` baselines committed
  (DB R-TEST-5, R-NFR-1/2).
- **PITR enabled and a restore drill actually performed** (DB R-OPS-1/2).
- Service-key rotation runbook; destructive-operation runbook (DB R-OPS-4, R-OPS-5).
- USFM export, in whichever shape M0 decided.

**Exit criteria**

- Every performance target in DB §15 met against the scale fixture, not the seeded book.
- A restore from PITR into staging has been done by a person, start to finish, and documented.
- Anonymising a profile leaves every revision, comment, and approval intact and readable.

---

### Pilot gate

Not a milestone — the condition for putting this in front of translators.

- One chapter travels assigned → translated → reviewed → approved → exported, and the USFM
  opens cleanly in the partner organisation's publishing tooling (APP §18.2).
- A console exists and a coordinator can provision an account, a project, and an assignment
  without a developer (§8).
- The device-fleet question (APP §20 #2) is answered, since `minSdk 33` is the app's
  highest-risk assumption and it is not a backend problem to solve.

---

## 4. Cross-Repo Dependencies

| This repo delivers | Which unblocks |
|---|---|
| M1 — runnable seeded local stack | App M1/M2: the app builds and integrates against something real from the start |
| M2 — auth config and `save_verse_text` | App M2: sign-in, forced password change, first end-to-end save |
| M2 — idempotency | App M3: the outbox cannot be built honestly without it |
| M3 — `changes_since` | App M3: delta sync, and therefore the whole offline story |
| M3 — revision views and `restore_revision` | App M3: history list and restore |
| M4 — workflow RPCs and typed errors | App M4: review queue, submit/approve, and the app's error handling |
| M5 — font storage | App M5: per-project fonts for Class D scripts |

| This repo needs | From |
|---|---|
| APP §13.5 amended with five error codes | App repo, M0 |
| First-cohort languages and script classes | Project decision, M0 — determines the versification scheme and which fonts are uploaded |
| Console with a server-side service key | Unowned (§8) — hard requirement at the pilot gate |

---

## 5. Post-MVP

In roughly the order the requirements documents justify, not a commitment:

- **Optimistic concurrency** (APP §19, §7.3), if field use shows genuine concurrent editing.
  The write counter already exists; the change is a `base_rev` parameter, a rejection code
  carrying current text and author, and one screen. Deliberately a contract change
  (DB R-FN-3), not a quiet addition.
- Background sync hardening once real sync intervals are known, and a revisit of the 7-day and
  90-day retention windows against measured behaviour (DB §17 #9).
- Realtime, if push notifications are taken up (APP §19) — with its own authorisation review,
  since Realtime's RLS path is not covered by the policy tests (DB R-SYNC-10).
- Key-term glossary and consistency checking (APP §19). Needs its own tables and its own
  design; do not pre-build a partial version.
- Multi-project query tuning, once the app supports multi-project.

---

## 6. Risk Register

| Risk | Impact | Where it bites | Mitigation |
|---|---|---|---|
| Console unowned | No accounts, projects, or assignments; pilot impossible | Pilot gate | Dev scripts carry M1–M4; escalate ownership during M0 |
| Refresh-token config wrong | Translator locked out irrecoverably in the field | Pilot | Verified in M0, re-verified in M2 against staging |
| Delta-sync cursor implemented naively | Silent permanent staleness, no error anywhere | M3 | R-TEST-4 constructs the failure deliberately |
| USFM round-trip undecided | MVP produces output the publisher cannot use | M5 | Forced to a decision in M0 |
| Service key leaks into a client bundle | Full compromise of every project's data | Any | DB R-RLS-3; console architecture reviewed in M0 |
| Counters drift from source | Chapter approved on a stale count; needs admin reopen | M3+ | Reconciliation function, weekly job, CI check |
| `minSdk 33` fleet assumption wrong | App unusable on field devices | Pilot | Not a backend risk, but it invalidates the pilot; tracked here because it invalidates this plan too |

---

## 7. Ways of Working

- Migrations forward-only and linear; never edited after reaching staging (DB R-MIG-2).
- No schema changes through the dashboard in staging or production (DB R-SCHEMA-4).
- Additive-only during a release window, because old app versions persist in the field
  (DB R-MIG-3).
- Production data never copied to staging or a developer machine (DB R-OPS-3).
- A new table without RLS fails CI. A new `SECURITY DEFINER` function without a pinned
  `search_path` fails CI (DB R-TEST-6).

---

## 8. Unowned Work

**The web console is a third deliverable with no repository and no owner.** It is not optional:
APP §18.2 removes all administrative UI from the app, so project creation, user management,
role and chapter assignment, password reset, chapter reopen, and USFM import/export exist
nowhere else.

- M1–M4 are covered by service-key dev scripts in this repo.
- **The pilot gate cannot be met without a console**, because a coordinator must provision
  accounts and assignments without a developer, and password reset (APP R-AUTH-7) is the only
  thing standing between a translator and permanent lockout.
- It requires a server-side component to hold the service key (DB R-RLS-3). A pure client-side
  console is not a deliverable shape here.

Resolving this is the highest-value thing that can happen during M0.

---

## 9. Sizing

Relative sizes are given per milestone; absolute duration needs the team shape, which is open:

- How many backend engineers, and are they shared with the console?
- Is the app team distinct, and can the two tracks genuinely run in parallel?
- Is the pilot date externally fixed (a translation workshop, a partner commitment)? If so,
  scope moves, not the milestone order — and M5 is where scope is cut from, never M1's RLS
  tests or M3's cursor guard.
