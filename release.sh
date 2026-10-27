#!/bin/bash
# Requires an installed Developer ID certificate and a notarytool Keychain profile.
set -euo pipefail
cd "$(dirname "$0")"
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set NOTARY_KEYCHAIN_PROFILE to an existing notarytool Keychain profile}"
case "$CODESIGN_IDENTITY" in
  'Developer ID Application:'*) ;;
  *) echo 'A Developer ID Application certificate is required.' >&2; exit 1 ;;
esac
./build.sh --universal --release
ditto -c -k --keepParent build/MacSweep.app build/MacSweep-notary.zip
xcrun notarytool submit build/MacSweep-notary.zip --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait --output-format json > build/notary-result.json
/usr/bin/plutil -extract status raw -o - build/notary-result.json | /usr/bin/grep -qx Accepted
xcrun stapler staple build/MacSweep.app
xcrun stapler validate build/MacSweep.app
codesign --verify --strict --verbose=2 build/MacSweep.app
spctl --assess --type execute --verbose=2 build/MacSweep.app
ditto -c -k --keepParent build/MacSweep.app build/MacSweep.zip
(cd build && shasum -a 256 MacSweep.zip > SHA256SUMS.txt)
echo 'Verified, notarized release: build/MacSweep.zip'
