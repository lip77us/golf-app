#!/usr/bin/env bash
# Build the static halved.golf site into a zip for Cloudflare Pages upload.
# Files are placed at the ZIP ROOT (index.html at the top level), excluding
# macOS junk and this script itself. Output: <repo>/halved-site.zip
set -euo pipefail

cd "$(dirname "$0")"          # the website/ directory
out="../halved-site.zip"

rm -f "$out"
zip -rX "$out" . \
  -x '.DS_Store' '*/.DS_Store' 'build-zip.sh' >/dev/null

echo "Built $(cd .. && pwd -P)/halved-site.zip"
unzip -l "$out"
