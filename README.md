# scripture-bridge-db

Supabase backend for Scripture Bridge — the database, authorisation, and API surface that the
Android application consumes.

**Status:** requirements draft. No migrations yet.

## Documentation

| Document | Contents |
|---|---|
| [docs/requirements.md](docs/requirements.md) | Database and backend requirements: schema, RLS, auth, write operations, delta sync, operations |
| [docs/roadmap.md](docs/roadmap.md) | Milestones M0–M5, exit criteria, and cross-repo dependencies |

The app's requirements document defines a backend-agnostic API contract and deliberately
leaves the engine, schema, and enforcement unspecified. This repository makes those decisions
for Supabase.

## Design in brief

- **Postgres with RLS as the only authorisation mechanism.** Every table has row level
  security enabled and forced; policy tests are part of CI.
- **No direct writes.** The `authenticated` role holds no DML on any table. All writes are
  `SECURITY DEFINER` RPCs, so revision-capture policy and workflow validation are
  server-side by construction.
- **No gateway service.** The app calls PostgREST, RPC, GoTrue, and Storage directly over
  generic HTTPS; the mapping to the contract's operation names lives in the app's single
  API-client module.
- **Tables are not exposed.** Base tables live in a `app` schema that PostgREST cannot reach;
  reads go through `security_invoker` views in `api`.
- **Idempotent writes and gap-free delta sync.** Both are load-bearing for a client that
  edits offline for hours and retries after dropped responses.

## Related repositories

- [scripture-bridge-android-app](https://github.com/samueldotj/scripture-bridge-android-app)
  — the Android client, and the API contract this backend satisfies.

## License

See [LICENSE](LICENSE).
