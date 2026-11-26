# Mobile Release Secrets & Config Checklist (AUT-IMP-003)

Checked-in reference for required service-account/track config and CI secrets. Use with `scripts/check-release-preflight.sh`.

## Secrets (GitHub Actions / release-mobile)

| Name | Required | Notes |
|---|---|---|
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Yes (Play ops) | Service account JSON for Android Publisher API. Must have access to package/tracks. |
| `UPLOAD_KEYSTORE_BASE64` | Yes | Base64 of upload keystore (`android/upload-keystore.jks`). |
| `KEY_ALIAS` | Yes | Upload key alias. |
| `KEY_PASSWORD` | Yes | Key password. |
| `KEY_STORE_PASSWORD` | Yes | Keystore password. |
| `CARTO_API_KEY` | Yes | Compiled via `--dart-define=CARTO_API_KEY`; workflow refuses empty. |
| `DISCORD_WEBHOOK_CHANGELOG` | Optional (best-effort) | New-semver changelog posts. |
| `DISCORD_WEBHOOK_UPDATES` | Optional (best-effort) | Staff updates posts. |
| `DISCORD_WEBHOOK_APPROVALS` | Optional (best-effort) | Tester-audience/setup asks. |

## Play config

| Item | Value | Notes |
|---|---|---|
| Package | `com.autobrainservice.app` | Must match build.gradle & Play app. |
| Closed testing track | `alpha` | Default upload target; must exist and have tester audience for auto-submit. |
| Production track | `production` | Promotion target. |
| Upload key fingerprint | SHA1 `F3:79:19:3F:F7:28:54:BE:46:01:6E:CB:FF:43:DC:15:DF:BF:FB:4C` | CI enforces; Play-registered upload cert. |

## Automated checks

- `scripts/check-release-preflight.sh [--secrets-only|--ci]` — validates SA/config presence/shape, package/track, version format, script syntax (no secret leakage).
- `scripts/get-play-max-version-code.sh` — queries Play max versionCode across tracks (requires SA).
- `scripts/bump-android-version-code.sh --apply` — bumps `pubspec.yaml` build number if <= Play max (used by CI).
- Workflow guards: package identity, CARTO key presence/compiled payload, signing fingerprint, version/pubspec match after auto-bump.

## One-time Play Console setup (if not already done)

- Closed testing `alpha`: testers (emails/Google Group) + country availability (e.g. restOfWorld) configured so commits submit for review (not draft fallback).
- Production: app listing/review requirements satisfied before promotion; country targeting configured as needed.
