#!/usr/bin/env bash
# Builds the LogSight web app for hosting (Cloudflare Pages / Firebase Hosting).
# Flutter doesn't copy web/_redirects into the build, so this script does.
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build web --release "$@"
cp web/_redirects build/web/_redirects
echo "Ready to upload: $(pwd)/build/web  (includes _redirects for path URLs)"
