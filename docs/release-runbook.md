# AutoBrain Mobile Release Runbook

**Platform**: Android (Google Play Console) + iOS (Xcode Cloud)
**CI**: GitHub Actions (dispatch-only, self-hosted runner with release-signing label)
**Scripts**: `scripts/play-upload-closed-testing.sh`, `scripts/play-promote-to-production.sh`, `scripts/check-release-preflight.sh`

---

## Android Release Flow

### 1. Prerequisites (Secrets & Config)

| Secret | Source | Required For |
|--------|--------|--------------|
| `UPLOAD_KEYSTORE_BASE64` | Upload keystore (base64) | AAB signing |
| `KEY_ALIAS` | Keystore key alias | AAB signing |
| `KEY_PASSWORD` | Key password | AAB signing |
| `KEY_STORE_PASSWORD` | Keystore password | AAB signing |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Play Console service account | Play API auth |
| `CARTO_API_KEY` | CARTO basemap key | Map tile auth (compiled into AAB) |
| `DISCORD_WEBHOOK_CHANGELOG` | Discord webhook | Customer-facing changelog |
| `DISCORD_WEBHOOK_UPDATES` | Discord webhook | Internal release notifications |
| `DISCORD_WEBHOOK_APPROVALS` | Discord webhook | Tester-audience alerts |

**Service Account Permissions (Google Play Console)**:
- Role: **Release Manager** (or custom: `Manage production releases`, `Manage testing tracks`, `View app info`)
- Must have access to package `com.autobrainservice.app`
- JSON key downloaded and stored as `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`

**Track Configuration**:
- **Closed Testing (Alpha)**: `alpha` — existing track with tester audience (emails/Google Group), country availability = Rest of World ON
- **Production**: `production` — may not exist initially; script creates it as `PRODUCTION` type on first promote

---

### 2. Pre-Flight Checks (Run Before Every Release)

```bash
# Set required env vars
export GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(cat sa.json)"
export PLAY_PACKAGE_NAME="com.autobrainservice.app"

# Run pre-flight (local or CI)
scripts/check-release-preflight.sh --check-version-code 256 --track alpha --promote
```

**What it verifies**:
- OAuth token exchange works (service account valid, correct scope)
- Source track (`alpha`) exists and has releases
- Target versionCode is on source track (or will be uploaded first)
- Production track exists or can be created (test edit create/commit)
- App details accessible (package name matches)

**CI Integration**: When `GITHUB_OUTPUT` is set, script writes:
```
preflight_ok=true
source_track_releases=<count>
version_code_on_source=<true|false>
production_track_exists=<true|false>
```

---

### 3. Release Dispatch (GitHub Actions)

**Workflow**: `.github/workflows/release-mobile.yml` (dispatch-only)

**Inputs**:
| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `version` | string | required | Release tag e.g. `v0.3.311+256` |
| `bypass_apk_throttle` | bool | `false` | Build APK even if <48h since last APK |
| `promote_to_production` | bool | `false` | Promote closed-testing → production (staged 10%) |

**Trigger**:
```bash
gh workflow run release-mobile.yml \
  -f version=v0.3.311+256 \
  -f promote_to_production=true
```

