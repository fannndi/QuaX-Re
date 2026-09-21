# QuaX-Re

A personal fork of [QuaX](https://github.com/Teskann/QuaX), a privacy-focused Flutter/Dart client
for X (Twitter). Android only.

Everything stays on the device: accounts, likes, saved posts and downloaded media live in a local
SQLite database and the app talks to X through reverse-engineered API endpoints. There are no
trackers and no analytics.

QuaX itself is forked from [Quacker](https://github.com/TheHCJ/Quacker) and
[Fritter](https://github.com/jonjomckay/fritter). See [LICENSE](./LICENSE) and
[licenses/](./licenses) for attribution.

## Features

- Home feed with For You and Following timelines
- Notifications timeline (bell in the feed's app bar)
- Like tab: posts liked in the app, Saved posts with folders, the account's likes and bookmarks
- Subscription groups: bundle followed users into custom feeds
- Tweet search (top / latest / media) and people search
- Download queue with pause/resume and a hidden media library (`.nomedia`) opened from the gallery
- Offline mode: cached timelines, locally liked/saved posts, downloaded clips play from disk
- Single-page settings: theme, media quality, autoplay/loop, text size, cache management

## Build

Prerequisites: [FVM](https://fvm.app/) with the pinned Flutter SDK (3.47.4 in `.fvmrc`), an
Android SDK with platform 37 / build-tools 36 / NDK 30, and the JDK bundled with Android Studio.

```bash
fvm flutter pub get
fvm dart run intl_utils:generate                            # after editing lib/l10n/*.arb
fvm dart run flutter_launcher_icons
fvm dart run flutter_iconpicker:generate_packs --packs material

fvm flutter test                                            # run the tests
fvm flutter build apk --profile                             # smoothness: profile/release
```

Install on a device without wiping its data:

```bash
adb install -r build/app/outputs/flutter-apk/app-profile.apk
```

Do **not** use `flutter install`: it uninstalls first, which deletes the local database (accounts,
likes, saved posts).

## Development

`AGENTS.md` documents the architecture, the conventions and the fork's deviations for anyone (or
any agent) working on the code.

## License

MIT, like the upstream projects. See [LICENSE](./LICENSE).
