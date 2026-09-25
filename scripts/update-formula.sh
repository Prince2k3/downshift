#!/bin/sh
# Points packaging/homebrew/dshift.rb at a pushed tag: scripts/update-formula.sh 0.4.0
# Copy the result to Formula/dshift.rb in Prince2k3/homebrew-tap.
set -eu
cd "$(dirname "$0")/.."
version=${1:?usage: $0 <version>}
url="https://github.com/Prince2k3/downshift/archive/refs/tags/v$version.tar.gz"
sha=$(curl -fsSL "$url" | shasum -a 256 | cut -d' ' -f1)
sed -i '' -e "s|^  url \".*\"|  url \"$url\"|" -e "s|^  sha256 \".*\"|  sha256 \"$sha\"|" packaging/homebrew/dshift.rb
echo "v$version  $sha"
