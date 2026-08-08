# autobrain-mobile split (AUT-5)

Status: **PREP DONE — execution blocked on `github_pat` binding approval.**
Prepared by Founding Engineer heartbeat 2026-08-08.

## What this is

Extraction of the Flutter app from `frontend/` of `CannonFodder151/autobrain` into a
new **PRIVATE** repo `autobrain-mobile`. This directory is the prepared mobile repo:
full copy of `frontend/` with the complete frontend git history preserved via
`git subtree split -P frontend` (39 commits), plus a mobile-first README.

## Split design

- `autobrain` KEEPS `frontend/` as the Flutter **web** app — `docker/frontend/Dockerfile`
  is untouched, web build keeps working.
- `autobrain-mobile` (new, private) gets the same Flutter codebase as the iOS/Android
  home. Package name stays `autobrain` (imports `package:autobrain/...` unchanged).
- Versioned independently: `scripts/bump-version.sh --mobile` already targets
  `../autobrain-mobile/pubspec.yaml`.

## Remaining steps once `github_pat` is bound to Founding Engineer

1. Create PRIVATE repo: `POST https://api.github.com/user/repos`
   `{"name":"autobrain-mobile","private":true,"description":"AutoBrain mobile app (Flutter)"}`
   with `Authorization: Bearer <github_pat>`.
2. Push this tree (branch `main`, frontend history intact):
   `git remote add origin https://github.com/CannonFodder151/autobrain-mobile.git`
   `git push -u origin main`.
3. Push autobrain doc changes (applied to workspace autobrain working tree):
   README "Mobile app split" section, `docs/developer-onboarding.md` note,
   `frontend/README.md` split pointer. Commit on a branch and push.
4. Optionally scaffold Android/iOS platform folders (`flutter create . --platforms=android,ios`)
   where a Flutter toolchain is available; not present in this sandbox.

## Verification

- `flutter analyze && flutter test` in this dir (post-scaffold).
- Web build of `autobrain/frontend/` unchanged (no frontend files modified).

## Blocker

Paperclip secret `github_pat` not bound to this agent as of 2026-08-08T08:16Z.
Binding proposal `4e4a3c38…` (env.GITHUB_TOKEN) pending board approval; CEO also
created proposals. Once approved, the secret becomes fetchable and the steps above
are executable.
