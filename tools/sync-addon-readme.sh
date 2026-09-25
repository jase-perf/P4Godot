#!/bin/sh
# Regenerate addons/p4godot/README.md from the root README. The addon copy
# ships in release zips without docs/, so every docs/ path becomes an absolute
# URL: images to raw.githubusercontent.com, pages to the repo's blob view.
# Images are rewritten first, so the general docs/ rule can't catch them twice.
cd "$(dirname "$0")/.." || exit 1
sed -e 's#src="docs/images/#src="https://raw.githubusercontent.com/jase-perf/P4Godot/main/docs/images/#g' \
    -e 's#](docs/images/#](https://raw.githubusercontent.com/jase-perf/P4Godot/main/docs/images/#g' \
    -e 's#](docs/#](https://github.com/jase-perf/P4Godot/blob/main/docs/#g' \
    -e 's#](CONTRIBUTING.md#](https://github.com/jase-perf/P4Godot/blob/main/CONTRIBUTING.md#g' \
  README.md > addons/p4godot/README.md
echo "addons/p4godot/README.md regenerated"
