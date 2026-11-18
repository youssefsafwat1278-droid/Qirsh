# Mali — CLAUDE.md

Arabic-first on-device expense tracker. Bank SMS → parse → categorize → local Drift DB.
User-facing brand: **Qirsh** (Arabic **قِرش**). Internal/technical codename:
**Mali** — the `money_companion` Flutter package and bundle ID
`com.youssefsafwat.mali` (both unchanged; technical identifiers are not rebranded).

## Gate commands (run these before every commit)

```bash
flutter analyze          # must be clean (0 issues)
flutter test             # must pass (canonical count via tools/ci_gates.sh)
flutter gen-l10n         # regenerate ARB → Dart after any l10n change
```

Run all three from `app/` (the Flutter project root, i.e. this directory).

## Run on simulator

```bash
flutter run -d "Mali-iPhone"       # or use the UDID in /tmp/mali_sim_udid.txt
```

Real-device build requires a paid Apple Developer account (App Groups). Not available yet.

## Environment variables (dart-define)

Passed at build/run time. Optional for LOCAL use — the app's data lives in local
Drift (the source of truth) and it launches without them — but cloud sync,
encrypted backup, AI capture, and auth REQUIRE Supabase config. `SupabaseConfig.isConfigured`
/ `SentryConfig.isConfigured` gate their use (no crashes without them), so those
features are simply unavailable when unconfigured — this is NOT a full offline
stub of all functionality.

| Variable          | What it does                                 |
|-------------------|----------------------------------------------|
| `SUPABASE_URL`    | Supabase project URL                         |
| `SUPABASE_ANON_KEY` | Supabase anon key                          |
| `SENTRY_DSN`      | Sentry error reporting DSN                   |

```bash
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

`SupabaseConfig.isConfigured` / `SentryConfig.isConfigured` gate their use — no crashes without them.

---

## Supabase setup (one-time, from scratch)

### 1. Create the project

1. Go to [supabase.com](https://supabase.com) → New project.
2. Choose a region close to your users (recommend **eu-central-1** or nearest Gulf option).
3. Save the **database password** somewhere safe — you'll need it for the CLI.
4. From **Project Settings → API**, copy:
   - `Project URL` → `SUPABASE_URL`
   - `anon public` key → `SUPABASE_ANON_KEY`
   - `service_role` key → keep this secret, used only in admin/server contexts

### 2. Run migrations

All SQL lives in `../supabase/migrations/`. Run them **in order** via the Supabase SQL editor
(**Dashboard → SQL Editor → New query**) or via the CLI:

```bash
# Install CLI once
brew install supabase/tap/supabase

# Link to your project (get <project-ref> from the dashboard URL: supabase.com/dashboard/project/<ref>)
supabase link --project-ref <project-ref>

# Push all migrations
supabase db push
```

Migration order and what each creates:

| File | Creates |
|------|---------|
| `0001_init.sql` | `profiles`, `backups`, `metrics`, `bank_rules` tables + RLS + storage RLS policies |
| `0002_catalog_mvp.sql` | `banks`, `sms_parsers`, `currencies`, `countries`, `categories`, `catalog_versions` + version triggers |
| `0003_feature_flags_announcements.sql` | `feature_flags`, `announcements` + seed flags |
| `0004_parser_lab.sql` | Parser lab tables |
| `0005_profiles.sql` | Extends `profiles`, adds `get_user_stats()` RPC |

### 3. Create the backups Storage bucket

In **Dashboard → Storage → New bucket**:
- Name: `backups`
- Public: **OFF** (private)
- The RLS policies in migration `0001` already handle per-user access.

### 4. Create the admin user

The admin panel uses Supabase email/password auth. Create your admin account:

**Dashboard → Authentication → Users → Add user**
- Email: your email
- Password: strong password
- Click **Create user**

> The admin panel has no sign-up flow — only users you manually create here can log in.

### 5. Deploy Edge Functions

```bash
# From the repo root (../supabase/)
cd ../supabase

