# e2e test on Windows desktop (both bridge modes) against the release archives
# in dist/ (the windows-x64 one is enough). Runs inside the disposable Windows
# VM (windowsBuildVM), which ships Flutter and the MSVC toolchain.
$ErrorActionPreference = 'Stop'

$Repo = (Resolve-Path "$PSScriptRoot\..\..\..").Path
Set-Location $Repo

# With PION_BRIDGE_BINARIES_BASE_URL set (below) the build downloads the archive
# under test even if local build outputs exist; clear the per-version cache.
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue example\build

# SHA256SUMS in sha256sum's format, LF-terminated and without a BOM.
$sums = Get-ChildItem "$Repo\dist\pionbridge-*.tar.gz" | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Name
}
if (-not $sums) { throw "no release archives in $Repo\dist" }
[IO.File]::WriteAllText("$Repo\dist\SHA256SUMS", (($sums -join "`n") + "`n"))
Get-Content "$Repo\dist\SHA256SUMS"

$env:PION_BRIDGE_BINARIES_BASE_URL = 'file:///' + ($Repo -replace '\\', '/') + '/dist'

# The example commits only its Android and Linux runners.
Set-Location "$Repo\example"
& flutter create --platforms=windows --org io.filemingo . | Out-Null
if ($LASTEXITCODE -ne 0) { throw "flutter create failed ($LASTEXITCODE)" }

& flutter test -d windows integration_test/e2e_test.dart
if ($LASTEXITCODE -ne 0) { throw "e2e test failed ($LASTEXITCODE)" }
