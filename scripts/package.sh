#!/bin/zsh
# Usage: scripts/package.sh
# Builds a universal release of TrashFree.app and zips it to build/TrashFree.zip, the
# file the GitHub release and the website's download button serve.
#
# The zip is made from a copy outside the repo: iCloud tags bundles in the synced Desktop
# with Finder info, and a bundle carrying it fails signature verification once unzipped.
set -euo pipefail
root="${0:A:h:h}"
"$root/scripts/bundle.sh" release >/dev/null
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr "$root/build/TrashFree.app" "$stage/TrashFree.app"
xattr -cr "$stage/TrashFree.app"
codesign --verify --deep --strict "$stage/TrashFree.app"
rm -f "$root/build/TrashFree.zip"
ditto -c -k --norsrc --noextattr --keepParent "$stage/TrashFree.app" "$root/build/TrashFree.zip"
echo "$root/build/TrashFree.zip"
