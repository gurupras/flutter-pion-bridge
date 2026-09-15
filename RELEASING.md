# Releasing

Native binaries are **not committed**. Each release publishes them as GitHub
Release assets, and each platform build downloads the ones matching the plugin
version in `pubspec.yaml`:

| Platform | Where the download happens | Archive |
|---|---|---|
| Android | `android/build.gradle` (`fetchGoBridge`, before `preBuild`) | `pionbridge-<v>-android.tar.gz` |
| iOS | `ios/pion_bridge.podspec` (at `pod install`) | `pionbridge-<v>-ios.tar.gz` |
| macOS | `macos/pion_bridge.podspec` (at `pod install`) | `pionbridge-<v>-macos.tar.gz` |
| Linux | `linux/CMakeLists.txt` (at configure) | `pionbridge-<v>-linux-{x64,arm64}.tar.gz` |
| Windows | `windows/CMakeLists.txt` (at configure) | `pionbridge-<v>-windows-x64.tar.gz` |

Every download is checked against the release's `SHA256SUMS`. The shared logic
lives in `build_support/`; the archive layouts are defined by
`scripts/package_release.sh`.

## Local development

Nothing changes: `scripts/build_<platform>.sh` writes binaries into the plugin
source tree (now gitignored), and a platform build uses local files whenever
they exist instead of downloading.

- **Android:** local bindings are used as-is. Set `PION_BRIDGE_BUILD_FROM_SOURCE=1`
  to have Gradle rerun `build_android.sh` whenever `go/` changes.
- **Stale local binaries win.** Rebuild after Go changes, or delete them to fall
  back to the release download.
- **`PION_BRIDGE_BINARIES_BASE_URL`** replaces the download location for every
  platform and forces the download even when local builds exist. For example,
  `file://$PWD/dist` tests archives from `package_release.sh` before publishing
  them. Downloads are cached per version (in the app's build directory, and in
  `ios/Downloaded`/`macos/Downloaded`), so clear those when re-testing new
  archives of the same version.

## CI pipeline

`Jenkinsfile` (Jenkins multibranch job **flutter-pion-bridge**) runs on every
push. It builds every platform from that commit and tests the packaged archives
— the files a release ships — before anything can be published:

| Stage | Where | What |
|---|---|---|
| Host tests | builder container | `tooling/ci/test.sh` (Go, race, SCTP fork, Dart) |
| Android, Linux, Windows | builder container on dileant | build + package, then e2e on Linux (Xvfb) and an Android emulator |
| macOS, iOS | disposable Tart VM on mini | build + package, then e2e on macOS and the `ci-iphone` simulator |
| Windows e2e | disposable Windows VM on dileant | e2e on Windows desktop |
| Publish | builder container | only when this push bumped the version (see below) |

The e2e test is `example/integration_test/e2e_test.dart`: two peers exchange
text and binary over a DataChannel in every bridge mode the platform ships
(websocket everywhere, shared on desktop, plus websocket↔shared interop). The
`tooling/ci/e2e/` scripts point the example app at the archives under test with
`PION_BRIDGE_BINARIES_BASE_URL`. Run one locally after packaging, e.g.
`scripts/package_release.sh linux-x64 && tooling/ci/e2e/linux.sh`.

## Cutting a release

There is no button: **a release is a version bump you push.**

```bash
# pubspec.yaml: version: 4.4.0
# CHANGELOG.md: ## 4.4.0 …
git commit -am "chore: release 4.4.0" && git push
```

On a push to `master`, Prepare compares `pubspec.yaml`'s version with the tags
on GitHub:

- **already tagged or released** — an ordinary push. Everything is built and
  tested, and Publish is skipped.
- **not yet released** — this push is the release. After every build and e2e
  stage passes, Publish uploads the archives plus `SHA256SUMS` to a draft
  release and publishes it, which creates the `v<version>` tag on the tested
  commit. A missing `## <version>` changelog section fails the run instead.

Then apps depend on the new tag (or, later, the pub.dev version).

A failed run leaves no tag, only a draft release: fix the problem and push
again, and the next run replaces the draft. A published version is never
rebuilt — fix forward with a new version. The repository's *release
immutability* setting keeps published assets and tags from being changed
afterwards.
