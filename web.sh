#!/usr/bin/env bash
# https://zylinski.se/odin-raylib-web/
# the below code in this file is slightly changed from Karl Zylinski's odin-raylib-web template
set -euo pipefail

# Point this to where you installed emscripten. Optional on systems that already
# have `emcc` in the path.
EMSCRIPTEN_SDK_DIR="$HOME/repos/emsdk"
OUT_DIR="build/web"

rm -rf $OUT_DIR
mkdir -p $OUT_DIR

export EMSDK_QUIET=1
[[ -f "$EMSCRIPTEN_SDK_DIR/emsdk_env.sh" ]] && . "$EMSCRIPTEN_SDK_DIR/emsdk_env.sh"

# Note RAYLIB_WASM_LIB=env.o -- env.o is an internal WASM object file. You can
# see how RAYLIB_WASM_LIB is used inside <odin>/vendor/raylib/raylib.odin.
#
# The emcc call will be fed the actual raylib library file. That stuff will end
# up in env.o
#
# Note that there is a rayGUI equivalent: -define:RAYGUI_WASM_LIB=env.o
echo "[1/2] Odin compile web debug build -> $OUT_DIR/game.wasm.o"
odin build src/main_web \
    -target:js_wasm32 \
    -build-mode:obj \
    -define:RAYLIB_WASM_LIB=env.o \
    -vet \
    -strict-style \
    -debug \
    -out:"$OUT_DIR/game.wasm.o"

ODIN_PATH=$(odin root)

cp $ODIN_PATH/core/sys/wasm/js/odin.js $OUT_DIR
cp glue/net.js $OUT_DIR
cp glue/input.js $OUT_DIR

files="$OUT_DIR/game.wasm.o ${ODIN_PATH}/vendor/raylib/wasm/libraylib.a ${ODIN_PATH}/vendor/raylib/wasm/libraygui.a"

# index_template.html contains the javascript code that calls the procedures in src/main_web/main_web.odin
# For debugging: Add `-g` to `emcc` (gives better error callstack in chrome)
# For audio: Add -sEXPORTED_RUNTIME_METHODS=['HEAPF32'] 
echo "[2/2] emcc link web debug build -> $OUT_DIR/index.{html,js,wasm}"
emcc -o $OUT_DIR/index.html $files \
    -sUSE_GLFW=3 \
    -sWASM_BIGINT \
    -sWARN_ON_UNDEFINED_SYMBOLS=0 \
    -sASYNCIFY \
    -sALLOW_MEMORY_GROWTH=1 \
    -sFORCE_FILESYSTEM=1 \
    -g \
    -sASSERTIONS \
    --shell-file src/main_web/index_template.html \
    --preload-file assets

rm $OUT_DIR/game.wasm.o

echo "Web build created in ${OUT_DIR}"