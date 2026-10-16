#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_DIR="$ROOT/build/widget-preview"
mkdir -p "$PREVIEW_DIR/ModuleCache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=()
while IFS= read -r SOURCE; do SOURCES+=("$SOURCE"); done < <(/usr/bin/find "$ROOT/Calendar/Core" -type f -name '*.swift' | /usr/bin/sort)
xcrun swiftc -sdk "$SDK" -target "$(uname -m)-apple-macosx27.0" \
    -swift-version 6 -parse-as-library \
    -module-cache-path "$PREVIEW_DIR/ModuleCache" \
    "${SOURCES[@]}" "$ROOT/CalendarWidget/CalendarWidgetView.swift" "$ROOT/Tests/WidgetPreview.swift" \
    -o "$PREVIEW_DIR/WidgetPreview"
"$PREVIEW_DIR/WidgetPreview" "$PREVIEW_DIR"
