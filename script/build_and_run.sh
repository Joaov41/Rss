#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DERIVED_DATA_PATH="${RSS_MAC_DERIVED_DATA_PATH:-/Users/johnval/Library/Developer/Xcode/DerivedData/RSSReaderMacYouTube}"

xcodebuild \
  -project "${PROJECT_ROOT}/RSSReaderApp.xcodeproj" \
  -scheme "RSSReaderApp (macOS)" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  build

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Debug/RSSReaderApp.app"
open "${APP_PATH}"
