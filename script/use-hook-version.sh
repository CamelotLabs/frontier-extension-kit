#!/usr/bin/env bash
# Point the kit at another FactoryHook version published in FrontierFun/factory-hook.
# Usage: script/use-hook-version.sh v1.2
set -euo pipefail

version="${1:?usage: script/use-hook-version.sh <version folder, e.g. v1.2>}"
cd "$(dirname "$0")/.."

# v1.1 is the oldest supported version: it fixes the volatility tracker (L-04) and adds the
# IExtensionHost views HookGated reads.
if [ "$(printf '%s\nv1.1\n' "$version" | sort -V | head -n1)" != "v1.1" ]; then
  echo "$version is not supported: build against v1.1 or later." >&2
  exit 1
fi

git -C lib/factory-hook fetch --quiet origin
git -C lib/factory-hook checkout --quiet origin/main

if [ ! -d "lib/factory-hook/$version" ]; then
  echo "lib/factory-hook/$version does not exist. Available:" >&2
  ls -d lib/factory-hook/v*/ | grep -v '/v1\.0/' >&2
  exit 1
fi

sed -i.bak -E "s#lib/factory-hook/v[0-9]+\.[0-9]+/#lib/factory-hook/$version/#g" remappings.txt
rm remappings.txt.bak

echo "Now building against FactoryHook $version ($(git -C lib/factory-hook rev-parse --short HEAD))."
forge build
forge test
