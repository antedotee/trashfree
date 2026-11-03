#!/bin/zsh
# Usage: scripts/package.sh
# Builds a universal release of TrashFree.app and zips it to build/TrashFree.zip, the
# file the GitHub release and the website's download button serve. The zip unpacks to a
# TrashFree folder holding the app and the install steps.
#
# The zip is made from a copy outside the repo: iCloud tags bundles in the synced Desktop
# with Finder info, and a bundle carrying it fails signature verification once unzipped.
set -euo pipefail
root="${0:A:h:h}"
"$root/scripts/bundle.sh" release >/dev/null
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/TrashFree"
ditto --norsrc --noextattr "$root/build/TrashFree.app" "$stage/TrashFree/TrashFree.app"
cp "$root/Resources/How to Install TrashFree.txt" "$stage/TrashFree/"
xattr -cr "$stage/TrashFree"
codesign --verify --deep --strict "$stage/TrashFree/TrashFree.app"
rm -f "$root/build/TrashFree.zip"
ditto -c -k --norsrc --noextattr --keepParent "$stage/TrashFree" "$root/build/TrashFree.zip"
echo "$root/build/TrashFree.zip"
