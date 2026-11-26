# Android Release Runbook — AutoBrain Mobile

**Owner:** Mobile Release Engineer + DevOps  
**Applies to:** `autobrain-mobile` (`com.autobrainservice.app`)  
**Issue:** AUT-IMP-003 (automate Android versionCode/build bump in CI; codify alpha→production promotion + required config/secrets checks)

## 1. Source of truth & versioning

- **Version source:** `pubspec.yaml` `version: X.Y.Z+N`
  - `X.Y.Z` = semantic/app version (shared release identity)
  - `N` (after `+`) = **Android `versionCode` / Play build number** (must be strictly increasing on Play Console)
- **Tag format:** `vX.Y.Z+N` (e.g. `v0.3.311+260`)
- **CI auto-bump (AUT-IMP-003):** `.github/workflows/release-mobile.yml` now runs `scripts/bump-android-version-code.sh --apply` before build.
  - Queries Play for max known versionCode across tracks (`scripts/get-play-max-version-code.sh`)
  - If requested `N <= maxOnPlay`, bumps to `maxOnPlay + 1` in `pubspec.yaml` and resolves release tag accordingly
  - Prevents "Version code N has already been used" (255/conflict-class failures)

## 2. Required secrets / config (checked-in checks)

### Repo/CI secrets (release-mobile workflow)
| Secret | Purpose | Check |
|---|---|---|
| `UPLOAD_KEYSTORE_BASE64` | Android upload keystore (base64) | preflight + signing verify |
| `KEY_ALIAS` | Keystore alias | preflight + build |
| `KEY_PASSWORD` | Key password | preflight + build |
| `KEY_STORE_PASSWORD` | Store password | preflight + build |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Play Android Publisher service account JSON | preflight + Play API calls |
| `CARTO_API_KEY` | Basemap key compiled into app (AUT-4691/5556) | workflow guard + payload verify |
| `DISCORD_WEBHOOK_CHANGELOG` | Customer changelog post (new semver only) | workflow step (best-effort) |
| `DISCORD_WEBHOOK_UPDATES` | Staff updates post | workflow step (best-effort) |
| `DISCORD_WEBHOOK_APPROVALS` | Tester-audience ask (closed testing fallback) | workflow step (best-effort) |

### Play/service-account & track config
- **Package:** `com.autobrainservice.app` (must match `android/app/build.gradle` namespace/applicationId)
- **Closed testing track (upload target):** `alpha` (existing track with testers; default in `scripts/play-upload-closed-testing.sh`)
- **Production track:** `production`
- **Service account access:** must have Play Console permissions to create/edit/commit releases for this app and tracks
- **Tester audience (closed testing):** required for `completed`/submitted-for-review. If missing, upload script may fall back to `draft` and workflow posts to `#approvals` for one-time setup.

### Preflight script
Run before manual/diagnostic releases (and enforced in CI for secrets during auto-bump):
```bash
export GOOGLE_PLAY_SERVICE_ACCOUNT_JSON='...'
bash scripts/check-release-preflight.sh            # full checks (in repo)
bash scripts/check-release-preflight.sh --secrets-only
bash scripts/check-release-preflight.sh --ci
```
Checks: SA presence/shape, package/track config, pubspec format, Android identity, required release scripts syntax, CI secret presence warnings. **Never prints secret values.**

## 3. CI release flow (alpha/closed testing)

Workflow: `.github/workflows/release-mobile.yml` (dispatch-only)

1. Resolve requested tag from input `version` (must correspond to intended semver/build input)
2. **Auto-bump versionCode if needed** via Play max lookup (`scripts/get-play-max-version-code.sh`, `scripts/bump-android-version-code.sh --apply`)
3. Setup Flutter/Java/Android SDK, install keystore, verify package identity & CARTO key presence
4. `flutter build appbundle --release` (+ throttled APK for signing/sideload checks)
5. Verify signing/fingerprints and CARTO key compiled into artifacts
6. Publish GitHub Release (non-draft) with `.aab`
7. Upload to Play **closed testing track `alpha`** (`scripts/play-upload-closed-testing.sh`)
   - Idempotent on reused versionCode (`PLAY_VERSION_CODE`) where already present
   - Commits edit (submits for review) when tester audience configured; may fall back to draft with approvals notification if audience missing
