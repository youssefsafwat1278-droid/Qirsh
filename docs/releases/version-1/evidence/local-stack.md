# Local Supabase stack for Version 1 verification

A private, disposable Supabase stack built from this worktree's `supabase/`
directory (all migrations in `supabase/migrations/`, applied on a fresh database).
It is separate from the other stacks on this machine (`frasaaaaa` on
54321/54322 and the older `qirsh_proof` on 55321/55322); do not stop or reset those.

| Item | Value |
|---|---|
| Stack (`project_id`) | `qirsh_v1_verify` |
| Source | scratch COPY of `supabase/` (tracked files are not edited) |
| Scratch directory | `<scratch>/qirsh_v1_verify` |
| API (Kong) | `http://127.0.0.1:56321` |
| Postgres | `127.0.0.1:56322` (shadow 56330, pooler 56329, disabled) |
| Studio | `http://127.0.0.1:56323` |
| Mail (Mailpit) | `http://127.0.0.1:56324` |
| Edge runtime inspector | 56328 |
| Analytics | disabled (see below) |
| URL, anon/service keys, DB URL, JWT secret, QA sign-in | `<scratch directory>/stack.env` (mode 600; `source` it) |

The keys are the well-known local development keys printed by `supabase start`;
they are kept only in `stack.env`, not in tracked files.

## Changes made in the scratch copy only

`supabase/config.toml` in the scratch copy: `project_id = "qirsh_v1_verify"`; ports
moved to 56321 (api), 56322 (db), 56330 (shadow), 56329 (pooler), 56323 (studio),
56324 (inbucket), 56327 (analytics), 56328 (edge inspector); `[analytics] enabled = false`.
Image files in `supabase/` were not copied.

## Fresh-environment result (2026-11-17)

- All 134 migrations applied cleanly on an empty database, including
  `0117_account_deletion_fence.sql` (no abort on a fresh database).
- The first `supabase start` failed only because the analytics (Logflare) and
  vector containers never became healthy (`LegacyHealthCheckTimeoutError`,
  Logflare `No Free Plan created yet in database`); migrations had already applied.
  Disabling analytics in the scratch copy fixed it. This is a local-tooling issue
  with CLI 2.117.0, not a schema issue.
- No Auth hook or Vault entries were configured. Features that depend on them
  (if any) are not exercised by this stack.

## Commands

```bash
S=<scratch>/qirsh_v1_verify
# start (idempotent) / status / stop — only ever with --workdir "$S"
supabase start  --workdir "$S"
supabase status --workdir "$S"
supabase stop   --workdir "$S"      # keeps data; add --no-backup to discard it
source "$S/stack.env"               # exports LOCAL_SUPABASE_* and QA_EMAIL/QA_PASSWORD
```

## Synthetic QA account

`qa+v1@example.test`, email confirmed, created through the local admin API. Its
password is `QA_PASSWORD` in `stack.env`. Sign in with email and password against
`LOCAL_SUPABASE_URL` (for the app: `--dart-define=SUPABASE_URL=$LOCAL_SUPABASE_URL
--dart-define=SUPABASE_ANON_KEY=$LOCAL_SUPABASE_ANON_KEY`), or:

```bash
curl -s -X POST "$LOCAL_SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $LOCAL_SUPABASE_ANON_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$QA_EMAIL\",\"password\":\"$QA_PASSWORD\"}"
```

## Restore-then-Cloud scenario (V1-020)

```bash
source "$S/stack.env"; cd app
PUB_CACHE=$HOME/.pub-cache flutter test --no-pub \
  --dart-define=SUPABASE_URL=$LOCAL_SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$LOCAL_SUPABASE_ANON_KEY \
  test/integration_local/restore_then_sync_local_supabase_test.dart
```

The test creates its own throw-away users and deletes them and their rows at the end.
Both `--dart-define`s are required: without them `SupabaseConfig.isConfigured` is
false and the startup reconcile backfill returns `skippedGuest`, so the run models
an unconfigured build rather than the shipped app.

## Status note (2026-11-17, ~06:22Z)

After the first successful scenario run, Docker Desktop failed with
`write .../log/vm/init.log: no space left on device` (host disk was full; ~30 GiB
free afterwards) and its API stopped answering (`docker ps` hangs; all local stacks,
including `frasaaaaa`, return no response). The stack was left as started; it was
not stopped. If it does not answer, Docker Desktop has to be restarted by its owner
and the stack brought back with `supabase start --workdir "$S"` (data volume kept).
