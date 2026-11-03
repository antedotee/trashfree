#!/bin/zsh
# Usage: scripts/signing-identity.sh <app bundle>
# Signs a local build with a stable self-signed identity, creating it on first use.
#
# macOS privacy grants (Files and Folders, Full Disk Access) belong to an app's
# designated requirement. An ad-hoc signature's requirement is the build's own hash, so
# every rebuild looked like a new app and the Downloads/Desktop/Documents prompts came
# back on every scan. Signed with the same certificate, every build has the requirement
# `identifier "dev.kartikyadav.trashfree" and certificate leaf = H"…"`, and the
# grants stay.
#
# The certificate lives in its own keychain under .signing/ (gitignored), never in the
# login keychain. codesign only looks in the keychain search list, so the dev keychain is
# added for the one signing call and the list is restored right after. Delete .signing/
# to remove the identity; the next build creates a new one and macOS asks once more.
set -euo pipefail
root="${0:A:h:h}"
app="$1"
dir="$root/.signing"
keychain="$dir/dev.keychain-db"
password="trashfree-dev"
name="TrashFree Local Signing"

if [[ ! -f "$keychain" ]]; then
  mkdir -p "$dir"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  # Keychain import only understands the legacy PKCS#12 ciphers.
  openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/id.p12" -passout pass:"$password"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security import "$tmp/id.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
fi

security unlock-keychain -p "$password" "$keychain"
identity="$(security find-identity "$keychain" | awk '/\)/ { print $2; exit }')"
[[ -n "$identity" ]] || { echo "no identity in $keychain" >&2; exit 1; }

search=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
restore() { security list-keychains -d user -s "${search[@]}"; }
trap restore EXIT
security list-keychains -d user -s "${search[@]}" "$keychain"
# The repo can live in an iCloud-synced folder, whose File Provider tags a new bundle
# with Finder info a moment after it appears; codesign refuses those attributes, so
# clear them and retry briefly.
for attempt in 1 2 3 4 5; do
  xattr -cr "$app"
  codesign --force --sign "$identity" "$app" 2>/dev/null && exit 0
  sleep 1
done
codesign --force --sign "$identity" "$app"
