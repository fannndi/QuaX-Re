# AGENTS.md

Guidance for AI coding agents working in this repository.

## Project overview

QuaX-Re is a personal fork of [QuaX](https://github.com/Teskann/QuaX) (itself forked from
Quacker/Fritter): a privacy-focused Flutter/Dart client for X (Twitter). Android only. No
trackers, everything local (SQLite `quax.db`), and reverse-engineered X API endpoints.

## Commands

The SDK is pinned in `.fvmrc` (Flutter 3.47.4) — use `fvm flutter` when fvm is available,
otherwise the same-version system `flutter`.

```bash
fvm flutter pub get
fvm dart run intl_utils:generate                            # after editing lib/l10n/*.arb
fvm dart run flutter_launcher_icons
fvm dart run flutter_iconpicker:generate_packs --packs material
fvm flutter test                                            # the CI-grade check
fvm flutter analyze                                         # ~45 pre-existing upstream infos

# Build and install on a connected device, keeping app data:
fvm flutter build apk --profile          # use profile (or release) to judge scroll
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

`flutter install` uninstalls first and wipes the local database (accounts, likes) — never use it.
On Windows `generate_icons.py` cannot run (no native cairo); generate the adaptive assets with
`npx sharp-cli` + PIL as described in the last fork note below.

## Architecture

### State management

All state lives in **flutter_triple** `Store<T>` objects (`*_model.dart` per feature, async work
through `execute()`). Widgets observe stores via `ScopedBuilder` / `TripleBuilder`. Do not use
`setState` or `ChangeNotifier` for app state — the Store pattern is the convention.

### Feature layout (`lib/`)

| Folder | Description |
|---|---|
| `app/` | App shell (`fritter_app.dart`), routing setup, theme, onboarding, privacy shield |
| `article/` | X long-form article rendering |
| `catcher/` | Shared exception types (`HttpException`, account errors) |
| `client/` | X API client wrappers, account selection/health, login webview, headers |
| `database/` | SQLite repository (`repository.dart`) + entities + migrations |
| `downloads/` | Download queue, native notification bridge, connectivity watcher, video cache |
| `group/` | Subscription groups (custom chunked feeds) |
| `home/` | Home screen with the For You / Following feed |
| `library/` | Hidden media library (`.nomedia`) with scan, thumbnails, external open |
| `likes/` | Like tab: local likes, Saved, the account's likes, X bookmarks |
| `notifications/` | Notifications timeline (opened from the feed's bell) |
| `profile/` | Profile header, tabs and media grid |
| `saved/` | Saved posts, folders, folder picker |
| `search/` | Tweet and user search |
| `settings/` | The single-page settings screen |
| `subscriptions/` | Followed users and their groups |
| `tweet/` | Tweet cards, threads, media, video playback |
| `ui/`, `utils/` | Shared widgets, errors, dates, paging, caches, downloads |
| `generated/` | Auto-generated localization — never edit by hand |

### API layer (`lib/client/`)

The API is **reverse-engineered**: endpoints, queryIds, tokens and headers change without notice.
Parse JSON defensively (`result["data"]?["text"] as String?`, never `result["data"]["text"]`).

`client.dart` is the `Twitter` facade over `dart_twitter_api`. `_QuackerTwitterClient.fetch()`
asks the pure `AccountSelector` (`account_selector.dart`) for a healthy account and retries on
another on error. Health signals: rate limits (429) are per-endpoint and remembered in memory by
`RateLimitTracker`; not-found (404) / rejected sessions (401) are per-account, persisted
(`recordNotFound` / `recordAccountSuccess` in `accounts.dart`) and only influence ordering — the
selector always falls back to flagged accounts, so errors surface from real responses, not flags.
Network-level failures never taint account health (one retry after 1s). Dedicated error widgets in
`ui/errors.dart`: `RateLimitedException`, `NoWorkingAccountException`, `NoAccountAvailableException`
(guest request first). Anything else surfaces as `HttpException`; retry re-runs `fetch()`.

### Database (`lib/database/`)

`repository.dart` is the only SQLite access point. Schema changes **must** go through
`sqflite_migration_plan` migrations — never ALTER tables outside one. Key entities: `Subscription`,
`SubscriptionGroup`, `SavedTweet` (+ folders), `LikedTweet`, `Account` (health columns).

### Navigation and localization

Routes are constants in `constants.dart`, registered in `fritter_app.dart`; x.com deep links are
parsed in `utils/urls.dart`. UI strings live in `lib/l10n/*.arb` and are reached through
`L10n.of(context)` — never hardcode UI text; regenerate after ARB edits.

## Coding style

- Functional patterns: immutable data, pure functions, `map`/`where`/`fold` over loops.
- Split responsibilities; avoid functions over ~30 lines (widget builders excepted).
- Anytime you are about to copy/paste code, stop and refactor instead.
- Go easy on comments: no obvious or redundant ones.

## Writing tests

Use the Should convention with a concise `reason` on every assertion that says what breaks when it
fails. Look at existing tests to mimic the style (`flutter test` runs everything; DB tests use
`sqflite_common_ffi`).

## Fork notes (deviations from upstream)

- Personal fork (fannndi/QuaX-Re); upstream CI/agent tooling (`.github/`, `.claude/`, `docs/`,
  `fastlane/`, release scripts) is removed on purpose. `master` tracks upstream for inspection.
- Three navbar tabs: Home (For You / Following) / Download (queue / gallery) / Like (local likes /
  Saved / profile likes / bookmarks). Settings is behind the gear in the home app bar; the bell
  opens the notifications screen; search shares the same app bar.
- The Following tab uses `HomeLatestTimeline` (`getHomeLatestTimeline`). Its queryId is
  community-tracked — on 404s update the constant or re-record with `tool/record/`.
- Saving is end-to-end: the footer bookmark saves/unsaves (long-press opens the folder sheet);
  folders are configured in the Saved tab's Manage folders.
- Scroll performance: text is measured once per card, seeded card colors and number formats are
  memoized, RTL is detected once per tile, and pagination prefetches 8 items early. Judge scroll
  smoothness on a profile/release build — debug is much slower.
- Downloads go to the hidden library only (`.nomedia`). A native foreground service owns progress
  and its notification actions; the queue is persisted (`downloads.json`), one transfer at a time,
  with pause/resume, Range resume, retries, space and integrity checks. No in-app player: gallery
  media opens in the system viewer through a FileProvider.
- Offline mode: `TimelineCache` (first page, 12h Ttl) paints feeds instantly, `NetworkStatus`
  (DNS probe) retries when the connection returns, and downloaded clips play from disk.
- Settings is one page: General, Theme, Media & downloads, Posts, Accessibility, Data, About.
  Account management lives in the account sheet, not in Settings.
- Responsiveness around the app: video pool + visibility-based playback, gallery search/sort/bulk
  actions, transfer badge, onboarding wizard gating first run.
- On Windows, generate the adaptive icon assets without `generate_icons.py`:
  `npx sharp-cli -i assets/icon.svg -o assets/icon-foreground-432x432.png resize 432`, then create
  `assets/icon-background.png` (solid #080808, 432x432) and `icon-monochrome-432x432.png`
  (foreground with alpha turned white) with PIL.
- Local Android build quirks (this machine): `sdkmanager` must run with Android Studio's JDK
  (`JAVA_HOME=…\Android Studio\jbr`), and `android/app/build.gradle` pins
  `ndkVersion = "30.0.16248370"`.
