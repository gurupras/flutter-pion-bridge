#!/usr/bin/env python3
"""Publish pion_bridge release archives as GitHub Release v<version>.

  check    decide whether this commit should be released: exit 0 when
           v<version> is new and CHANGELOG.md documents it, exit 3 when the
           version is already tagged or released (an ordinary push), and fail
           on anything else — a version to release whose changelog entry is
           missing included
  publish  write dist/SHA256SUMS, upload every archive to a draft release, then
           publish it; publishing creates the v<version> tag at --commit
           (--draft-only stops before publishing)

A failure before the final step leaves at most an unpublished draft (no tag),
which the next run replaces. Needs GH_TOKEN with Contents: read and write.
Standard library only.
"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

REPO = "gurupras/flutter-pion-bridge"
API = f"https://api.github.com/repos/{REPO}"
UPLOADS = f"https://uploads.github.com/repos/{REPO}"
# Must match scripts/package_release.sh and build_support/.
PLATFORMS = ["android", "ios", "macos", "linux-x64", "linux-arm64", "windows-x64"]
ROOT = pathlib.Path(__file__).resolve().parents[2]


def request(method, url, body=None, data=None, content_type=None, ok=(200, 201, 204)):
    headers = {
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if body is not None:
        data = json.dumps(body).encode()
        content_type = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        payload = e.read()
        status = e.code
    if status not in ok:
        sys.exit(f"{method} {url}: HTTP {status}: {payload[:500].decode(errors='replace')}")
    return status, (json.loads(payload) if payload else None)


def changelog_section(version):
    text = (ROOT / "CHANGELOG.md").read_text()
    match = re.search(rf"^## {re.escape(version)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not match or not match.group(1).strip():
        sys.exit(f"CHANGELOG.md has no '## {version}' section")
    return match.group(1).strip()


# Exit code for "this version is already out"; the pipeline reads it to tell an
# ordinary push from one that bumped the version.
ALREADY_RELEASED = 3


def released(version):
    tag = f"v{version}"
    status, _ = request("GET", f"{API}/git/ref/tags/{tag}", ok=(200, 404))
    if status == 200:
        return f"tag {tag} already exists"
    status, _ = request("GET", f"{API}/releases/tags/{tag}", ok=(200, 404))
    if status == 200:
        return f"release {tag} is already published"
    return None


def ensure_unreleased(version):
    reason = released(version)
    if reason:
        sys.exit(f"{reason}; bump the version in pubspec.yaml")


def ensure_can_write():
    """Fail now, not after an hour of building, if the token cannot publish.

    An empty release body creates nothing: GitHub answers 422 (permitted, but
    invalid) when the app may write contents and 403 when it may not.
    """
    status, _ = request("POST", f"{API}/releases", body={}, ok=(403, 422))
    if status == 403:
        sys.exit("GH_TOKEN cannot create releases (403). Grant the GitHub App "
                 "'Contents: Read and write' and accept the updated permissions "
                 "on its installation.")


def check(args):
    reason = released(args.version)
    if reason:
        print(f"{reason} — nothing to release")
        sys.exit(ALREADY_RELEASED)
    changelog_section(args.version)
    ensure_can_write()
    print(f"v{args.version} is unreleased, has a changelog entry, and can be published")


def publish(args):
    tag = f"v{args.version}"
    notes = changelog_section(args.version)
    ensure_unreleased(args.version)

    dist = pathlib.Path(args.dist)
    archives = [dist / f"pionbridge-{args.version}-{p}.tar.gz" for p in PLATFORMS]
    missing = [a.name for a in archives if not a.is_file()]
    if missing:
        sys.exit(f"missing archives in {dist}: {', '.join(missing)}")
    sums = dist / "SHA256SUMS"
    sums.write_text("".join(
        f"{hashlib.sha256(a.read_bytes()).hexdigest()}  {a.name}\n" for a in archives))
    print(sums.read_text(), end="")

    # Drop drafts left by earlier failed runs so the release list stays clean.
    _, releases = request("GET", f"{API}/releases?per_page=100")
    for old in releases:
        if old["draft"] and old["tag_name"] == tag:
            print(f"deleting stale draft {old['id']}")
            request("DELETE", f"{API}/releases/{old['id']}")

    _, release = request("POST", f"{API}/releases", body={
        "tag_name": tag,
        "target_commitish": args.commit,
        "name": tag,
        "body": notes,
        "draft": True,
    })
    for path in archives + [sums]:
        kind = "text/plain" if path == sums else "application/gzip"
        url = f"{UPLOADS}/releases/{release['id']}/assets?name={urllib.parse.quote(path.name)}"
        print(f"uploading {path.name} ({path.stat().st_size} bytes)")
        request("POST", url, data=path.read_bytes(), content_type=kind)

    _, uploaded = request("GET", f"{API}/releases/{release['id']}/assets?per_page=100")
    names = sorted(a["name"] for a in uploaded if a["state"] == "uploaded")
    expected = sorted(p.name for p in archives + [sums])
    if names != expected:
        sys.exit(f"draft assets {names} != expected {expected}; leaving the draft unpublished")

    if args.draft_only:
        print(f"draft only: left {release['html_url']} unpublished (no tag created)")
        return

    # A tag created since the first check would silently take precedence over
    # target_commitish, so look again right before publishing.
    ensure_unreleased(args.version)
    _, published = request("PATCH", f"{API}/releases/{release['id']}",
                           body={"draft": False, "make_latest": "true"})
    print(f"published {published['html_url']} at {args.commit}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("check")
    p.add_argument("--version", required=True)
    p.set_defaults(func=check)
    p = sub.add_parser("publish")
    p.add_argument("--version", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--dist", default=str(ROOT / "dist"))
    p.add_argument("--draft-only", action="store_true",
                   help="upload to the draft release but do not publish it")
    p.set_defaults(func=publish)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