**What the workflow does**:
1. Checkout + Flutter/Java/Android SDK setup
2. Verify version matches `pubspec.yaml`
3. Install keystore + `key.properties`
4. Verify package identity (`com.autobrainservice.app`)
5. Verify `CARTO_API_KEY` secret present
6. Build release `.aab` with `--dart-define` for API keys
7. (Optional) Build APK if throttle allows or bypassed
8. Verify AAB signing (v1/JAR) + upload key fingerprint
9. Verify `CARTO_API_KEY` compiled into AAB payload
10. (If APK built) Verify APK v2+v3 signing + key fingerprint + CARTO key
11. Extract changelog entry for semantic version
12. Publish GitHub Release (public, not draft) with `.aab` artifact
13. Upload `.aab` to Play Console **closed testing (alpha)** via `play-upload-closed-testing.sh`
14. If `promote_to_production=true`: promote to **production** (staged 10%) via `play-promote-to-production.sh`
15. Post Discord notifications (#changelog for new semver, #updates for every build)

---

### 4. Play Upload Script (`play-upload-closed-testing.sh`)

**Usage**:
```bash
scripts/play-upload-closed-testing.sh build/app/outputs/bundle/release/app-release.aab [track-id]
```

**Environment Variables**:
| Var | Default | Description |
|-----|---------|-------------|
| `PLAY_TRACK` | `alpha` | Target closed testing track |
| `PLAY_RELEASE_STATUS` | `completed` | `completed`, `draft`, or `inProgress` |
| `PLAY_ROLLOUT_PERCENT` | `100` | For `inProgress`: userFraction cap (99.9% max) |
| `PLAY_ALLOW_DRAFT_FALLBACK` | `true` | Fall back to draft if no tester audience |
| `PLAY_RELEASE_NOTES` | auto | What's new text (from CHANGELOG) |
| `PLAY_LOG_FILE` | — | Transcript log path |
| `GITHUB_OUTPUT` | — | CI output for `needs_tester_audience` |

**Behavior**:
- Single-edit flow (never opens probe edit → avoids AUT-952 "Edit deleted" failure)
- Creates missing track as `CLOSED_TESTING` in its own committed edit first
- For rollout tracks (`alpha`): retries as `inProgress` userFraction=0.999 if `completed` rejected (AUT-4987)
- If no tester audience: falls back to `draft`, sets `needs_tester_audience=true` in `GITHUB_OUTPUT`

---

### 5. Play Promote Script (`play-promote-to-production.sh`)

**Usage**:
```bash
scripts/play-promote-to-production.sh [versionCode] [source-track]
```

**Environment Variables**:
| Var | Default | Description |
|-----|---------|-------------|
| `PLAY_TRACK` | `production` | Target track |
| `PLAY_FROM_TRACK` | `alpha` | Source track for versionCode |
| `PLAY_ROLLOUT_FRACTION` | `0.1` | Staged rollout fraction (0<frac≤1) |
| `PLAY_RELEASE_NOTES` | auto | What's new text |
| `PLAY_SOURCE_POLL_ATTEMPTS` | `12` | Poll retries for source track |
| `PLAY_SOURCE_POLL_DELAY` | `10` | Seconds between polls |
| `PLAY_LOG_FILE` | — | Transcript log path |

**Behavior**:
- Resolves versionCode from source track (with retry/poll for upload race, AUT-365)
- Verifies versionCode present on source track
- Creates production track if missing (idempotent)
- Opens main edit, promotes to production with `status=inProgress` + `userFraction` (default 0.1 = 10%)
- Commits edit — **no draft fallback** (commit failure surfaces cause)
- Verifies versionCode visible on production track after commit
- Output: `production release OK: versionCode N staged rollout userFraction=X`

**Rollout Advancement**:
```bash
# Advance to 50%
PLAY_ROLLOUT_FRACTION=0.5 scripts/play-promote-to-production.sh <vc>

# Advance to 100% (completed)
PLAY_ROLLOUT_FRACTION=1 scripts/play-promote-to-production.sh <vc>
```

---

### 6. One-Time Play Console Setup (Required Before First Release)

**Closed Testing (Alpha) Track**:
1. Play Console → Testing → Closed testing → Alpha
2. **Testers**: Add email addresses or Google Group
3. **Countries/regions**: Turn ON "Rest of World" (or select specific)
4. **Save** — this enables auto-submit-for-review on every upload

**Production Track**:
- Created automatically by promote script on first run
- No manual setup needed

---

### 7. VersionCode Management

- **Format**: `pubspec.yaml` version = `X.Y.Z+N` where `N` = versionCode (integer)
- **Conflict**: Play rejects duplicate versionCode with `403 Version code N already used`
- **Bump**: Increment `N` in `pubspec.yaml` (e.g., `0.3.311+255` → `0.3.311+256`)
- **Tag**: Git tag = `vX.Y.Z+N` (e.g., `v0.3.311+256`)
- **Changelog**: Add entry under `## [X.Y.Z] - YYYY-MM-DD` in `CHANGELOG.md`

---

### 8. Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Version code N already used` | Duplicate versionCode | Bump `+N` in pubspec.yaml |
| `invalid service account JSON` | Malformed/expired SA key | Regenerate SA key in Play Console |
| `targeting no countries` | Alpha track has no tester audience | Configure testers + Rest of World in Play Console |
| `does not allow any existing users to upgrade` | Rollout track + `completed` status | Script auto-retries as `inProgress` 0.999 |
| `This Edit has been deleted` | Multiple concurrent edits | Script uses single-edit flow; ensure no parallel runs |
| `CARTO_API_KEY not in .aab payload` | `--dart-define` not passed to build | Verify workflow passes `CARTO_API_KEY` |
| `APK signer SHA-1 mismatch` | Wrong upload keystore in CI secrets | Verify `UPLOAD_KEYSTORE_BASE64` matches Play Console |

---

### 9. Discord Notifications

| Channel | Trigger | Content |
|---------|---------|---------|
| `#changelog` | New semantic version (X.Y.Z) | Release notes + GitHub Release link |
| `#updates` | Every build (dispatch) | Artifact link + notes |
| `#approvals` | `needs_tester_audience=true` | One-time setup request for alpha track |

---

### 10. iOS Release (Xcode Cloud)

See `docs/APPLE_SIGNING_CREDENTIALS.md` and `.xcodecloud/workflows/` for TestFlight/App Store workflows.

---

*Runbook maintained by Mobile Release Engineer. Update on workflow/script changes.*