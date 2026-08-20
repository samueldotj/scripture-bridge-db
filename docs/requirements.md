# Scripture Bridge — Database and Backend Requirements (Supabase)

**Status:** Draft
**Scope:** The backend that satisfies §13 of the Android application requirements, implemented on Supabase
**Companion document:** `scripture-bridge-android-app/docs/requirements.md` (referred to below as **APP**)
**Last updated:** 2026-08-11

---

## 1. Purpose and Relationship to the App Document

APP §1.2 deliberately leaves the database engine, schema, indexes, migrations, query design,
authorisation enforcement, backup, and export mechanics unspecified, and requires only that
the backend satisfy the API contract in APP §13. **This document makes those decisions.** It
specifies a Supabase implementation and is the requirements document for the
`scripture-bridge-db` repository.

### 1.1 This document specifies

- The Postgres schema, constraints, and indexes.
- How every APP §13 operation is served, and by what mechanism.
- Row Level Security (RLS) as the authorisation mechanism (APP R-API-5).
- Auth configuration, account provisioning, and session behaviour (APP §14.3).
- Delta-sync change tracking (APP R-OFF-7, §13.4).
- Idempotency (APP R-OFF-4, §13.3), revision capture policy (APP R-REV-4), and the
  typed error model (APP §13.5).
- Migrations, environments, backups, retention, and operational ownership.
- The administrative surface the app does not use (APP §13.6) at the data layer.

### 1.2 This document does not specify

- The web console's UI. It specifies the data operations the console needs, not its screens.
- The Android application. Where this document constrains the app, it does so only by
  fixing the transport shape its API-client module must target (§3).
- USFM parsing and rendering rules beyond the storage model they require (§14).

### 1.3 Standing constraints inherited from APP

These are not restated as new requirements; they bind this document directly.

| APP requirement | Effect here |
|---|---|
| R-API-5 | Authorisation is enforced server-side on every operation, with no trust in client-supplied role. §6 |
| R-API-3 | All timestamps server-assigned. Client clocks never determine ordering. §5.9, §8 |
| R-CON-1/2 | Last write wins; overwritten text survives in revision history. §8.1 |
| R-REV-1/4 | Revisions immutable; capture policy decided server-side. §8.2, §8.3 |
| R-LEGAL-2 | Erasure of a user must not destroy translation history. §5.2, §12.3 |
| R-SEC-1 | No privileged key ever reaches the app. §6.1, §11.1 |
| R-AUTH-3/5 | Sessions persist indefinitely; refresh must survive a lost response. §7.3 |
| R-TEXT-1 | Text is NFC on the wire and at rest. §5.5 |

---

## 2. Platform Decision and Its Consequences

Supabase is assumed. That is not a neutral choice, and the consequences below drive most of
the rest of this document.

**What Supabase provides that this project needs:**

- Postgres with RLS, which lets APP R-API-5 be enforced by the storage engine rather than by
  application code that must be audited endpoint by endpoint.
- GoTrue (Auth) with admin-provisioned accounts, no self-registration, and long-lived
  rotating refresh tokens — a direct fit for APP §14.3.
- PostgREST, which turns tables, views, and functions into an HTTPS/JSON API without a
  bespoke server, meeting APP R-API-1/2/4/6 out of the box.
- Storage for font assets (APP R-FONT-3).
- Managed backups and point-in-time recovery, which APP §1.2 assigns to the backend.

**What it does not provide, and must therefore be built here:**

| Gap | Section |
|---|---|
| APP §13's literal URL paths do not exist on PostgREST | §3 |
| Idempotency keys | §9 |
| Revision-capture policy and workflow validation as atomic server-side operations | §8 |
| A gap-free delta-sync cursor | §10 |
| Typed error codes mapped to HTTP status | §11.2 |
| Precomputed progress | §5.7 |

