#!/bin/bash
# Uses only installed local tools. Never starts an app or registers an extension.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${CALENDAR_BUILD_DIR:-$ROOT/build}"
APP="$BUILD_DIR/Calendar.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
DEPLOYMENT_TARGET=27.0
ARCHS="$(uname -m)"
CHECK_WIDGET_ONLY=false
CHECK_FETCHER_ONLY=false
for OPTION in "$@"; do
    case "$OPTION" in
        --universal) ARCHS="arm64 x86_64" ;;
        --check-widget) CHECK_WIDGET_ONLY=true ;;
        --check-fetcher) CHECK_FETCHER_ONLY=true ;;
        *) echo "Использование: ./scripts/build-offline.sh [--universal] [--check-widget | --check-fetcher]" >&2; exit 2 ;;
    esac
done

if $CHECK_WIDGET_ONLY && $CHECK_FETCHER_ONLY; then
    echo "Выберите только одну отдельную проверку расширения." >&2
    exit 2
fi

build_fetcher_service() {
    local FETCHER_BUNDLE="$1"
    mkdir -p "$FETCHER_BUNDLE/Contents/MacOS" "$BUILD_DIR/FetcherModuleCache"
    local FETCHER_BINARIES=()
    local FETCHER_ARCH
    local FETCHER_BINARY
    for FETCHER_ARCH in $ARCHS; do
        FETCHER_BINARY="$BUILD_DIR/ScheduleFetcher-$FETCHER_ARCH"
        xcrun swiftc -sdk "$SDK" -target "$FETCHER_ARCH-apple-macosx$DEPLOYMENT_TARGET" \
            -swift-version 6 -parse-as-library -O -module-name ScheduleFetcher \
            -module-cache-path "$BUILD_DIR/FetcherModuleCache" -framework Foundation -framework Security \
            "$ROOT/Calendar/Core/ISTUFetchProtocol.swift" "$ROOT/ScheduleFetcherXPC/FetcherService.swift" -o "$FETCHER_BINARY"
        FETCHER_BINARIES+=("$FETCHER_BINARY")
    done
    if [[ ${#FETCHER_BINARIES[@]} -gt 1 ]]; then
        xcrun lipo -create "${FETCHER_BINARIES[@]}" -output "$FETCHER_BUNDLE/Contents/MacOS/ScheduleFetcher"
    else
        cp "${FETCHER_BINARIES[0]}" "$FETCHER_BUNDLE/Contents/MacOS/ScheduleFetcher"
    fi
    cp "$ROOT/ScheduleFetcherXPC/Resources/Info.plist" "$FETCHER_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ScheduleFetcher' "$FETCHER_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ru.local.GoldenGateCalendar.ScheduleFetcher' "$FETCHER_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$FETCHER_BUNDLE/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --options runtime \
        --entitlements "$ROOT/ScheduleFetcherXPC/Resources/ScheduleFetcher.entitlements" "$FETCHER_BUNDLE"
}

if $CHECK_FETCHER_ONLY; then
    CHECK_DIR="$BUILD_DIR/fetcher-check"
    CHECK_APP="$CHECK_DIR/FetchCheck.app"
    mkdir -p "$CHECK_APP/Contents/MacOS" "$CHECK_DIR/ModuleCache"
    build_fetcher_service "$CHECK_APP/Contents/XPCServices/ScheduleFetcher.xpc"
    CHECK_BINARIES=()
    for ARCH in $ARCHS; do
        CHECK_BINARY="$CHECK_DIR/FetchCheck-$ARCH"
        xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
            -swift-version 6 -parse-as-library -O -module-name FetchCheck \
            -module-cache-path "$CHECK_DIR/ModuleCache" -framework Foundation -framework Security \
            "$ROOT/Calendar/Core/ISTUFetchProtocol.swift" "$ROOT/Calendar/App/ISTUFetchClient.swift" \
            "$ROOT/Calendar/Core/Models.swift" "$ROOT/Calendar/Core/CalendarMath.swift" \
            "$ROOT/Calendar/Core/ScheduleImportTypes.swift" "$ROOT/Calendar/Core/ISTUParser.swift" \
            "$ROOT/Calendar/Core/UniversitySchedule.swift" "$ROOT/Calendar/Core/SharedPlannerStorage.swift" \
            "$ROOT/Calendar/Core/CalendarStore.swift" "$ROOT/Calendar/Core/WidgetSupport.swift" \
            "$ROOT/ScheduleFetcherXPC/Checks/FetchCheck.swift" -o "$CHECK_BINARY"
        CHECK_BINARIES+=("$CHECK_BINARY")
    done
    if [[ ${#CHECK_BINARIES[@]} -gt 1 ]]; then
        xcrun lipo -create "${CHECK_BINARIES[@]}" -output "$CHECK_APP/Contents/MacOS/FetchCheck"
    else
        cp "${CHECK_BINARIES[0]}" "$CHECK_APP/Contents/MacOS/FetchCheck"
    fi
    cp "$ROOT/Calendar/Resources/Info.plist" "$CHECK_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable FetchCheck' "$CHECK_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ru.local.GoldenGateCalendar' "$CHECK_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$CHECK_APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :PlannerAppGroupIdentifier ""' "$CHECK_APP/Contents/Info.plist"
    /usr/bin/codesign --force --sign - --options runtime \
        --entitlements "$ROOT/ScheduleFetcherXPC/Checks/FetchCheck.entitlements" "$CHECK_APP"
    echo "PASS: отдельный headless XPC diagnostic host собран и подписан; не запускался."
    echo "$CHECK_APP/Contents/MacOS/FetchCheck"
    exit 0
fi

if $CHECK_WIDGET_ONLY; then
    CHECK_DIR="$BUILD_DIR/widget-check"
    mkdir -p "$CHECK_DIR/ModuleCache"
    WIDGET_SOURCES=()
    for NAME in Models CalendarMath SharedPlannerStorage CalendarStore WidgetSupport WidgetIntents UniversitySchedule ScheduleImportTypes; do
        SOURCE="$ROOT/Calendar/Core/$NAME.swift"
        if [[ ! -f "$SOURCE" ]]; then echo "Нет общего исходного файла: $SOURCE" >&2; exit 1; fi
        WIDGET_SOURCES+=("$SOURCE")
    done
    while IFS= read -r SOURCE; do WIDGET_SOURCES+=("$SOURCE"); done < <(/usr/bin/find "$ROOT/CalendarWidget" -type f -name '*.swift' | /usr/bin/sort)
    if [[ ${#WIDGET_SOURCES[@]} -le 8 ]]; then echo "Исходные файлы WidgetKit ещё не созданы." >&2; exit 1; fi
    BINARIES=()
    for ARCH in $ARCHS; do
        BINARY="$CHECK_DIR/CalendarWidget-$ARCH"
        xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
            -swift-version 6 -parse-as-library -application-extension -O \
            -Xfrontend -entry-point-function-name -Xfrontend NSExtensionMain \
            -Xlinker -e -Xlinker _NSExtensionMain \
            -D CALENDAR_WIDGET_EXTENSION \
            -module-cache-path "$CHECK_DIR/ModuleCache" -module-name CalendarWidget \
            -framework SwiftUI -framework WidgetKit -framework AppIntents \
            "${WIDGET_SOURCES[@]}" -o "$BINARY"
        BINARIES+=("$BINARY")
    done
    if [[ ${#BINARIES[@]} -gt 1 ]]; then
        xcrun lipo -create "${BINARIES[@]}" -output "$CHECK_DIR/CalendarWidget"
    else
        cp "${BINARIES[0]}" "$CHECK_DIR/CalendarWidget"
    fi
    echo "PASS: WidgetKit исходники скомпилированы и слинкованы с ограничениями App Extension."
    echo "Артефакт проверки: $CHECK_DIR/CalendarWidget"
    echo "Это не зарегистрированный виджет: нет App Intents metadata, общей подписанной группы и embedded appex."
    echo "Полная сборка расширения выполняется схемой Calendar в Xcode с выбранной Team."
    exit 0
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/ModuleCache"
SOURCES=()
while IFS= read -r SOURCE; do SOURCES+=("$SOURCE"); done < <(/usr/bin/find "$ROOT/Calendar" -type f -name '*.swift' | /usr/bin/sort)
if [[ ${#SOURCES[@]} -eq 0 ]]; then echo "Исходные файлы Swift не найдены." >&2; exit 1; fi
BINARIES=()
for ARCH in $ARCHS; do
    BINARY="$BUILD_DIR/Calendar-$ARCH"
    xcrun swiftc -sdk "$SDK" -target "$ARCH-apple-macosx$DEPLOYMENT_TARGET" \
        -swift-version 6 -parse-as-library -O \
        -module-cache-path "$BUILD_DIR/ModuleCache" \
        -module-name CalendarApp \
        -framework AppKit -framework SwiftUI -framework ServiceManagement \
        -framework WidgetKit -framework AppIntents -framework Security \
        "${SOURCES[@]}" -o "$BINARY"
    BINARIES+=("$BINARY")
done
if [[ ${#BINARIES[@]} -gt 1 ]]; then
    xcrun lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/Calendar"
else
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/Calendar"
fi
# A local ad-hoc bundle must never retain a previously embedded, unregistered widget.
rm -rf "$APP/Contents/PlugIns" "$APP/Contents/Resources/Metadata.appintents" "$APP/Contents/Metadata.appintents"
build_fetcher_service "$APP/Contents/XPCServices/ScheduleFetcher.xpc"
cp "$ROOT/Calendar/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Calendar/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Calendar' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier ru.local.GoldenGateCalendar' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :PlannerAppGroupIdentifier ""' "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --options runtime \
    --entitlements "$ROOT/Calendar/Resources/Calendar-Local.entitlements" "$APP"
"$ROOT/scripts/validate-offline.sh" "$APP"
echo "Готово: $APP"
echo "Локальная CLI-сборка без WidgetKit extension и App Groups; главное приложение поддерживает опциональное облако, отдельная служба загружает только ИРНИТУ."
echo "Приложение не запускалось. При первом запуске macOS получит запрос на регистрацию автозапуска."
