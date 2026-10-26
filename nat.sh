#!/usr/bin/env bash
# https://zylinski.se/odin-raylib-web/
# the below code in this file is unchanged from Karl Zylinski's odin-raylib-web template
set -euo pipefail

OUT_DIR="build/local"
mkdir -p $OUT_DIR
odin build src/main_desktop \
	-vet -strict-style -debug -out:$OUT_DIR/game_desktop.bin
cp -R ./assets/ ./$OUT_DIR/
echo "Desktop build created in ${OUT_DIR}"