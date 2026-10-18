#!/bin/bash
# Packages the already built universal CLI app. Never starts the app or modifies it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${1:-$ROOT/build/Calendar.app}"
RELEASE_VERSION="${2:-1.0.0}"
OUTPUT_DIR="${3:-$ROOT/Artifacts/releases}"
STAGING_ROOT="$ROOT/build/release"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Версия должна иметь вид 1.0.0." >&2
    exit 2
fi
if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Сначала соберите universal-приложение: ./scripts/build-offline.sh --universal" >&2
    exit 1
fi
SOURCE_APP="$(cd "$SOURCE_APP" && pwd)"
mkdir -p "$OUTPUT_DIR" "$STAGING_ROOT"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
if [[ "$SOURCE_APP" == "$STAGING_ROOT/"* ]]; then
    echo "Исходное приложение не должно находиться внутри build/release." >&2
    exit 2
fi
MAIN_RELATIVE="Contents/MacOS/Calendar"
HELPER_RELATIVE="Contents/XPCServices/ScheduleFetcher.xpc"
HELPER_BINARY_RELATIVE="$HELPER_RELATIVE/Contents/MacOS/ScheduleFetcher"
for BINARY in "$SOURCE_APP/$MAIN_RELATIVE" "$SOURCE_APP/$HELPER_BINARY_RELATIVE"; do
    xcrun lipo "$BINARY" -verify_arch arm64 x86_64
done
"$ROOT/scripts/validate-offline.sh" "$SOURCE_APP"
SOURCE_MAIN_HASH="$(shasum -a 256 "$SOURCE_APP/$MAIN_RELATIVE")"
SOURCE_HELPER_HASH="$(shasum -a 256 "$SOURCE_APP/$HELPER_BINARY_RELATIVE")"
SOURCE_INFO_HASH="$(shasum -a 256 "$SOURCE_APP/Contents/Info.plist")"

for RELEASE_ARCH in arm64 x86_64; do
    STAGING_DIR="$STAGING_ROOT/$RELEASE_ARCH"
    APP="$STAGING_DIR/SimpleSchedule.app"
    if [[ "$RELEASE_ARCH" == arm64 ]]; then
        ARCH_LABEL="AppleSilicon"
        ARCH_RUSSIAN="Apple Silicon (M1 и новее)"
    else
        ARCH_LABEL="Intel"
        ARCH_RUSSIAN="Intel (x86_64)"
    fi
    # Only these two paths under our own staging directory are regenerated.
    rm -rf "$APP"
    mkdir -p "$STAGING_DIR"
    ditto "$SOURCE_APP" "$APP"
    for BINARY in "$MAIN_RELATIVE" "$HELPER_BINARY_RELATIVE"; do
        xcrun lipo "$APP/$BINARY" -thin "$RELEASE_ARCH" -output "$APP/$BINARY.thin"
        mv "$APP/$BINARY.thin" "$APP/$BINARY"
        chmod 755 "$APP/$BINARY"
        [[ "$(xcrun lipo -archs "$APP/$BINARY")" == "$RELEASE_ARCH" ]]
    done
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName SimpleSchedule' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleName SimpleSchedule' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$APP/Contents/Info.plist"
    # Bundle identifiers/executable names remain stable for container, login and XPC identity.
    /usr/bin/codesign --force --sign - --options runtime \
        --entitlements "$ROOT/ScheduleFetcherXPC/Resources/ScheduleFetcher.entitlements" "$APP/$HELPER_RELATIVE"
    /usr/bin/codesign --force --sign - --options runtime \
        --entitlements "$ROOT/Calendar/Resources/Calendar-Local.entitlements" "$APP"
    "$ROOT/scripts/validate-offline.sh" "$APP"
    ln -sfn /Applications "$STAGING_DIR/Applications"
    cat > "$STAGING_DIR/INSTALL.txt" <<EOF
SimpleSchedule $RELEASE_VERSION — $ARCH_RUSSIAN

Требования: macOS 27 или новее; процессор $ARCH_RUSSIAN.

Установка
1. Перетащите SimpleSchedule.app в папку Applications (Программы).
2. Извлеките этот образ диска и откройте приложение из Программ.
3. Откройте календарь значком в верхней строке меню. Повторное нажатие скрывает панель.

Эта сборка подписана локальной ad-hoc подписью. Сертификат Developer ID и
нотариальное заверение Apple отсутствуют. При загрузке из интернета macOS может
заблокировать запуск. Если доверяете этому выпуску и проверили его источник,
используйте штатную кнопку «Всё равно открыть» в «Системные настройки» →
«Конфиденциальность и безопасность», если она доступна. Настройки безопасности
могут запрещать запуск такой сборки. Отключать Gatekeeper не требуется.

Виджет рабочего стола в этот установочный файл не включён. Для него нужна
полная сборка проекта в Xcode с выбранной Apple Team и общей App Group.

Дела и расписание доступны локально. В настройках можно войти по почте,
объединить данные с аккаунтом PWA/iPhone, включить автоматическое обновление
и уведомления macOS. Сессия хранится в Связке ключей. Без входа облачная
синхронизация не выполняется. Вид календаря и темы остаются нативными.
Для напоминаний разрешите уведомления в macOS; скрытая панель продолжает
работать, полное завершение останавливает получение новых изменений.
Автозапуск можно отключить в настройках приложения.

На Intel проверены состав Mach-O и подпись, запуск на физическом Intel Mac
не проверялся. Отсутствие notarization и проверка безопасности системы могут
влиять на первый запуск на другом Mac.
EOF
    IMAGE="$OUTPUT_DIR/SimpleSchedule-$RELEASE_VERSION-$ARCH_LABEL.dmg"
    hdiutil create -ov -format UDZO -fs HFS+ -volname "SimpleSchedule $ARCH_LABEL" \
        -srcfolder "$STAGING_DIR" "$IMAGE"
    hdiutil verify "$IMAGE"
    echo "Готово: $IMAGE"
done

[[ "$(shasum -a 256 "$SOURCE_APP/$MAIN_RELATIVE")" == "$SOURCE_MAIN_HASH" ]]
[[ "$(shasum -a 256 "$SOURCE_APP/$HELPER_BINARY_RELATIVE")" == "$SOURCE_HELPER_HASH" ]]
[[ "$(shasum -a 256 "$SOURCE_APP/Contents/Info.plist")" == "$SOURCE_INFO_HASH" ]]
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "SimpleSchedule-$RELEASE_VERSION-AppleSilicon.dmg" \
        "SimpleSchedule-$RELEASE_VERSION-Intel.dmg" > SHA256SUMS.txt
)
echo "Исходная universal-сборка не изменена. DMG и SHA256SUMS.txt: $OUTPUT_DIR"