# Deploy all functions at once
supabase functions deploy catalog-delta
supabase functions deploy catalog-announcements
supabase functions deploy catalog-flags
supabase functions deploy catalog-versions
supabase functions deploy parser-test
```

Or deploy all in one shot:
```bash
for fn in catalog-delta catalog-announcements catalog-flags catalog-versions parser-test; do
  supabase functions deploy $fn
done
```

### 6. Verify everything works

In the Supabase SQL editor, run:
```sql
select get_user_stats();          -- should return JSON with totals
select * from catalog_versions;   -- should show 5 rows (banks/parsers/etc.)
select * from feature_flags;      -- should show 4 seeded flags
```

---

## Admin panel — run locally

The admin panel lives at `../admin/` (Next.js 14, port 3001).

### First-time setup

```bash
cd ../admin

# Create env file
cp .env.local.example .env.local 2>/dev/null || cat > .env.local << 'EOF'
NEXT_PUBLIC_SUPABASE_URL=https://your-project-ref.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key-here
EOF

# Install dependencies
npm install
```

### Run dev server

```bash
cd ../admin
npm run dev
# Opens at http://localhost:3001
```

Log in with the admin user you created in step 4 above.

### What the admin panel shows

| Route | Content |
|-------|---------|
| `/dashboard` | User stats (total, MAU, new this month), catalog counts, daily signup chart |
| `/banks` | Bank catalog — add/edit banks and their SMS senders |
| `/parsers` | SMS parser rules — add/edit/validate regex rules |
| `/categories` | Spending categories |
| `/flags` | Feature flags — toggle on/off, set rollout % |
| `/announcements` | In-app announcement banners |

### Build for production

```bash
cd ../admin
npm run build
npm start        # runs on port 3001
```

---

## Full test checklist

Run all of these before merging anything:

```bash
# ── Flutter app ──────────────────────────────────────────
cd app
flutter pub get
flutter gen-l10n                                  # regenerate l10n
flutter analyze                                   # must be 0 issues
flutter test                                      # must pass (count via tools/ci_gates.sh)

# Run on simulator
flutter run -d "Mali-iPhone"

# Run with Supabase connected
flutter run -d "Mali-iPhone" \
  --dart-define=SUPABASE_URL=https://your-ref.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=your-anon-key

# ── Admin panel ──────────────────────────────────────────
cd ../admin
npm install
npm run lint                                      # must be clean
npm run build                                     # must succeed

# ── Supabase SQL sanity checks ───────────────────────────
# Run in Dashboard → SQL Editor:
# select get_user_stats();
# select * from feature_flags where is_active = true;
# select count(*) from banks;
```

## Project layout

```
lib/
  main.dart                    # bootstrap: Sentry → Supabase → AppSession → DB → runApp
  app.dart                     # MoneyApp widget, GoRouter, theme, locale
  core/
    auth/                      # Auth service + Supabase implementation
    backend/                   # SupabaseConfig, SentryConfig, MetricsClient, RulesClient
    di/                        # app_providers.dart — Riverpod global providers
    security/                  # Biometric lock gate + service
    session/                   # AppSession (install ID, user prefs)
    theme/                     # AppColors, AppTheme, AppTypography, AppSpacing, AppAssets
    utils/                     # Currency helper, formatters, ID generator, l10n ext
  data/
    db/                        # AppDatabase (Drift, SQLCipher-encrypted), migrations
    repositories/              # Drift implementations of all domain repositories
    catalog/                   # Remote catalog sync (CatalogSyncService, FeatureFlagService)
  domain/
    entities/                  # Pure Dart entity models
    repositories/              # Abstract repository interfaces
    usecases/                  # Business logic use cases
    services/                  # NotificationPlanner
  engine/
    parser/                    # ParserEngine (Dart isolate), bank profiles, normalizer
    categorization/            # Categorizer, merchant→category map, seed data
    models/                    # ParsedTransaction, TransactionType, TransactionSource
  features/
    accounts/                  # Multi-currency account management
    achievements/              # Gamification / badges
    app/                       # AppShell, bottom nav
    backup/                    # Export/import
    budgets/                   # Budget tracking
    capture/                   # SMS notification listener + CaptureRuntime
    cards/                     # Card details screen
    common/                    # Shared widgets (motion, vault, section hero, etc.)
    dashboard/                 # Home screen — account switcher, totals, recent txns
    foundation/                # Foundation home screen
    goals/                     # Savings goals
    onboarding/                # First-run flow
    reports/                   # Spend reports + charts
    settings/                  # Settings screen + account manager (route: /accounts)
    subscriptions/             # Bills/subscriptions (big brand cards)
    transactions/              # Transaction list, details, manual-add sheet
  l10n/                        # ARB files → generated app_localizations_*.dart
