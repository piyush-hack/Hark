#!/bin/bash
# Builds a shareable Hark and, with --publish, releases it on GitHub, where every installed copy
# (0.2.0 and later) finds it and offers the update in a window.
#
#   scripts/release.sh 0.3.0                                # build dist/Hark-0.3.0.dmg and .zip only
#   scripts/release.sh 0.3.0 --publish                      # also commit the version, tag v0.3.0, push, release
#   scripts/release.sh 0.3.0 --publish --notes-file new.md  # what's new, shown in the update window
#
# Without --notes-file the notes are the commit subjects since the last release.
# Releases must be signed by the same identity every time (the local "Hark Local Signing" one, or
# HARK_SIGN_IDENTITY): the updater only installs a build signed like the copy it replaces, and macOS
# keeps each person's Microphone and Accessibility grants only while the signature stays the same.
# Publishing uses the gh account HARK_GH_USER (default: the repository's owner) without switching accounts.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "Usage: scripts/release.sh <major.minor.patch> [--publish] [--notes-file FILE]" >&2; exit 64; }
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
shift
PUBLISH=0
NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) PUBLISH=1 ;;
    --notes-file) [ $# -ge 2 ] || usage; NOTES_FILE="$2"; shift ;;
    *) usage ;;
  esac
  shift
done
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || { echo "No notes file at $NOTES_FILE" >&2; exit 1; }

PLIST=Resources/Info.plist
TAG="v$VERSION"
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
REPO="$(git remote get-url origin | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##')"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$PUBLISH" = 1 ]; then
  [ -z "$(git status --porcelain -- . ":!$PLIST")" ] || { echo "Commit or stash your changes first." >&2; exit 1; }
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || { echo "$TAG already exists." >&2; exit 1; }
  GH_USER="${HARK_GH_USER:-${REPO%%/*}}"
  GH_TOKEN="$(gh auth token --user "$GH_USER" 2>/dev/null)" || { echo "Log in with: gh auth login (as $GH_USER)" >&2; exit 1; }
  export GH_TOKEN
  case "$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission)" in
    ADMIN|MAINTAIN|WRITE) ;;
    *) echo "gh account $GH_USER can't publish to $REPO. Set HARK_GH_USER to one that can." >&2; exit 1 ;;
  esac
fi

# Installed copies only offer versions newer than their own.
if [ "$VERSION" != "$CURRENT" ]; then
  NEWEST="$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  [ "$NEWEST" = "$VERSION" ] || { echo "$VERSION is older than the current $CURRENT." >&2; exit 1; }
  # Edit the two values in place (PlistBuddy would reformat the whole file).
  sed -i '' -e "/<key>CFBundleShortVersionString<\/key>/{n;s#<string>.*</string>#<string>$VERSION</string>#;}" \
            -e "/<key>CFBundleVersion<\/key>/{n;s#<string>.*</string>#<string>$((BUILD + 1))</string>#;}" "$PLIST"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION" ] || { echo "Couldn't set the version in $PLIST" >&2; exit 1; }
  echo "→ Version $CURRENT → $VERSION"
fi

APP="dist/Hark.app"
HARK_APP="$APP" scripts/build-app.sh
if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "Refusing to release an ad-hoc signed build: updates and permissions need a stable signature." >&2
  exit 1
fi

echo "→ Packaging…"
ZIP="dist/Hark-$VERSION.zip"
DMG="dist/Hark-$VERSION.dmg"
rm -f "$ZIP" "$DMG"
# ditto keeps the bundle's signature intact (zip -r can break it).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
mkdir "$TMP/dmg"
ditto "$APP" "$TMP/dmg/Hark.app"
ln -s /Applications "$TMP/dmg/Applications"
hdiutil create -volname "Hark $VERSION" -srcfolder "$TMP/dmg" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$APP"
echo "✓ $DMG  (share this)"
echo "✓ $ZIP  (the in-app updater downloads this)"

[ "$PUBLISH" = 1 ] || { echo "Publish with: scripts/release.sh $VERSION --publish"; exit 0; }

echo "→ Publishing $TAG to github.com/$REPO…"
git add "$PLIST"
git diff --cached --quiet || git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Hark $VERSION"
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -q origin HEAD "$TAG"

NOTES="$TMP/notes.md"
if [ -n "$NOTES_FILE" ]; then
  cat "$NOTES_FILE" > "$NOTES"
else
  PREVIOUS="$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)"
  { echo "## What's new"; git log --no-merges --pretty='- %s' ${PREVIOUS:+"$PREVIOUS..$TAG^"} | grep -v '^- Release v' | head -30 || true; } > "$NOTES"
fi
# Everything below the --- line is for new users; the update window shows only what's above it.
cat >> "$NOTES" <<EOF

---

**New to Hark?** Download **Hark-$VERSION.dmg**, open it, and drag Hark to Applications. Hark is signed but not notarized by Apple, so the first time you open it macOS will say it can't verify it. Click **Done** (not Move to Trash, which deletes it), then:
- **macOS 15 and later:** open System Settings → Privacy & Security, scroll down, and click **Open Anyway** next to Hark.
- **macOS 14:** Control-click Hark in Applications, choose **Open**, then **Open** again.

You need an Apple Silicon Mac with macOS 14+, and [Claude Code](https://claude.com/claude-code) signed in (Hark's brain). After this, Hark updates itself: new versions appear in a window inside the app.
EOF
gh release create "$TAG" "$DMG" "$ZIP" --repo "$REPO" --title "Hark $VERSION" --notes-file "$NOTES" --verify-tag
echo "✓ Released https://github.com/$REPO/releases/tag/$TAG"
