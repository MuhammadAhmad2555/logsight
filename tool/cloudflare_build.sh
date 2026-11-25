#!/usr/bin/env bash
# Cloudflare Pages build for LogSight (Flutter web).
#   Build command:          bash tool/cloudflare_build.sh
#   Build output directory: build/web
# Cloudflare's build image has no Flutter, so this installs a pinned version.
set -euo pipefail
cd "$(dirname "$0")/.."

FLUTTER_VERSION="${FLUTTER_VERSION:-3.44.8}"
if ! command -v flutter >/dev/null 2>&1; then
  FLUTTER_DIR="${HOME}/flutter-${FLUTTER_VERSION}"
  if [ ! -x "${FLUTTER_DIR}/bin/flutter" ]; then
    git clone --depth 1 --branch "${FLUTTER_VERSION}" https://github.com/flutter/flutter.git "${FLUTTER_DIR}"
  fi
  export PATH="${FLUTTER_DIR}/bin:${PATH}"
fi

flutter config --no-analytics >/dev/null 2>&1 || true
flutter --version
flutter pub get
bash tool/build_web.sh
