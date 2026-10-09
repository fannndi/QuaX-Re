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
- Like tab: posts liked in the app, Saved posts with folders, the account's likes and bookmarks
- Tweet search (top / latest / media) and people search, plus an offline Local tab
- Download queue with pause/resume and a hidden media library (`.nomedia`) opened from the gallery
- Offline mode: cached threads, locally liked/saved posts, downloaded clips play from disk
- Single-page settings: theme, media quality, autoplay/loop, text size, cache management
- English-only interface: a single locale (`intl_en.arb`) and no in-app translation of posts

## Build

Prerequisites: [FVM](https://fvm.app/) with the pinned Flutter SDK (3.47.4 in `.fvmrc`), an
Android SDK with platform 37 / build-tools 36 / NDK 30, and the JDK bundled with Android Studio.

```bash
fvm flutter pub get
fvm dart run intl_utils:generate                            # required: lib/generated is not in git
fvm dart run flutter_launcher_icons

fvm flutter test                                            # run the tests
fvm flutter build apk --profile --split-per-abi --target-platform android-arm64   # one APK for this phone
```

`--target-platform android-arm64` keeps the build to the one ABI a phone loads; add
`--split-per-abi` to get one APK per architecture instead of a fat one. Install
`app-arm64-v8a-profile.apk` — around 45 MB instead of 119.

`python3 l10n.py` sorts `lib/l10n/intl_en.arb` and reports keys the code no longer references;
`--clean` removes them.

Install on a device without wiping its data:

```bash
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-profile.apk
```

Do **not** use `flutter install`: it uninstalls first, which deletes the local database (accounts,
likes, saved posts).

## Development

`AGENTS.md` documents the architecture, the conventions and the fork's deviations for anyone (or
any agent) working on the code.

## License

MIT, like the upstream projects. See [LICENSE](./LICENSE).