```

## Tech stack

| Layer | Library |
|-------|---------|
| State | `flutter_riverpod` |
| Navigation | `go_router` |
| Local DB | `drift` (SQLCipher-encrypted via `sqlite3mc`) |
| Secure storage | `flutter_secure_storage` |
| Backend | `supabase_flutter` |
| Auth | Google Sign-In, Sign in with Apple |
| Charts | `fl_chart` |
| Animations | `flutter_animate` |
| Icons | `lucide_icons` |
| Fonts | `google_fonts` |
| Error tracking | `sentry_flutter` |
| Biometrics | `local_auth` |
| Notifications | `flutter_local_notifications` |

## Critical architecture rules

1. **UI reads only from Drift. Never from the network.**
   Sync writes to Drift; UI reads from Drift. No direct Supabase reads in widgets/providers.

2. **Remote catalog = content only. Business logic stays in Dart.**
   Parser rules describe patterns. "Is this OTP?", confidence thresholds, sender filtering — all hardcoded in `engine/`.

3. **Parser runs in a Dart isolate (2-second timeout).**
   Regex must be Dart syntax: named groups use `(?<name>...)` not `(?P<name>...)`.

4. **Feature flags use SHA-256, not `hashCode`.**
   `hashCode` is unstable across Dart versions. Use `sha256("$installId:$flagKey").bytes → 16-bit int % 100`.

5. **Category keys are stable strings.**
   `'restaurants'`, `'subscriptions'`, etc. Parser rules reference categories by `key`, not UUID.

6. **DB schema version is `_targetSchemaVersion` in `app_database.dart` (currently 44).**
   Bump it and add a migration case for every schema change.

7. **No HMAC secret in the binary.** HTTPS + Edge Function filtering is the MVP security model.

8. **Do not commit.** Leave changes in the working tree for the orchestrator to review and commit.

## Multi-currency accounts

- `accounts` table, `AccountEntity`, `AccountRepository` / `DriftAccountRepository`
- `account_id` FK on transactions; v2 migration creates a default account and backfills
- Parser detects currency from SMS, falls back to the account's currency
- `Currency` helper at `lib/core/utils/currency.dart` — Arabic labels for all currencies
- Dashboard has an account/currency switcher chip row and per-currency totals (no FX yet)
- `baseCurrencyProvider` replaces hardcoded "ريال" strings in goals/cards/chart/subscriptions

## Design system notes

- Dark mode: true-black (`#000000`) background, white primary — "Premium Minimalist" palette
- `AppColors` in `lib/core/theme/app_colors.dart` — do not revert to the previous teal palette
- Header extends under the status bar (no safe-area gap)
- Common animated widgets in `lib/features/common/motion.dart` (`AnimatedAmountText`, etc.)

## codex-delegate skill

Installed at `.claude/skills/codex-delegate/`. Use to delegate bounded tasks to Codex:

```bash
node .claude/skills/codex-delegate/scripts/relay.mjs --brief brief.txt --cd .
```

Codex never commits. Review diff + re-run gates, then commit yourself.
Resume a previous session with `--resume-last`.

## Codegen

After changing Drift table definitions:

```bash
dart run build_runner build --delete-conflicting-outputs
```

After changing `.arb` localization files:

```bash
flutter gen-l10n
```

## CI (Codemagic)

Two workflows in `../codemagic.yaml`:
- `ios-unsigned-sideload` — unsigned IPA for Sideloadly (no paid Apple account needed)
- `ios-signed-release` — signed IPA (requires Apple Developer Program)

Supabase keys injected via the `supabase` variable group in Codemagic settings.
