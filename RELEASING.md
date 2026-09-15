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
  platform. For example, `file://$PWD/dist` tests archives from
  `package_release.sh` before publishing them.

## Cutting a release

1. Bump `version:` in `pubspec.yaml` and add a matching `## <version>` section
   to `CHANGELOG.md`. Commit and push to `master`.
2. In Jenkins, run **flutter-pion-bridge-release** (Build Now).
3. The pipeline (`Jenkinsfile`):
   - **Prepare:** resolves the version and commit, and fails if `v<version>` is
     already tagged or released, or the changelog section is missing.
   - **In parallel:**
     - host test layers (`tooling/ci/test.sh`)
     - Android/Linux/Windows builds in the builder container (`tooling/ci/linux/`)
     - macOS/iOS builds in a disposable Tart VM (`tooling/ci/macos/`)
   - **Publish:** uploads every archive plus `SHA256SUMS` to a draft release,
     then publishes it. Publishing creates the `v<version>` tag on the built commit.
4. Apps pick it up by depending on the tag (or, later, the pub.dev version).

Tick **DRAFT_ONLY** to run everything but stop at the unpublished draft, e.g.
to check a pipeline change or inspect the archives before releasing.

A failed run leaves no tag, only a draft release, which the next run replaces.
A published version is never rebuilt: fix forward with a new version. The
repository's *release immutability* setting keeps published assets and tags
from being changed afterwards.
