#!/bin/zsh

set -euo pipefail

# Use a workspace-local DerivedData path to avoid permissions issues.
DERIVED_DIR="$(pwd)/DerivedData"
mkdir -p "$DERIVED_DIR"

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  install \
  -project Notation.xcodeproj \
  -scheme Notation \
  -configuration Deployment \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  -quiet
