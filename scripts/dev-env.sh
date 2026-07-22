#!/bin/bash
# Source this before building: `source scripts/dev-env.sh`
#
# Works around a broken Command Line Tools installation seen in the wild
# (CLT 26.x with stale files from older versions left behind), which breaks
# `swift build` in three independent ways. On healthy toolchains this script
# is a no-op. It never modifies anything outside ~/.cache/wisp.
#
# After sourcing, build with:  swift build $WISP_SWIFT_FLAGS

WISP_CACHE="$HOME/.cache/wisp"
CLT="/Library/Developer/CommandLineTools"
export WISP_SWIFT_FLAGS=""

# Probe: can swiftc compile a Foundation import at all?
_wisp_probe() {
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'import Foundation\n' > "$tmpdir/probe.swift"
    swiftc ${WISP_VFS_FLAGS:-} -o "$tmpdir/probe" "$tmpdir/probe.swift" 2>"$tmpdir/err"
    local probe_status=$?
    rm -rf "$tmpdir"
    return $probe_status
}

if ! _wisp_probe; then
    mkdir -p "$WISP_CACHE"

    # 1. Stale SDK interfaces vs newer compiler ("SDK is not supported").
    export SWIFT_IGNORE_SWIFTMODULE_REVISION=1

    # 2. Duplicate SwiftBridging module inside CLT's include dir — mask the
    #    redundant copy with a VFS overlay.
    if [ -f "$CLT/usr/include/swift/bridging.modulemap" ] && \
       grep -q "SwiftBridging" "$CLT/usr/include/swift/module.modulemap" 2>/dev/null; then
        touch "$WISP_CACHE/empty.modulemap"
        cat > "$WISP_CACHE/mask-bridging.yaml" <<EOF
{
  "version": 0,
  "roots": [
    { "name": "$CLT/usr/include/swift/bridging.modulemap", "type": "file", "external-contents": "$WISP_CACHE/empty.modulemap" }
  ]
}
EOF
        WISP_VFS_FLAGS="-vfsoverlay $WISP_CACHE/mask-bridging.yaml"
        export WISP_SWIFT_FLAGS="-Xswiftc -vfsoverlay -Xswiftc $WISP_CACHE/mask-bridging.yaml"
    fi

    # 3. Stale PackageDescription private interfaces break manifest linking —
    #    point SPM at a cleaned copy of the manifest libraries.
    if ls "$CLT/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/"*.private.swiftinterface >/dev/null 2>&1; then
        if [ ! -d "$WISP_CACHE/swiftpm-libs" ]; then
            cp -R "$CLT/usr/lib/swift/pm" "$WISP_CACHE/swiftpm-libs"
            rm -f "$WISP_CACHE/swiftpm-libs/ManifestAPI/PackageDescription.swiftmodule/"*.private.swiftinterface
            rm -f "$WISP_CACHE/swiftpm-libs/PluginAPI/PackagePlugin.swiftmodule/"*.private.swiftinterface
        fi
        export SWIFTPM_CUSTOM_LIBS_DIR="$WISP_CACHE/swiftpm-libs"
    fi

    if _wisp_probe; then
        echo "dev-env: applied broken-CLT workarounds (cache: $WISP_CACHE)"
    else
        echo "dev-env: WARNING — swiftc still failing; try reinstalling Command Line Tools" >&2
    fi
fi
unset -f _wisp_probe
