#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# This app has no third-party headers. Do not let shell include paths or an
# unrelated SDK override the developer tools selected by xcode-select (or
# DEVELOPER_DIR). Keep TOOLCHAINS from selecting a different Swift compiler.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH SDKROOT TOOLCHAINS
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
swiftc=$(/usr/bin/xcrun --sdk macosx --find swiftc)

# Exclude default system search paths such as /usr/local/include, where old
# Darwin headers can shadow the SDK (issue #1). Keep compiler builtin headers
# before SDK headers: stddef.h and friends depend on that ordering.
exec "$swiftc" -O -sdk "$sdk" \
    -Xcc -nostdlibinc \
    -Xcc -idirafter -Xcc "$sdk/usr/include" \
    -Xcc -iframework -Xcc "$sdk/System/Library/Frameworks" \
    "$project_dir/main.swift" -o "${1:-$project_dir/crt-xdr}"
