#!/bin/sh
# Regenerate addons/p4godot/README.md from the root README. The addon copy
# ships in release zips without docs/, so image paths become absolute URLs.
cd "$(dirname "$0")/.." || exit 1
sed 's#src="docs/images/#src="https://raw.githubusercontent.com/jase-perf/P4Godot/main/docs/images/#g; s#](docs/images/#](https://raw.githubusercontent.com/jase-perf/P4Godot/main/docs/images/#g' \
  README.md > addons/p4godot/README.md
echo "addons/p4godot/README.md regenerated"
