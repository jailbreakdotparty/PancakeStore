#!/bin/sh
set -eu

# Prepare the pinned Unicorn 2.1.4 source with the TCI (Tiny Code Interpreter)
# backend. TCI executes translated guest operations in C and does not emit
# executable host pages, which avoids iOS 26/27 TXM invalid-page termination.
TOOLS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR=${1:?usage: prepare-unicorn-tci.sh BUILD_DIR}
SOURCE_DIR="$BUILD_DIR/unicorn-2.1.4"
ARCHIVE="$BUILD_DIR/unicorn.tar.gz"

curl -fL --retry 3 https://github.com/unicorn-engine/unicorn/archive/refs/tags/2.1.4.tar.gz -o "$ARCHIVE"
echo "ea8863f095a0136388694e5a6063afd9bb7650e30243dd6251af59c5ce5601f4  $ARCHIVE" | shasum -a 256 -c -
tar -xzf "$ARCHIVE" -C "$BUILD_DIR"

# These four commits are the TCI backport maintained against Unicorn 2.1.4.
# Keep the exact commit IDs pinned so the generated interpreter is reproducible.
PATCH_COMMITS='795ba9aa0c02bf22cf432f27fddceadbd30378d3
90e62bcb22f4d068cc4185037b83419918c81a15
dc23827e0f649d767467b9bc8bd415ddf89b5eff
53471ef9cf480fab094bf13db3e5d2f9e2c30dc5'
index=0
printf '%s\n' "$PATCH_COMMITS" | while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    index=$((index + 1))
    patch_file="$BUILD_DIR/unicorn-tci-$index.patch"
    curl -fL --retry 3 "https://github.com/Naville/unicorn/commit/$commit.patch" -o "$patch_file"
    echo "[*] Applying pinned Unicorn TCI patch $index/4: $commit"
    if [ "$index" -eq 2 ]; then
        # Unicorn 2.1.4 has a commented-out MESSAGE block in CMakeLists.txt
        # which makes the original commit's second CMake hunk fail. Apply
        # those CMake edits by stable anchors and patch qemu/configure alone.
        awk '/^diff --git a\/qemu\/configure / { copy=1 } copy { print }' \
            "$patch_file" > "$BUILD_DIR/unicorn-tci-2-qemu.patch"
        if [ ! -s "$BUILD_DIR/unicorn-tci-2-qemu.patch" ]; then
            echo "Could not extract qemu/configure section from TCI patch 2." >&2
            exit 1
        fi
        patch -p1 -d "$SOURCE_DIR" < "$BUILD_DIR/unicorn-tci-2-qemu.patch"
        python3 - "$SOURCE_DIR/CMakeLists.txt" <<'PYTHON'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
option = 'option(UNICORN_INTERPRETER "Use interpreter mode" OFF)'
if option not in text:
    anchor = 'option(UNICORN_TRACER "Trace unicorn execution" OFF)'
    if anchor not in text:
        raise SystemExit('Could not find UNICORN_TRACER anchor in CMakeLists.txt')
    text = text.replace(anchor, anchor + '\n' + option, 1)

mode = '''    set(UNICORN_EXECUTION_MODE "")
    if(UNICORN_INTERPRETER)
        set(UNICORN_EXECUTION_MODE "--enable-interpreter")
    else()
        set(UNICORN_EXECUTION_MODE "--disable-interpreter")
    endif()
'''
if 'set(UNICORN_EXECUTION_MODE "")' not in text:
    anchor = '    execute_process(COMMAND sh ${CMAKE_CURRENT_SOURCE_DIR}/qemu/configure'
    if anchor not in text:
        raise SystemExit('Could not find qemu/configure execute_process anchor in CMakeLists.txt')
    text = text.replace(anchor, mode + anchor, 1)

needle = '        ${TARGET_LIST}\n        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}'
if needle not in text:
    raise SystemExit('Could not find TARGET_LIST argument block in CMakeLists.txt')
if '        ${UNICORN_EXECUTION_MODE}\n' not in text:
    text = text.replace(needle, '        ${TARGET_LIST}\n        ${UNICORN_EXECUTION_MODE}\n        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}', 1)
path.write_text(text)
PYTHON
    else
        patch -p1 -d "$SOURCE_DIR" < "$patch_file"
    fi
done

# Fail closed if the resulting tree is not the intended interpreter build.
grep -q 'option(UNICORN_INTERPRETER "Use interpreter mode" OFF)' "$SOURCE_DIR/CMakeLists.txt"
grep -q 'set(UNICORN_TARGET_ARCH "tci")' "$SOURCE_DIR/CMakeLists.txt"
grep -q 'CONFIG_TCG_INTERPRETER=y' "$SOURCE_DIR/qemu/configure"
test -s "$SOURCE_DIR/qemu/tcg/tci.c"
test -s "$SOURCE_DIR/qemu/tcg/tci/tcg-target.h"
test -s "$SOURCE_DIR/qemu/tcg/tci/tcg-target.inc.c"

echo "[*] Unicorn 2.1.4 TCI source prepared."