- **R-PLAT-DB-1.** Postgres **15 or later**. Three features below this floor would each have to
  be worked around: `security_invoker` views (§6.4), `NORMALIZE`/`IS NORMALIZED` (§5.5), and
  `pg_current_xact_id()`/`pg_snapshot_xmin()` (§10.2). Supabase's current default is at or
  above this; confirm the version of the project actually provisioned (§17 #1).
- **R-PLAT-DB-2.** A paid tier is required before pilot, not before development. Point-in-time
  recovery (§13.2) and the absence of project pausing are the reasons; free-tier projects pause
  after inactivity, which is disqualifying for a field pilot. Development and CI may run on the
  local stack and the free tier.
- **R-PLAT-DB-3. Region: India (`ap-south-1`, Mumbai).** *(Decided.)* A data-residency
  decision (APP §2.4), and immutable: Supabase projects cannot change region after creation, so
  changing it means a new project and a data migration. Confirm it is still the closest offered
  region when the project is created — the list grows.
  Two consequences follow. Scheduled maintenance windows are chosen in IST rather than UTC
  (`scripts/schedule-jobs.sql`), because a window picked in UTC lands in the working day of the
  people affected. And India's DPDP Act is the governing personal-data regime: the obligations
  this schema already carries are consent capture (R-COMPLY-1) and erasure that preserves
  translation history (R-COMPLY-2, tested in `07_erasure.sql`). Whether anything further is
  required is a question for the project's own legal advice, not an engineering decision.

---

## 3. How the App Reaches the Data

### 3.1 Decision

APP §13 specifies REST paths such as `POST /verses/{id}/text`. PostgREST does not serve those
paths. APP §13 opens with: *"any equivalent transport is acceptable provided the semantics
hold."*

- **R-TRANSPORT-1. The app talks to Supabase directly** over generic HTTPS — PostgREST for
  reads, Postgres functions (`POST /rest/v1/rpc/<fn>`) for writes, GoTrue for auth, Storage
  for fonts. **No gateway service is built.**
- **R-TRANSPORT-2.** The mapping from APP §13's operation names to these endpoints lives
  entirely in the app's single API-client module (APP R-AGN-2). No Supabase-shaped type may
  reach the app's domain, repository, or UI layers, and no Supabase SDK may be used
  (APP R-AGN-1) — the endpoints are ordinary HTTPS/JSON and require no vendor library.
- **R-TRANSPORT-3.** This document is the authority on request and response shapes. Where a
  shape here differs from APP §13's illustration, the app's API-client module adapts; the
  **semantics** in APP §13 are binding on this document and may not be adapted away.

**Rejected alternative: an Edge Function façade implementing APP §13 verbatim.** It buys
literal path fidelity and costs a second deployable, a second authorisation surface to audit,
cold-start latency on every save from a device already on a poor connection, and a place for
business logic to drift away from the constraints that enforce it. The path shapes are an
implementation detail of one Kotlin file. Not worth a tier of infrastructure.

**Consequence to accept:** the app cannot be pointed at an arbitrary conformant backend
without editing that module. APP R-AGN-2 already scopes that to one module, which is the
guarantee that actually matters.

### 3.2 Operation mapping

| APP §13 operation | Served by |
|---|---|
| `POST /auth/login` | `POST /auth/v1/token?grant_type=password` |
| `POST /auth/refresh` | `POST /auth/v1/token?grant_type=refresh_token` |
| `POST /auth/logout` | `POST /auth/v1/logout` |
| `POST /auth/password` | `PUT /auth/v1/user` |
| `GET /me` | `POST /rest/v1/rpc/me` (§5.2 — combines profile, memberships, roles, and the must-change-password flag in one round trip) |
| `POST /verses/{id}/text` | `rpc/save_verse_text` |
| `POST /verses/{id}/status` | `rpc/set_verse_status` |
| `POST /verses/{id}/restore` | `rpc/restore_revision` |
| `POST /verses/{id}/comments` | `rpc/add_comment` |
| `POST /verses/{id}/flag` | `rpc/flag_verse` |
| `POST /comments/{id}/resolve` | `rpc/resolve_comment` |
| `POST /chapters/{id}/submit` | `rpc/submit_chapter` |
| `POST /chapters/{id}/review` | `rpc/review_chapter` |
| All `GET` collection reads | `GET /rest/v1/<view>` against the `api` schema (§6.4) |
| `GET /projects/{id}/changes?since=` | `rpc/changes_since` (§10) |
| `GET /projects/{id}/search?q=` | `rpc/search_verses` (§5.8) |
| `GET /fonts/{id}` | Supabase Storage object URL (§12.1) |

- **R-TRANSPORT-4.** Every write is an RPC. No table is directly writable by the
  `authenticated` role (§6.2). This is what makes "the server decides history policy"
  (APP R-REV-4) and "authorisation is server-side" (APP R-API-5) true by construction rather
  than by convention.
- **R-TRANSPORT-5.** Reads go to views, never to base tables, so that column additions and
  internal restructuring do not break deployed clients (APP R-PLAT-1 implies a long tail of
  un-updated app versions in the field).

---

## 4. Schema Organisation

- **R-SCHEMA-1.** Three schemas with distinct roles:

  | Schema | Contents | Exposed via PostgREST |
  |---|---|---|
  | `app` | All base tables, all internal helper functions | **No** |
  | `api` | Views and RPC functions the app and console call | Yes |
  | `ref` | Immutable reference data: canonical books, versification (§5.1) | No (read through `api` views) |

- **R-SCHEMA-2.** PostgREST's exposed-schema setting lists `api` **only**. `app` and `ref` are
  not reachable over HTTP even if a policy is later misconfigured. This is defence in depth,
  not a substitute for RLS.
- **R-SCHEMA-3.** `public` is left empty and `CREATE` on it is revoked from `PUBLIC`. Anything
  landing in `public` is a mistake, and an empty schema makes that visible.
- **R-SCHEMA-4.** No object is created through the Supabase dashboard's table or SQL editor in
  staging or production. Every object exists because a migration created it (§13.1). A schema
  that drifts from its migrations cannot be rebuilt, and rebuilding is how staging is refreshed.

---

## 5. Data Model

Column lists below are the substantive ones; every table also carries `created_at timestamptz
not null default now()` and, where mutable, `updated_at` maintained by trigger.

### 5.1 Reference data (`ref`)

- **R-DATA-1.** Canonical book and versification data is **reference data, seeded and
  version-controlled**, not per-project user input.

```
ref.book_canon      code (PK, USFM 3-letter: GEN, MAT, REV), name_en, sort_order,
                    testament, canon_section, chapter_count
ref.versification   scheme, book_code, chapter_number, verse_count
                    PK (scheme, book_code, chapter_number)
```

- **R-DATA-2.** At least one versification scheme is seeded and named explicitly. Verse counts
  differ between schemes — Psalm superscriptions, the Greek and Hebrew numbering of several
  Psalms, the ending of Malachi and Joel, and 3 John — and a project that picks the wrong one
  discovers it at export, after translation. The scheme is fixed **per project** at creation
  and is thereafter immutable (§5.3).
- **R-DATA-3.** Project creation materialises books, chapters, and empty verse rows from the
  chosen scheme, so a verse row exists before anyone types into it. The app never creates a
  verse; it only writes text into one. This makes assignment, progress, and the "chapter has
  empty verses" rule (APP R-WF-1) simple counting queries rather than absence-of-row
  inferences.

### 5.2 Identity

```
app.profile         id uuid PK default gen_random_uuid()
                    auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL
                    display_name text                  -- NULL once anonymised
                    anonymised_at timestamptz
                    must_change_password boolean not null default true
                    created_by uuid REFERENCES app.profile(id)
```

- **R-DATA-4. Content tables never reference `auth.users` directly.** They reference
  `app.profile`. Erasing a user's personal data (APP R-LEGAL-2) deletes or detaches the
  `auth.users` row and nulls `display_name`; the profile row survives, so every revision,
  comment, and approval keeps a stable author reference. A foreign key from revisions to
  `auth.users` with `ON DELETE CASCADE` would destroy translation history on an erasure
  request — the exact outcome R-LEGAL-2 forbids — and one with `ON DELETE RESTRICT` would make
  erasure impossible. The indirection resolves both.
- **R-DATA-5.** A profile with `anonymised_at` set is returned by every read API with
  `display_name: null`. The app renders "Former contributor" (APP R-LEGAL-2). Views must not
  filter these rows out; a missing author is worse than a tombstoned one.
- **R-DATA-6. The must-change-password flag lives in this table, not in user metadata.**
  APP R-AUTH-6 suggests user metadata. On Supabase, `raw_user_meta_data` is **writable by the
  user themselves** through the auth API, so a flag stored there can be cleared by the account
  it constrains, defeating the forced password change. The alternative is `raw_app_meta_data`,
  which is service-key-only and would also work; a table column is chosen because it is
  visible to SQL, testable, and returned by `rpc/me` alongside everything else the app needs at
  sign-in. Clearing it is a privileged operation (§7.4).

### 5.3 Projects and membership

```
app.project         id uuid PK, name, language_name, language_code, script_code,
                    text_direction ('ltr'|'rtl'), versification_scheme,
                    font_id uuid REFERENCES app.font(id),
                    font_size_sp int, line_height_multiplier numeric,
                    archived_at timestamptz

app.project_member  project_id, profile_id, role ('admin'|'translator'|'reviewer'),
                    PK (project_id, profile_id)
```

- **R-DATA-7.** Role is a property of (user, project) (APP §4.3). There is no global role
  column anywhere. A "platform administrator" is a console operator holding the service key
  (§7.4), not a row in this table.
- **R-DATA-8.** `versification_scheme` is immutable after creation, enforced by trigger.
  Changing it would orphan or duplicate verse rows that already hold translated text.
- **R-DATA-9.** Projects are archived, never deleted, from the console. Deletion of a project
  containing translation work must require a deliberate, separately-authorised operation
  (§13.4), not a `DELETE` that any admin session can issue.

### 5.4 Content

```
app.book            id uuid PK, project_id, code REFERENCES ref.book_canon(code),
                    name, sort_order, chapter_count
                    UNIQUE (project_id, code)

app.chapter         id uuid PK, book_id, number int, verse_count int,
                    assigned_translator_id, assigned_reviewer_id,   -- → app.profile
                    workflow_state ('not_started'|'in_progress'|'in_review'|'approved'),
                    submitted_at, approved_at, approved_by_id,
                    counters (§5.7)
                    UNIQUE (book_id, number)

app.verse           id uuid PK, chapter_id, number int,
                    text text not null default '',
                    rev int not null default 0,
                    status ('empty'|'draft'|'done'|'flagged'),
                    last_modified_by_id, last_modified_at timestamptz,
                    unresolved_comment_count int not null default 0
                    UNIQUE (chapter_id, number)

app.verse_revision  id uuid PK, verse_id, rev int, text text not null,
                    author_id, created_at, note text,
                    restored_from_revision_id uuid REFERENCES app.verse_revision(id)
                    UNIQUE (verse_id, rev)

app.comment         id uuid PK, verse_id, author_id, body text not null,
                    resolved_at, resolved_by_id
```

- **R-DATA-10.** `verse.rev` is a **per-verse counter**, incremented inside
  `save_verse_text` (§8.1). It is not a sequence, not a transaction id, and not global. APP
  §5.1 is explicit that it is neither a concurrency token nor a history sequence number, and
  nothing in this schema may quietly give it either meaning.
- **R-DATA-11.** `verse.status` is derived from text and flags but stored, because APP R-WF-1
  and progress (§5.7) query it constantly. It is maintained only by the write functions of §8;
  no other code path may set it.
- **R-DATA-12.** `verse.text` defaults to the empty string, never NULL. Three-valued logic on
  the single most-read column in the system buys nothing; `status = 'empty'` carries that
  meaning explicitly.

### 5.5 Text integrity

- **R-TEXT-DB-1.** `app.verse.text` and `app.verse_revision.text` carry
  `CHECK (text IS NFC NORMALIZED)`. APP R-TEXT-1 requires NFC end to end and requires that a
  round trip be a no-op; a database that silently accepts NFD makes that promise
  unverifiable. Postgres enforces it natively, so it costs one clause.
- **R-TEXT-DB-2.** The API **rejects** non-NFC text rather than normalising it. Normalising on
  write would mean text returned by a read differs from text just sent, breaking the round-trip
  guarantee the app depends on for its dirty-state tracking. The typed error is
  `text_not_normalized` (§11.2).
- **R-TEXT-DB-3.** No server-side operation may slice, truncate, or index into verse text by
  character or byte position. Grapheme-cluster correctness (APP R-TEXT-3) is guaranteed by ICU
  on the client; Postgres has no equivalent, so the database's role is to store text opaquely.
  Search (§5.8) is the one exception and is constrained accordingly.
- **R-TEXT-DB-4.** `CHECK (length(text) <= 4000)` on verse text. Not a linguistic limit — it is
  a bound on what a malfunctioning client can push into a row that is replicated into revision
  history on every write.

### 5.6 Fonts

```
app.font            id uuid PK, name, script_code, storage_path, file_size_bytes,
                    sha256, license, version
```

- **R-DATA-13.** Font binaries live in Storage (§12.1); this table is metadata plus the
  integrity hash the app verifies after download.

### 5.7 Progress counters

- **R-PERF-1.** Progress (APP §8.3, `GET /projects/{id}/progress`) is served from **maintained
  counters**, not from `count(*)` over verses. A full-Bible project is ~31,000 verse rows;
  aggregating them on every progress screen render, from a device on a metered connection that
  polls, is the query that will eventually dominate the instance's load.
- **R-PERF-2.** `app.chapter` carries `verses_empty`, `verses_draft`, `verses_done`,
  `verses_flagged`. They are maintained by trigger on `app.verse` status transitions, inside the
  same transaction as the write.
- **R-PERF-3.** Book- and project-level progress aggregates over chapter counters — hundreds of
  rows, not tens of thousands — and needs no further denormalisation. Do not add a second
  counter tier; two levels of trigger-maintained denormalisation is where these designs start
  disagreeing with themselves.
- **R-PERF-4.** A `SELECT`-based reconciliation function recomputes all counters from source and
  reports discrepancies. It runs in CI against the seeded fixture and is available to operators.
  Counters drift; the question is only whether drift is detectable.

### 5.8 Search

- **R-SEARCH-DB-1.** Project-wide search (APP R-SEARCH-2) uses **trigram matching**
  (`pg_trgm`, GIN index), not `tsvector` full-text search. Postgres text-search configurations
  are per-language and do not exist for the target languages (APP §2.1, classes B and D);
  `simple` would give whitespace tokenisation, which is wrong for scripts that do not delimit
  words with spaces. Trigrams are script-agnostic and need no per-language configuration.
- **R-SEARCH-DB-2.** The index is built on a generated column holding a **folded** form of the
  text — `lower()` plus diacritic folding via `unaccent` — so matching is
  normalisation-insensitive and diacritic-tolerant as APP R-SEARCH-1 requires of its local
  counterpart. The two implementations will not agree in every edge case; the app must not
  present online and offline search as the same feature returning merged results.
- **R-SEARCH-DB-3.** Search results are ordered by canonical position (book sort order, chapter,
  verse), not by relevance score. A translator searching for a term wants it in Bible order.
- **R-SEARCH-DB-4.** Search is scoped to projects the caller is a member of, by RLS, not by a
  `WHERE` clause in the function. A search endpoint is the classic place where a hand-written
  filter is forgotten.

### 5.9 Time

- **R-DATA-14.** Every timestamp is `timestamptz`, assigned server-side by `now()` or
  `clock_timestamp()`. No client-supplied timestamp is ever stored in a column that ordering,
  history, or the 10-minute revision window (§8.2) depends on (APP R-API-3).
- **R-DATA-15.** The app's local outbox timestamps may be carried through as
  `client_created_at` on the revision for display and diagnostics, clearly named as
  client-asserted. They must never be used in a comparison.

---

## 6. Authorisation (RLS)

### 6.1 Principles

- **R-RLS-1.** RLS is **enabled and forced** (`ENABLE ROW LEVEL SECURITY`,
  `FORCE ROW LEVEL SECURITY`) on every table in `app` and `ref`. A new table without RLS is a
  data leak on the day PostgREST is pointed at it; CI fails the build if any table in `app`
  lacks both (§13.3).
- **R-RLS-2.** The `anon` role has **no** access to any application table. Nothing in this
  system is public. The anon key is a public value that reaches every installed APK; it must
  be worth nothing on its own.
- **R-RLS-3.** The `service_role` key exists only in the console backend and CI secrets. It
  bypasses RLS entirely. **It must never appear in the Android app, in a client-side console
  bundle, or in any repository** (APP R-SEC-1, R-API-9). Its exposure is a full compromise of
  every project's data.
- **R-RLS-4.** RLS is the **only** authorisation mechanism. Write functions (§8) are
  `SECURITY DEFINER` and therefore bypass RLS on the tables they touch, so each one must
  re-establish the caller's permission explicitly as its first action, using the same helper
  functions the policies use. A `SECURITY DEFINER` function that forgets this is a privilege
  escalation with the API's own signature on it.

### 6.2 Grants

- **R-RLS-5.** `authenticated` receives `SELECT` on `api` views and `EXECUTE` on the `api` RPC
  functions. It receives **no** `INSERT`, `UPDATE`, or `DELETE` on any table, anywhere.
- **R-RLS-6.** `EXECUTE` is revoked from `PUBLIC` on every function at creation. Postgres grants
  it by default, and the default is wrong here.
- **R-RLS-7.** Every `SECURITY DEFINER` function sets `search_path = ''` and schema-qualifies
  every identifier. An unpinned `search_path` on a definer function is a well-known escalation
  path.

### 6.3 Policy structure

Helper functions, `STABLE`, in `app`:

```
app.current_profile_id()          -- maps auth.uid() → app.profile.id
app.role_in_project(project uuid) -- 'admin'|'translator'|'reviewer'|NULL
app.is_member(project uuid)
app.can_edit_verse(verse uuid)    -- membership + assignment + chapter not approved
```

- **R-RLS-8.** Policies call the helpers rather than repeating join logic. The rules in APP §4
  and §8 must have exactly one implementation; a rule expressed in fifteen policies is a rule
  with fifteen chances to be wrong.
- **R-RLS-9.** Helpers that read `app.project_member` are `SECURITY DEFINER`, because a policy
  on `project_member` that queries `project_member` recurses. This is the standard failure and
  it presents as an infinite-recursion error at query time, not at migration time.
- **R-RLS-10.** Policies reference `auth.uid()` as `(select auth.uid())`. The subquery form is
  evaluated once per statement as an InitPlan rather than once per row; the difference is
  substantial on the verse table and costs nothing.
  **This idiom is scalar-only.** For set membership the form is
  `x in (select app.my_project_ids())`, where the helper returns `setof uuid`. Writing
  `x = any ((select …))` against an array-returning helper is a syntax trap, not a slow
  query: a parenthesised sub-SELECT in `ANY` position is parsed as a subquery, so the
  comparison becomes `uuid = uuid[]` and the migration fails outright.
- **R-RLS-11.** Read access: a member of a project can read **all** content of that project.
  Translators are not restricted to their assigned chapters for reading — consistency of
  terminology across the book requires seeing other chapters, and per-chapter read filtering
  would make offline caching of a book impossible (APP §12).
- **R-RLS-12.** Write access is narrower than read access and is enforced in the write
  functions (§8) as well as by policy: text and status writes require assignment as translator
  on that chapter; review operations require assignment as reviewer; both require the chapter
  not be `approved` (APP R-WF-3). Project admins may act in either capacity.

### 6.4 Views

- **R-RLS-13.** Every view in `api` is created `WITH (security_invoker = true)`, so the
  underlying RLS policies apply to the calling user rather than the view's owner. Without it, a
  view over an RLS-protected table is a hole straight through the policy — the single most
  consequential detail in this section.
- **R-RLS-14.** Views expose exactly the fields APP §5.1 names, plus `my_role` on the project
  view. Internal columns (counters used only for progress, folded search columns, change-log
  bookkeeping) are not exposed.

---

## 7. Authentication and Account Provisioning

### 7.1 Configuration

- **R-AUTH-DB-1. Self-registration is disabled** (`disable_signup`; dashboard: Authentication →
  Providers → Email → "Allow new users to sign up" off). APP R-API-9 makes this an assumption
  the app relies on and does not compensate for.
  **Two different settings share the name `enable_signup`, and only one of them means this.**
  The top-level `[auth].enable_signup` maps to GoTrue's `DisableSignup` and is the correct
  control. The per-provider `[auth.email].enable_signup` maps to `EXTERNAL_EMAIL_ENABLED` and
  must stay **true**: setting it false disables email authentication entirely, so every
  administrator-provisioned account fails to sign in with "Email logins are disabled". Since
  admin provisioning is the only way accounts exist here, that setting would lock out the whole
  cohort, and it would look like a credential problem rather than a configuration one.
- **R-AUTH-DB-2.** Email/password is the only enabled provider. No OAuth, no magic link, no
  phone/SMS (APP R-AUTH-1, and R-LEGAL-3's registration lead time is thereby avoided).
- **R-AUTH-DB-3.** Email confirmation is irrelevant because accounts are created pre-confirmed
  by the admin API (§7.2), and identifiers may be **synthetic addresses on a project-controlled
  domain** (APP R-AUTH-2). No confirmation, recovery, or notification mail is ever sent to a
  translator. **No SMTP provider need be configured for the translator flow**; if one is
  configured for console operators, translator-facing templates must remain disabled.
- **R-AUTH-DB-4.** Access-token (JWT) lifetime: **1 hour**. Long enough that a device with
  intermittent connectivity is rarely mid-refresh, short enough that a leaked token expires.

### 7.2 Provisioning

- **R-AUTH-DB-5.** Accounts are created through the GoTrue **admin API** with the service key,
  from the console only, with `email_confirm: true`, an admin-chosen initial password, and a
  matching `app.profile` row created in the same operation.
- **R-AUTH-DB-6.** Profile creation is idempotent and self-healing: a trigger on `auth.users`
  insert creates the profile if the console did not. An auth user without a profile is invisible
  to every query in this schema and presents as a user who can sign in but has no data.
- **R-AUTH-DB-7.** `must_change_password` defaults to **true** on creation (APP R-AUTH-6). It is
  cleared only by `rpc/complete_password_change`, which verifies the caller actually changed
  their password (by requiring the change to have been made in the current session and checking
  `auth.users.updated_at`), rather than trusting the client's assertion that it happened.
- **R-AUTH-DB-8.** Until the flag is cleared, RLS denies the caller read access to all project
  content. The gate is in the database, not in the app's navigation — APP R-AUTH-6 requires the
  user reach no project data first, and a navigation guard is not a security control.

### 7.3 Sessions

APP §20 #1 asks for confirmation of the refresh-token settings. This section answers it and
flags what must still be verified against the live project (§17 #2).

- **R-AUTH-DB-9. Refresh tokens must not expire and no session limit may be enabled.**
  Specifically: refresh-token rotation **on**; refresh-token expiry / inactivity timeout
  **disabled**; session time-box **disabled**. APP R-AUTH-3 requires a password be entered once
  per device, ever. A translator whose password was communicated out of band months ago cannot
  recover from a forced re-authentication without the coordinator (APP R-AUTH-7).
- **R-AUTH-DB-10. The refresh-token reuse interval must be raised well above its default.**
  The default is on the order of ten seconds, which assumes a client whose renewal response
  arrives. APP R-AUTH-5 describes the failure precisely: a response lost in a dead zone leaves
  the client holding a token the server has retired, and the retry locks the user out — the
  worst outcome in this deployment. **Set it to at least 300 seconds.** The setting is
  GoTrue's refresh-token reuse interval (`SECURITY_REFRESH_TOKEN_REUSE_INTERVAL`; dashboard:
  Authentication → Sessions). Confirm the exact name, current default, and permitted maximum on
  the provisioned project before the pilot — this is the single configuration value most likely
  to cause an unrecoverable field failure.
- **R-AUTH-DB-11.** Password reset for another user is a **console operation using the admin
  API** (APP R-AUTH-7), which also re-sets `must_change_password`. Self-service email recovery
  cannot work against synthetic addresses and must be left disabled rather than left available
  and broken.

### 7.4 Privileged operations

- **R-AUTH-DB-12.** Every service-key operation — account creation, password reset, role
  assignment, chapter assignment, project creation, chapter reopen, project deletion —
  is performed by the console and written to `app.audit_log` (§12.2) with the acting operator,
  target, and before/after values. APP §14.2 lists a server-side audit trail of privileged
  operations as an assumption the app relies on.

---

## 8. Write Operations

All are `SECURITY DEFINER` functions in `api`, each performing, in order: authenticate the
caller, check the idempotency key (§9), authorise, validate workflow rules, mutate, write
history, append to the change log (§10), and return the new state.

- **R-FN-1.** Each function is a **single transaction**. The verse update, the revision insert,
  the counter update, the change-log append, and the idempotency record either all happen or
  none do. Partial application of a save is how history and current text come to disagree.
- **R-FN-2.** Each returns the full new state of the affected entity, so the app can settle its
  local row without a follow-up read (APP §12, and a round trip saved on a metered connection).

### 8.1 `save_verse_text(verse_id, text, reason)`

The core operation (APP §13.3). Behaviour:

1. Reject if the chapter is `approved` → `chapter_locked` (APP R-WF-3, R-API-11).
2. Reject if the caller is not the assigned translator, assigned reviewer, or a project admin
   → `not_assigned`.
3. Reject if the text is not NFC → `text_not_normalized` (§5.5).
4. If the text is **byte-identical** to the current text, return the current state unchanged:
   no `rev` increment, no revision, no change-log entry.
5. Otherwise increment `rev`, replace the text, set `last_modified_by`/`last_modified_at`,
   update status `empty → draft` if it was empty.
6. Decide revision capture per §8.2 and insert a revision if captured.
7. Append to the change log; return the state including `revision_captured`.

- **R-FN-3. The write is never rejected for staleness.** No `base_rev` parameter exists on this
  function, and none may be added without the corresponding change to APP §7 (last write wins).
  Adding one later is APP §19's optimistic-concurrency upgrade and is a deliberate contract
  change, not an implementation detail.
- **R-FN-4.** Step 4 is not merely an optimisation. The app's outbox may re-send collapsed
  writes (APP R-OFF-5) and autosave may fire on unchanged text; without it, revision history
  fills with identical entries and the 10-minute rule (§8.2) fires on non-edits.
- **R-FN-5.** The function takes `FOR UPDATE` on the verse row before reading `rev`. Two
  concurrent saves must serialise; last-write-wins means the later arrival wins, not that both
  writes race to assign the same `rev`.

### 8.2 Revision capture policy

APP §6.2 and R-REV-4: the decision is server-side. Capture a revision when **any** of:

| # | Condition |
|---|---|
| 1 | The write's `reason` is `explicit_save` or `editor_closed` |
| 2 | The chapter changed workflow state in this transaction (submit, return, approve) |
| 3 | More than **10 minutes** since the last revision of this verse **by this author** |
| 4 | The most recent revision of this verse has a different author |

- **R-FN-6. On the `reason` parameter.** APP R-REV-4 says the client "sends every write
  identically and does not decide history policy," while APP §6.2's first commit point — the
  user explicitly saving or navigating away — is by nature a client-side event. This is resolved
  by having the client report **what happened in the UI** (`autosave` | `explicit_save` |
  `editor_closed`) as an observation, and the server decide what that means. The policy stays in
  one place and remains changeable without a client release; an old or hostile client can at
  worst cause extra revisions, never inconsistent history.
- **R-FN-7.** Condition 3 uses server time on both sides of the comparison (APP R-API-3). An
  offline batch that syncs hours later is evaluated against when its writes **arrived**, so it
  typically produces one revision, not one per queued write. This is the correct outcome:
  history should record what the translator did, at the granularity a reviewer can read.
- **R-FN-8.** The revision's `rev` is the verse's counter value **after** the increment, so a
  revision's `rev` identifies the write it snapshots. Revisions are a subset of writes and
  `rev` values are therefore non-contiguous (APP §5.1); nothing may assume otherwise, and the
  UI presents ordinals (APP §5.1).

### 8.3 Revision immutability

- **R-FN-9.** `app.verse_revision` has no `UPDATE` or `DELETE` grant to any role, and a
  `BEFORE UPDATE OR DELETE` trigger raises unconditionally. The trigger catches the case that
  matters: a future migration, a console feature, or a `service_role` script. APP R-REV-1 makes
  immutability a property of the system, and the service key bypasses grants but not triggers.
- **R-FN-10.** Restore (`restore_revision`) is forward-only: it reads the target revision's
  text and performs a normal save with `reason = 'restore'`, setting
  `restored_from_revision_id` on the resulting revision. The counter is never rewound and no
  revision is removed (APP R-REV-5). Restore is implemented **in terms of** `save_verse_text`,
  not beside it, so it cannot diverge from it.

### 8.4 Workflow operations

- **R-FN-11.** `submit_chapter` rejects with `chapter_not_ready` if any verse is `empty`
  (APP R-WF-1). `review_chapter(decision = 'approve')` rejects with `chapter_has_flags` if any
  verse is `flagged` (APP R-WF-2). Both check counters (§5.7) and re-verify against source rows
  in the same transaction, because approving a chapter on a stale counter is unrecoverable
  without an admin reopen.
- **R-FN-12.** `flag_verse` requires a non-empty comment body and creates the comment and the
  flag in one transaction (APP R-REVIEW-2); `comment_required` otherwise.
- **R-FN-13.** Workflow transitions are validated against the state machine in APP §8.1. An
  invalid transition is `invalid_transition` (§11.2), not a silent no-op. An offline client
  acting on a stale chapter state is expected and must get a typed answer.
- **R-FN-14.** Chapter **reopen** (`approved → in_progress`) is admin-only and console-only
  (APP §13.6). It exists in `api` but its policy admits only project admins.

---

## 9. Idempotency

APP R-OFF-4 and §13.3: every write carries an idempotency key so a retry after a dropped
response does not duplicate a revision. This is not optional — the deployment's defining
network condition (APP §2.3) is the dropped response.

```
app.idempotency_key   profile_id, key text, operation text, request_hash text,
                      response jsonb, created_at
                      PK (profile_id, key)
```

- **R-IDEM-1.** The key is read from the `Idempotency-Key` request header via
  `current_setting('request.headers', true)::json`, so the app's transport matches APP §13.3
  without carrying the key in the body.
- **R-IDEM-2.** Every write function begins by inserting the key. A unique violation means this
  request has been seen: return the stored response verbatim and perform no work.
- **R-IDEM-3.** If the key matches but `request_hash` differs, raise
  `idempotency_key_reuse`. Silently returning the first response to a different request is
  worse than an error, because the client will believe the second write landed.
- **R-IDEM-4.** A key whose row exists but whose response is still NULL means a concurrent
  in-flight request. The second caller blocks on the row lock and returns the first's response
  when it commits. It must not proceed in parallel.
- **R-IDEM-5.** Keys are retained **7 days** and pruned by a scheduled job (§13.5). The window
  must comfortably exceed the longest realistic offline period for a queued write (APP §2.3
  describes multi-hour outages; a week covers a field trip).
- **R-IDEM-6.** A write arriving **without** a key is rejected with `idempotency_key_required`.
  Making it optional guarantees some code path omits it, and the resulting duplicate revisions
  are indistinguishable from real edits.

---

## 10. Delta Synchronisation

APP R-OFF-7 and §13.4: the app pulls changes by opaque cursor and never refetches a project.
This is the part of the design where a plausible implementation silently loses data.

### 10.1 Change log

```
app.change_log   seq bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                 project_id uuid not null,
                 entity_type ('verse'|'chapter'|'comment'|'assignment'|'project'),
                 entity_id uuid, op, payload jsonb,
                 xact_id xid8 not null default pg_current_xact_id(),
                 created_at timestamptz not null default clock_timestamp()
```

- **R-SYNC-1.** Every write function appends to the change log **in the same transaction** as
  its mutation. Nothing else writes to it, and no trigger-based capture is used: the write
  functions are the only mutation path (§6.2), so triggers would add a second mechanism with no
  additional coverage.
- **R-SYNC-2.** The payload carries the full new state of the entity, not a delta. Verse rows
  are small; reconstructing state from diffs on a client that may have missed windows is not.

### 10.2 The cursor

- **R-SYNC-3. Reads must exclude rows from transactions that have not yet committed**, using
  `xact_id < pg_snapshot_xmin(pg_current_snapshot())`:

  ```sql
  select * from app.change_log
   where project_id = p
     and seq > cursor_seq
     and xact_id < pg_snapshot_xmin(pg_current_snapshot())
   order by seq
   limit n;
  ```

  **Why this is mandatory:** identity values are assigned at insert time but become visible at
  commit time. A transaction can take `seq = 100` and commit *after* another that took
  `seq = 101`. A reader that advances its cursor to 101 will never see 100 — the row is
  permanently skipped, and the client's copy of that verse is permanently stale with no error
  anywhere. Excluding rows at or above the snapshot's `xmin` means the cursor only advances past
  entries no in-flight transaction can still be holding below.

  The cost is that changes become visible to sync only once all transactions in flight when they
  were written have finished — sub-second in normal operation, longer if a long transaction is
  open. That is a latency cost, not a correctness one, and it is the right trade.

- **R-SYNC-4.** The cursor returned to the app is the highest `seq` in the returned page,
  encoded opaquely (base64 of a versioned JSON object). The app treats it as a token
  (APP §13.4). It is not signed; RLS re-checks project access on every call, so a forged cursor
  can at worst skip a client's own changes.
- **R-SYNC-5.** Responses are paginated with a bounded page size and an explicit `has_more`
  flag, so a client that has been offline for weeks catches up in bounded chunks over a metered
  connection (APP R-NET-2).

### 10.3 Retention and expiry

- **R-SYNC-6.** Change-log rows are retained **90 days** and pruned by a scheduled job. A
  per-project watermark records the highest pruned `seq`.
- **R-SYNC-7.** A cursor **below** the watermark returns `cursor_expired` (HTTP 410,
  APP §13.5), and the app falls back to a full fetch of its subscribed scope. Returning an empty
  page instead would look like "nothing changed" and leave the device silently stale forever.
  A cursor *equal* to the watermark is still valid: the watermark is the highest `seq` pruned,
  so everything after it survives. An initial sync (no cursor) is never expired.
- **R-SYNC-8.** 90 days must exceed the longest plausible gap between a device syncing. It will
  not always: a device that is off for a season triggers a full refetch, which is correct
  behaviour and must be tested, not assumed rare.

### 10.4 Realtime

- **R-SYNC-9.** Supabase Realtime is **not used in the MVP.** APP §18.1 does not require push,
  APP §19 defers notifications, and a persistent WebSocket contradicts APP §2.3's metered,
  intermittent connectivity and APP R-NET-3's Data Saver obligation. Delta sync on a schedule
  and on app foreground is the model.
- **R-SYNC-10.** If Realtime is enabled later, RLS applies to Realtime channels through the
  publication and authorisation configuration; that configuration must be reviewed and tested
  separately. It is not covered by the policy tests in §13.3.

---

## 11. API Surface Details

### 11.1 Keys and headers

- **R-API-DB-1.** The app ships the **anon** key and the project URL. Both are public values.
  All access derives from the user's own JWT (APP R-SEC-1).
- **R-API-DB-2.** Responses are gzip-compressed and all collection endpoints paginate
  (APP R-API-4, R-API-6). PostgREST provides both; page limits must be set explicitly rather
  than left to the default, which is unbounded on some configurations.
- **R-API-DB-3.** Reads that the app caches send `Prefer: count=none` and avoid `select=*`;
  each view enumerates its columns. An implicit `*` over a growing table is a bandwidth
  regression nobody notices until the field reports data costs.

### 11.2 Error model

APP §13.5 requires a machine-readable code on every error. Postgres exceptions are mapped by
SQLSTATE: PostgREST maps `PT<nnn>` error codes to HTTP status `<nnn>`, and the exception's
message carries the application code.

- **R-ERR-1.** Every raised exception uses `ERRCODE = 'PT<status>'`, `MESSAGE = '<code>'`, and
  `DETAIL` as a JSON object of structured details. The app's API-client module normalises this
  into APP §13.5's `{ error: { code, message, details } }` envelope.

| Code | SQLSTATE | HTTP | Source |
|---|---|---|---|
| `chapter_not_ready` | PT422 | 422 | APP R-WF-1 |
| `chapter_has_flags` | PT422 | 422 | APP R-WF-2 |
| `chapter_locked` | PT409 | 409 | APP R-WF-3 |
| `comment_required` | PT422 | 422 | APP R-REVIEW-2 |
| `not_assigned` | PT403 | 403 | APP §13.5 |
| `forbidden` | PT403 | 403 | APP §13.5 |
| `unauthenticated` | — | 401 | GoTrue / PostgREST |
| `cursor_expired` | PT410 | 410 | §10.3 |
| `rate_limited` | — | 429 | §11.3 |
| `invalid_transition` | PT409 | 409 | §8.4 — **new** |
| `text_not_normalized` | PT422 | 422 | §5.5 — **new** |
| `idempotency_key_required` | PT400 | 400 | §9 — **new** |
| `idempotency_key_reuse` | PT409 | 409 | §9 — **new** |
| `must_change_password` | PT403 | 403 | §7.2 — **new** |
| `not_found` | PT404 | 404 | Target row absent or not visible — **new** |
| `invalid_argument` | PT400 | 400 | Bad enum value; `details` carries `field` and `value` — **new** |
| `verse_empty` | PT422 | 422 | `done` requested on a verse with no text — **new** |
| `verse_flagged` | PT422 | 422 | Status change on a flagged verse; resolve the comment instead — **new** |
| `password_unchanged` | PT422 | 422 | Forced change completed without the password actually changing (§7.2) — **new** |

- **R-ERR-2.** The ten codes marked **new** extend APP §13.5. APP R-API-12 requires the app to
  treat unrecognised codes as retryable-unknown and keep the write in the outbox — which is
  wrong for every one of them, since none will succeed on retry. **APP §13.5 must be amended to
  include them** before the app implements its error handling (§17 #6).
- **R-ERR-5.** New codes are added only for conditions the app must handle *differently*.
  Three separate `invalid_*` codes were collapsed into `invalid_argument` with a `field`
  detail for exactly this reason: they are all client programming errors with one correct
  client response. Every code added is a branch someone has to write, test, and translate.
- **R-ERR-3.** An RLS denial surfaces as an empty result on reads and as an explicit typed
  error on writes. The write functions check permission and raise `forbidden`/`not_assigned`
  rather than letting a policy silently filter a row and produce a "succeeded but nothing
  changed" response.
- **R-ERR-4.** No error message, `DETAIL`, or `HINT` may contain verse text, a display name, or
  a token (APP R-SEC-6). Error payloads reach logs and crash reports.

### 11.3 Rate limiting and abuse

- **R-API-DB-4.** Auth endpoints are rate-limited by GoTrue's own configuration; the limits must
  be reviewed against a realistic sign-in burst (a coordinator provisioning a team on one
  network, all signing in within minutes).
- **R-API-DB-5.** A statement timeout is set for the `authenticated` role (a few seconds).
  Search (§5.8) is the endpoint that will find the pathological query, and an untimed one on a
  shared instance affects every translator.

---

## 12. Storage, Audit, and Compliance

### 12.1 Font storage

- **R-STORE-1.** Fonts live in a Storage bucket with RLS-equivalent access policies restricting
  reads to authenticated users who are members of a project referencing the font.
- **R-STORE-2.** `app.font.sha256` is authoritative; the app verifies the hash after download
  and refuses a mismatch (APP R-FONT-3 caches these locally, and a corrupt font on a Class D
  script renders the app unusable).
- **R-STORE-3.** Font licence terms must permit redistribution through the app. This is a legal
  gate on which fonts may be uploaded at all, and it belongs in the console's upload flow.

### 12.2 Audit log

```
app.audit_log   id, occurred_at, actor_profile_id, actor_kind ('user'|'console'|'system'),
                action, target_type, target_id, before jsonb, after jsonb, request_id
```

- **R-AUDIT-1.** Every privileged operation (§7.4) and every workflow transition is recorded.
- **R-AUDIT-2.** The table is append-only by the same mechanism as revisions (§8.3): no
  `UPDATE`/`DELETE` grant, plus a trigger.
- **R-AUDIT-3.** No verse text in the audit log. Content history is the revision table's job;
  duplicating it here creates a second, unmanaged copy of translation data with different
  retention.

### 12.3 Personal data

- **R-COMPLY-1.** `app.consent_record(profile_id, version, accepted_at)` stores the
  acknowledgement APP R-LEGAL-1 requires the app to record. The consent text version is stored
  so a changed notice can be re-presented.
- **R-COMPLY-2.** Erasure is implemented as `rpc/anonymise_profile` (console, service key): it
  nulls `display_name`, sets `anonymised_at`, deletes the `auth.users` row, and leaves every
  revision, comment, and approval intact (§5.2, APP R-LEGAL-2). It is irreversible and audited.
- **R-COMPLY-3.** Personal data in this system is limited to display name, sign-in identifier,
  and activity timestamps. No phone numbers, no location, no device identifiers. Keeping the
  set this small is what makes R-COMPLY-2 tractable; adding to it later is a compliance
  decision, not a schema decision.

---

## 13. Operations

### 13.1 Migrations

- **R-MIG-1.** Schema is managed by the Supabase CLI, migrations committed to this repository,
  applied in CI. There is no other way schema reaches staging or production (§4, R-SCHEMA-4).
- **R-MIG-2.** Migrations are forward-only and linear. No migration is edited after it has been
  applied to staging; corrections are new migrations.
- **R-MIG-3.** Every migration must be safe against a **long tail of old app versions in the
  field**. APP R-PLAT-1's device profile implies slow update adoption. Concretely: additive
  changes only during a release window; a column is deprecated in one release and dropped in a
  later one; views (§3, R-TRANSPORT-5) absorb the shape change so old clients keep working.
- **R-MIG-4.** Reference data (§5.1) is seeded by migration and versioned with the schema, not
  loaded by hand.
- **R-MIG-5.** Every migration is applied to a fresh local database and to staging before
  production. `supabase db reset` against the seed must succeed in CI on every commit; that is
  the only proof the migration chain still builds a working database from zero.

### 13.2 Environments and backups

| Environment | Purpose | Data |
|---|---|---|
| Local (`supabase start`) | Development, tests | Seeded fixture only |
| Staging | Integration, console development, app QA | Synthetic; **never** production data |
| Production | Pilot and field use | Real |

- **R-OPS-1.** Point-in-time recovery enabled in production before the pilot (R-PLAT-DB-2).
  Daily backups alone lose up to a day of translation work, and APP §15 sets a hard "no edit may
  be lost" target.
- **R-OPS-2.** Restore is **tested** — a documented drill restoring production to staging,
  performed before the pilot and repeated on a schedule. An untested backup is a belief.
- **R-OPS-3.** Production data is never copied to staging or to a developer machine. If
  realistic data volume is needed, it is generated (§13.3).
- **R-OPS-4.** Service-key rotation procedure documented, with an owner and an expected
  frequency.

### 13.3 Testing

- **R-TEST-1. Every RLS policy has a negative test.** Tests run under an impersonated user JWT
  and assert that a non-member sees nothing, an unassigned translator cannot write, a reviewer
  cannot write to an approved chapter, and a user with `must_change_password` set reads no
  content. pgTAP, run in CI. Policies are the entire authorisation model (§6.1); untested
  policies mean untested authorisation.
- **R-TEST-2.** Concurrency tests for `save_verse_text`: two simultaneous saves produce two
  distinct `rev` values, one final text, and both texts recoverable from history (APP R-CON-2).
- **R-TEST-3.** Idempotency tests: replayed key returns the stored response and creates no
  second revision; a mismatched hash errors; a concurrent duplicate blocks rather than racing.
- **R-TEST-4.** A delta-sync test that **specifically covers the out-of-order commit case** of
  §10.2 — open a transaction, write from a second connection, commit out of order, and assert no
  change-log entry is skipped. This bug cannot be found by ordinary use; it must be constructed.
- **R-TEST-5.** A seeded fixture of one full book with realistic verse counts, plus a
  scale fixture of a full Bible with revision history, for index and progress-query validation
  against APP §15's targets.
- **R-TEST-6.** CI fails if any table in `app` or `ref` lacks `ENABLE`+`FORCE ROW LEVEL
  SECURITY`, or if any `SECURITY DEFINER` function lacks a pinned `search_path`. Both are
  mechanical checks that catch the two highest-severity mistakes available in this design.

### 13.4 Destructive operations

- **R-OPS-5.** Project deletion, bulk verse deletion, and any operation that removes revision
  history are **not exposed** in `api` at all. They are performed, if ever, by a migration or a
  documented manual runbook against production with a fresh backup taken first.

### 13.5 Scheduled jobs

- **R-OPS-6.** `pg_cron` runs: idempotency-key pruning (§9, daily), change-log pruning and
  watermark update (§10.3, daily), and counter reconciliation reporting (§5.7, weekly).
  Scheduled by `scripts/schedule-jobs.sql`, run once per environment after migrations —
  deliberately not a migration, because creating `pg_cron` in one breaks `supabase db reset`
  wherever the extension is unavailable, and only staging and production should prune.
- **R-OPS-7.** Each job logs its outcome to a table an operator can query. A pruning job that
  silently stops running presents months later as a cursor that never expires, or a table that
  grew without bound.

### 13.6 Capacity

Rough sizing, to establish that this is a small database and that the design should not be
distorted for scale it will not see:

| Item | Estimate |
|---|---|
| Verses, full Bible | ~31,000 rows |
| Verse text | ~150–400 bytes each |
| Revisions | 5–20 per verse over a project's life |
| Content per project including history | Well under 1 GB |
| Change log, 90-day retention | Tens of thousands of rows |
| Concurrent writers per project | Single digits |

- **R-CAP-1.** Do not partition, shard, or introduce read replicas. The correctness
  requirements in §8, §9, and §10 are the hard part of this system; its data volume is not.

---

## 14. USFM and Export

APP §13.6 places USFM import and export in the console, but the storage model that makes them
possible is a schema decision and belongs here.

- **R-USFM-1.** The verse row stores the **translated verse text only**. Paragraph breaks,
  section headings, poetry line structure, footnotes, cross-references, and chapter titles are
  not verse text and must not be jammed into the column.
- **R-USFM-2.** A **round-trip fidelity risk** must be resolved before import is built: a source
  USFM file containing markers between or around verses cannot be reconstructed from
  verse-text-only storage. Either those markers are preserved in a sidecar structure
  (`app.chapter_markup`, keyed by position), or the project accepts that export produces
  structurally plain USFM that the publishing tool's operator must re-mark. **This is a decision,
  not a detail** — it determines whether the MVP's vertical slice (APP §18.2) actually ends in
  usable output (§17 #4).
- **R-USFM-3.** Export is a read-only operation over `verse` and `ref` data, executed by the
  console. It must not require any schema element the app's write path does not maintain.

---

## 15. Non-Functional Targets

Derived from APP §15, expressed as database-side budgets. These leave the app roughly 80% of
each end-to-end budget for network and rendering.

| Operation | Target (server time, p95) |
|---|---|
| `save_verse_text` | < 50 ms |
| `GET /assignments` equivalent | < 100 ms |
| Chapter verses read (~40 rows) | < 60 ms |
| `changes_since` page | < 150 ms |
| Progress read | < 100 ms |
| Revision list page | < 100 ms |
| Project-wide search | < 500 ms |

- **R-NFR-1.** Indexes exist for every one of these paths before the pilot, verified against the
  scale fixture (R-TEST-5), not against the seeded book. Baseline set: `verse(chapter_id,
  number)`, `chapter(book_id, number)`, `verse_revision(verse_id, rev DESC)`,
  `comment(verse_id) WHERE resolved_at IS NULL`, `change_log(project_id, seq)`,
  `project_member(profile_id)`, and the trigram GIN index of §5.8.
- **R-NFR-2.** `EXPLAIN` output for the seven queries above is recorded in the repository and
  re-checked when the schema changes. A sequential scan that appears at 31,000 rows will not
  appear at 400.

---

## 16. Scope

### 16.1 In scope for MVP

1. Schema, reference data, and project materialisation (§5).
2. RLS across all tables, with policy tests (§6, R-TEST-1).
3. Auth configuration, admin provisioning, forced password change, persistent sessions (§7).
4. All write RPCs with revision capture, workflow validation, and idempotency (§8, §9).
5. Read views for every APP §13.4 operation the app uses.
6. Delta sync with a gap-free cursor (§10).
7. Typed errors (§11.2).
8. Font storage (§12.1) and audit log (§12.2).
9. Migrations, CI, seeded and scale fixtures, PITR, a tested restore (§13).

### 16.2 Out of scope for MVP

- Realtime (§10.4).
- Multi-project optimisation. The schema is multi-project from day one; query tuning for a
  translator in many projects is not needed (APP §18.2 defers multi-project in the app).
- Key-term glossary and consistency checking (APP §19). It will need its own tables and its own
  design; do not pre-build a partial version.
- Read replicas, partitioning (R-CAP-1).
- Any administrative UI. This document specifies the data operations the console performs, not
  the console.

---

## 17. Open Questions and Risks

| # | Item | Type |
|---|---|---|
| 1 | Confirm the Postgres version on the provisioned Supabase project meets R-PLAT-DB-1 (15+). Three requirements depend on it (§2). | Verification |
| 2 | **Confirm the refresh-token settings on the live project: rotation on, reuse interval ≥ 300 s, no inactivity timeout, no session time-box** (R-AUTH-DB-9/10). This answers APP §20 #1. It is the configuration most likely to lock a translator out irrecoverably in the field. | Verification |
| 3 | ~~Region and data-residency decision before the production project is created.~~ **Closed: India, `ap-south-1` (Mumbai)** (R-PLAT-DB-3). Confirm it is still the nearest offered region at creation. | Closed |
| 4 | **USFM round-trip: sidecar markup storage, or accept structurally plain export?** (R-USFM-2). Determines whether the MVP's vertical slice ends in output the partner organisation can publish. Depends on APP §20 #8. | Decision |
| 5 | Which versification scheme for the first cohort (R-DATA-2)? Immutable per project, and wrong choices surface only at export. | Decision |
| 6 | **APP §13.5 must be amended with the ten new error codes of §11.2**, or the app will treat non-retryable failures as retryable and hold them in the outbox forever (APP R-API-12). The set grew from five to ten as the write RPCs were implemented; treat it as final only once those are tested. | Dependency |
| 7 | Who owns the web console, and does it hold the service key in a server-side component? A console that needs the service key in a browser bundle is not deliverable under R-RLS-3. This is APP §20 #6 seen from the backend. | Dependency |
| 8 | Is a hosted staging project available for app development to integrate against before the console exists (APP §20 #7)? The seeded local stack plus these RPCs is a sufficient answer if it is published as a runnable target. | Dependency |
| 9 | Retention periods — 7 days for idempotency keys, 90 days for the change log — are asserted from the connectivity profile in APP §2.3, not measured. Revisit after the pilot with real device sync intervals. | Verification |
| 10 | ~~Anonymisation deletes the `auth.users` row; confirm nothing cascades from it.~~ **Closed.** `api.anonymise_profile` is implemented and `07_erasure.sql` asserts that every revision and comment survives an erasure, that the profile is tombstoned rather than deleted, and that the API still returns the rows with a null author name. | Closed |
