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
fvm dart run intl_utils:generate       # required after a fresh clone, and after ARB edits
fvm dart run flutter_launcher_icons
python3 l10n.py                        # sort ARB files; reports missing and unused keys
python3 l10n.py --clean                # drops the unused keys from every locale

fvm flutter test                                            # the CI-grade check
fvm flutter analyze                                         # no issues: keep it there

# Build and install on a connected device, keeping app data:
fvm flutter build apk --profile --split-per-abi   # one APK per ABI: ~46 MB instead of ~119 MB
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-profile.apk   # x86_64 for an emulator
```

`--split-per-abi` matters: the fat APK ships all three ABIs (95 MB of native code) for a phone
that loads exactly one. `lib/settings/native_locale_names.dart` carries the language picker's 29
labels inline for the same reason — the `flutter_localized_locales` package put 15 MB of JSON in the
bundle to produce them.

`lib/generated/` is **not** in version control, so `intl_utils:generate` is not optional after a
clone — without it nothing compiles. `flutter install` uninstalls first and wipes the local
database (accounts, likes) — never use it. On Windows `generate_icons.py` cannot run (no native
cairo); generate the adaptive assets with `npx sharp-cli` + PIL as described in the last fork note
below.

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
| `group/` | `GroupFeedShell`, the app bar and refresh plumbing the home feed is wrapped in |
| `home/` | Home screen with the For You / Following feed |
| `library/` | Hidden media library (`.nomedia`) with scan, thumbnails, external open |
| `likes/` | Like tab: local likes, Saved, the account's likes, X bookmarks |
| `profile/` | Profile header, tabs and media grid |
| `saved/` | Saved posts, folders, folder picker |
| `search/` | Tweet and user search, plus the offline Local tab |
| `settings/` | The single-page settings screen |
| `subscriptions/` | `SubscriptionsModel` (the followed accounts) and the followed-user index |
| `tweet/` | Tweet cards, threads, media, video playback |
| `ui/`, `utils/` | Shared widgets, errors, dates, paging, caches, downloads |
| `l10n/` | ARB sources, one per locale — the input to `intl_utils` |
| `generated/` | Auto-generated localization — never edit by hand, and not in git |

### API layer (`lib/client/`)

The API is **reverse-engineered**: endpoints, queryIds, tokens and headers change without notice.
Parse JSON defensively (`result["data"]?["text"] as String?`, never `result["data"]["text"]`).

**Verifying the header still works:** X reshapes their frontend without notice — the 2026 `x-web`
migration removed the `ondemand.s` chunk the generator read and broke every port of this algorithm
at once. When Search and follows start answering 404, run `dart run tool/check_indices.dart`: it
walks the live page and says whether the generator can still find its inputs, or whether
`ClientTransaction._findIndicesFileUrl` needs following them somewhere new again. It takes ~2s and
is not part of `flutter test` because it needs the network.

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
- Three navbar tabs, in this order: Download (queue / gallery) / Home (For You / Following,
  centered) / Like (local likes / Saved / profile likes / bookmarks). Settings is behind the gear
  in the home app bar; search shares that app bar. There is no notifications screen — the bell and
  the `notifications/` folder it lived in are gone, along with the subscription-group screens the
  old navbar reached (`c38b45c`). Do not look for them, and do not document them.
- The Following tab uses `HomeLatestTimeline` (`getHomeLatestTimeline`). Its queryId is
  community-tracked — on 404s update the constant or re-record with `tool/record/`.
- Account switching is a hard reset, never a refresh: `accountsRevision` (bumped only by a real
  switch, `lib/client/accounts.dart`) makes both home feeds `TweetFeedController.reset()` — the
  chronological feed must not merge the new login's first page on top of the old one's posts — and
  a page still in flight is cancelled (`CursorPagingController.reset`), so two timelines can never
  mix. The in-memory `activeAccount` (id + handle) drives the app-bar avatar and the per-account
  scroll keys (`scroll.home.*.<accountId>`); re-picking the current account is a no-op.
- Saving is end-to-end: the footer bookmark saves/unsaves (long-press opens the folder sheet);
  folders are configured in the Saved tab's Manage folders.
- Scroll performance: text is measured once per card (and the spans handed to the text widget are
  memoised, which is what lets that measurement survive a rebuild), seeded card colors and number
  formats are memoized, RTL is detected once per tile, pagination prefetches 8 items early, and the
  gallery decodes at tile width. Scroll offsets are written straight to `SharedPreferences` —
  through `PrefService.set()` they would notify `PrefService` (an `InheritedNotifier`) and rebuild
  every card on screen. Judge scroll smoothness on a profile/release build — debug is much slower.
- Fetching: timeline/profile/search/follows pages are decoded and parsed on a worker isolate
  (`parseChainsOnIsolate` / `parseOffThread` in `lib/client/client_parsing.dart`), which also loads
  the locale there because tombstones resolve a message while parsing; the app shares a single
  `http.Client` (`lib/client/http_client.dart`) so requests reuse the connection; and every list
  first load paints a `lib/ui/skeletons.dart` placeholder instead of a spinner.
- Downloads go to the hidden library only (`.nomedia`). A native foreground service owns progress
  and its notification actions; the queue is persisted (`downloads.json`), one transfer at a time,
  with pause/resume, Range resume, retries, space and integrity checks. No in-app player: gallery
  media opens in the system viewer through a FileProvider.
- Offline mode: `TimelineCache` stores a thread body (bounded to 30 days / 200 entries) so an
  already-read thread opens from disk, `NetworkStatus` (DNS probe) retries when the connection
  returns, and downloaded clips play from disk. There is no cached first page for the feeds
  themselves — a cold start shows `TweetListSkeleton` — so do not promise an instant feed paint.
- Local search (search screen's 5th tab) matches saved/liked posts in Dart
  (`lib/database/local_post_search.dart`) and library media by file name — Android's SQLite ships
  without FTS5 (verified on device: `no such module: fts5`), so do not build an SQL index for it.
- Settings is one page: General, Theme, Media, Tweets, Accessibility, Data, App info. Account
  management lives in the account sheet, not in Settings.
- Responsiveness around the app: video pool + visibility-based playback, gallery search/sort/bulk
  actions, transfer badge, onboarding wizard gating first run.
- On Windows, generate the adaptive icon assets without `generate_icons.py`:
  `npx sharp-cli -i assets/icon.svg -o assets/icon-foreground-432x432.png resize 432`, then create
  `assets/icon-background.png` (solid #080808, 432x432) and `icon-monochrome-432x432.png`
  (foreground with alpha turned white) with PIL.
- Local Android build quirks (this machine): `sdkmanager` must run with Android Studio's JDK
  (`JAVA_HOME=…\Android Studio\jbr`), and `android/app/build.gradle` pins
  `ndkVersion = "30.0.16248370"`.
