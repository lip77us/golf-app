#!/usr/bin/env bash
# Build the static halved.golf site. Files are placed at the ROOT (index.html
# at the top level), excluding the build tooling and macOS junk.
#
# Out:  dist/                     -> what `npx wrangler deploy` publishes
#       ~/Downloads/halved-site.zip -> the same thing, for the dashboard
#
# halved.golf is a Cloudflare WORKER with static assets, not a Pages project.
# See wrangler.jsonc.
set -euo pipefail

cd "$(dirname "$0")"          # the website/ directory
out="$HOME/Downloads/halved-site.zip"

# **Before the audit, not after.** dist/ is a byte-copy of the site sitting
# inside website/, so a stale one from the last run doubles every page:
# build-seo.py walks the tree, counted 60 pages instead of 30 and failed with
# 95 duplicate-title errors (3 Nov 2026).
rm -rf dist

# Refresh the SEO block + sitemap, and stop here if the audit finds errors —
# a broken link or a missing canonical should never reach the live site.
./build-seo.py

rm -f "$out"
# `.wrangler/` is wrangler's local cache, written into whatever directory it
# is run from. It holds the Cloudflare account id — not a credential, but not
# something to publish either, and it appeared here the first time anyone ran
# wrangler from website/ (3 Nov 2026). Excluded rather than relied on being
# absent, because the next `wrangler` command recreates it.
zip -rX "$out" . \
  -x '.DS_Store' '*/.DS_Store' 'build-zip.sh' 'build-guides.py' \
     'build-seo.py' 'seo-manifest.json' 'SEO.md' \
     '.wrangler/*' '.wrangler' 'dist/*' 'dist' 'wrangler.jsonc' >/dev/null

# The same artifact as a DIRECTORY, which is what `wrangler deploy` takes.
# Unzipped from the zip rather than copied, so the two can never disagree
# about what is excluded — one exclusion list, checked once, above.
unzip -q "$out" -d dist

echo "Built dist/ and $out"
unzip -l "$out"
