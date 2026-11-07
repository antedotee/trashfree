#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed, SwiftPM does not find
# the Swift Testing framework, and the tools ship its Foundation overlay without a module,
# so point the compiler at the framework and skip cross-import overlays. With Xcode
# installed, plain `swift test` works too.
set -euo pipefail
cd "${0:A:h:h}"
frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "$(xcode-select -p)" == /Library/Developer/CommandLineTools && -d $frameworks/Testing.framework ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc $frameworks \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker $frameworks \
    -Xlinker -rpath -Xlinker $frameworks \
    "$@"
fi
exec swift test "$@"
