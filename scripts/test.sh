#!/bin/bash
# The test executable has no app entry point and cannot register a login item.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build/tests"
mkdir -p "$BUILD_DIR/ModuleCache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(/usr/bin/find "$ROOT/Calendar/Core" -type f -name '*.swift' | /usr/bin/sort)
for SUITE in CoreTests SettingsTests GroupLegendTests GroupNavigationTests WidgetStorageTests WidgetLinkTests ScheduleTests ISTUNetworkPolicyTests ISTUParserTests ScheduleImportTests ISTUControllerTests; do
    SUITE_SOURCES=("${SOURCES[@]}")
    if [[ "$SUITE" == "ISTUControllerTests" ]]; then
        SUITE_SOURCES+=("$ROOT/Calendar/App/ISTUImportController.swift" "$ROOT/Calendar/App/ISTUFetchClient.swift")
    fi
    xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-macosx27.0" \
        -swift-version 6 -parse-as-library \
        -module-cache-path "$BUILD_DIR/ModuleCache" \
        "${SUITE_SOURCES[@]}" "$ROOT/Tests/$SUITE.swift" -o "$BUILD_DIR/$SUITE"
    "$BUILD_DIR/$SUITE"
done
