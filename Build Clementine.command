#!/bin/bash
cd "$(dirname "$0")"
clear
echo "Building Clementine…"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. An installer window will open."
  echo "When it finishes, double-click 'Build Clementine' again."
  xcode-select --install
  echo "NEEDS_CLT" > build.log
  exit 0
fi
/bin/bash ./build.sh 2>&1 | tee build.log
echo
echo "You can close this window."
