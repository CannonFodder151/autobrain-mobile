# AutoBrain Mobile (Flutter)

The **mobile app** for AutoBrain — an AI-powered car enthusiast companion.
Split out of the `autobrain` monorepo (`frontend/`) into this private repo so
the mobile and web apps can evolve and version independently.

> [!NOTE]
> The web app lives in the [autobrain](https://github.com/CannonFodder151/autobrain)
> repo (`frontend/`) and is built for web by its Docker image. This repo is the
> iOS / Android home for the same Flutter codebase.

## Structure

```
lib/
  main.dart          entrypoint
  app.dart           MaterialApp + auth gate
  core/
    config.dart      --dart-define build configuration
    api_client.dart  HTTP client (REST + uploads + exports)
    auth_state.dart  auth token + session (provider)
    models.dart      typed API models
    offline_cache.dart  SQLite cache for offline mode
    theme.dart
  screens/
    auth/            login, register, reset password, server setup
    home/            dashboard
    vehicles/        list, add (with rego lookup), timeline
    services/        history, add, AI prediction, export
    fuel/            tracker, add, efficiency graph
    diagnostics/     AI diagnosis + add-to-service
    mods/            tracker, build sheet export
    receipts/        OCR scan + apply to service/inventory
    parts/           inventory, reorder suggestions
    valuation/       resale value estimator
    analytics/       spend, TCO, insights, forecast
    admin/           user admin, server settings, licence
    settings/        account, licence, notifications
  widgets/           shared widgets
test/                model unit tests
web/                 Flutter web build config (mirrored into autobrain)
```

## Build

Flutter SDK is required. Regenerate platform boilerplate (Android/iOS/Web
folders beyond the config files committed here) with:

```bash
flutter create . --platforms=android,ios,web --org com.autobrain
flutter pub get
```

Configure API endpoints at build time:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://host/api/v1 \
                   --dart-define=WS_BASE_URL=wss://host/ws
flutter build ios --release --dart-define=API_BASE_URL=https://host/api/v1 \
                   --dart-define=WS_BASE_URL=wss://host/ws   # requires macOS + Xcode
```

## Offline mode

API responses are cached to SQLite (`offline_cache.dart`). Screens that
currently rely on live data degrade gracefully on failure; the cache layer is
the intended extension point for full offline queues.

## Tests

```bash
flutter test
```

## Versioning

The mobile app versions independently from the web app. `scripts/bump-version.sh`
in `autobrain` accepts `--mobile` to bump this repo's `pubspec.yaml` alongside a
release.

## macOS self-hosted runner (Nathans-iMac-Pro)

The iOS runner is a persistent host with no Homebrew and only the
CommandLineTools Ruby 2.6, whose SDK is missing `ruby/config.h` — enough to
break any `gem install` that has to build a native extension. The toolchain is
provisioned instead into the runner user's own `$HOME`, with no sudo and no
system paths touched:

```bash
# on the runner, as the service user (nathan), or via the
# "Provision macOS runner toolchain (fastlane)" workflow_dispatch
bash scripts/macos/provision-runner.sh
```

That builds Ruby via rbenv under `~/.rbenv`, installs fastlane into
`~/.gem`, and writes `~/.autobrain-toolchain.env`. Actions steps run
`/bin/bash -e` with a launchd-inherited `PATH` and never read `~/.zshrc`, so
any step that needs Ruby or fastlane must source the env file:

```yaml
- name: Use the provisioned toolchain
  run: |
    . scripts/macos/toolchain-env.sh
    fastlane --version
```

Homebrew itself is not installed: its installer needs `sudo`, and the runner
user has no passwordless sudo. `provision-runner.sh` installs it automatically
once NOPASSWD sudo is granted, and prints the exact one-line command if not.
Both paths are idempotent, so the runner can be reimaged and re-provisioned
with a single workflow dispatch.