8. Optional promotion to production when `promote_to_production=true`

## 4. Alpha → Production promotion (codified)

### Preconditions
- `.aab` uploaded and versionCode visible on source track (default `alpha`)
- Release notes/changelog reviewed; rollout decision approved per company policy
- Production track has required country/tester/review readiness as applicable in Play Console
- Service account has permission to update/commit `production`

### Promotion script (checked-in)
```bash
export GOOGLE_PLAY_SERVICE_ACCOUNT_JSON='...'
export PLAY_PACKAGE_NAME='com.autobrainservice.app'
export PLAY_FROM_TRACK='alpha'          # source
export PLAY_TRACK='production'          # target
export PLAY_ROLLOUT_FRACTION='0.1'      # default staged 10%; set 1 for 100% completed
export PLAY_RELEASE_NOTES='AutoBrain vX.Y.Z+N'
bash scripts/play-promote-to-production.sh <versionCode> [source-track]
```

**Behavior (scripts/play-promote-to-production.sh):**
- Resolves/verifies versionCode on source track (poll/retry; tolerates Play response shape differences)
- Ensures production track exists (creates if missing)
- Sets release on production as `inProgress` with `userFraction` (staged, default 10%) or `completed` when fraction >= 1
- Commits edit (**no draft fallback**) and verifies versionCode visible on production
- To advance rollout: re-run with `PLAY_ROLLOUT_FRACTION=0.5` then `1.0` (or use Play Console)

### CI-triggered promotion (opt-in)
`release-mobile.yml` input `promote_to_production=true` runs promotion after successful alpha upload:
- Passes upload-confirmed `versionCode`
- Uses staged rollout fraction configured in workflow/env (`PLAY_ROLLOUT_FRACTION`, default 10% in script; workflow may set per policy)
- Fails the run on promotion/commit errors (no silent fallback)

## 5. Manual recovery / common failures

- **"Version code already used":** auto-bump should prevent; if hit on re-run, ensure `PLAY_VERSION_CODE` passed for idempotent upload path or re-dispatch after bump.
- **"targeting no countries / tester audience missing" (closed testing):** configure testers + country availability on `alpha` in Play Console (one-time), then re-run to submit as completed.
- **Promotion fails "not visible on source track":** wait for upload propagation or pass explicit versionCode (upload output); script retries/polls and can proceed with caller-supplied versionCode but commit is authoritative.
- **Wrong signing key:** CI enforces expected upload cert fingerprints; rotate/fix `UPLOAD_KEYSTORE_*` secrets to Play-registered upload key.
- **Missing CARTO key:** workflow/build guards fail fast to avoid watermarked/broken map artifacts.

## 6. Verification checklist (release complete)

- [ ] `pubspec.yaml` version/tag matches resolved release `vX.Y.Z+N`
- [ ] CI logs show auto-bump decision (bumped true/false) and Play max versionCode
- [ ] `.aab` signed with expected upload key; artifact attached to GitHub Release
- [ ] Play alpha track contains versionCode (submitted or draft-with-known-reason)
- [ ] If promoted: production shows versionCode with intended rollout fraction/status
- [ ] Discord notifications posted (best-effort) / manual note if webhook failed

## 7. Files (checked-in)

- `.github/workflows/release-mobile.yml` — CI release + auto-bump + upload + optional promotion
- `scripts/get-play-max-version-code.sh` — Play max versionCode query
- `scripts/bump-android-version-code.sh` — CI/local auto-increment helper
- `scripts/check-release-preflight.sh` — secrets/config/runbook preflight checks
- `scripts/play-upload-closed-testing.sh` — alpha upload/commit
- `scripts/play-promote-to-production.sh` — alpha→production staged promotion
- `docs/releases/ANDROID_RELEASE_RUNBOOK.md` — this runbook
