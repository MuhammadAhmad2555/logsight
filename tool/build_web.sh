#!/usr/bin/env bash
# Builds the LogSight web app into build/web.
# Hosting serves index.html for app links (/p/<id>/logs):
#   - Cloudflare Workers: wrangler.jsonc sets not_found_handling = single-page-application
#   - Cloudflare Pages:   automatic (no 404.html in the build)
#   - Firebase Hosting:   firebase.json rewrites ** to /index.html
set -euo pipefail
cd "$(dirname "$0")/.."
flutter build web --release "$@"
echo "Built: $(pwd)/build/web"
