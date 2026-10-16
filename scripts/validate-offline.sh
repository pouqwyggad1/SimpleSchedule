#!/bin/bash
# Static audit and signature checks. No launch, system setting changes, or network use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Calendar.app}"
/usr/bin/plutil -lint \
    "$ROOT/Calendar/Resources/Info.plist" \
    "$ROOT/Calendar/Resources/Calendar.entitlements" \
    "$ROOT/Calendar/Resources/Calendar-Local.entitlements" \
    "$ROOT/CalendarWidget/Resources/Info.plist" \
    "$ROOT/CalendarWidget/Resources/CalendarWidget.entitlements" \
    "$ROOT/ScheduleFetcherXPC/Resources/Info.plist" \
    "$ROOT/ScheduleFetcherXPC/Resources/ScheduleFetcher.entitlements" \
    "$ROOT/Calendar.xcodeproj/project.pbxproj"
/usr/bin/python3 - "$ROOT" "$APP" <<'PY'
import json, pathlib, plistlib, re, subprocess, sys, xml.etree.ElementTree as ET
root = pathlib.Path(sys.argv[1])
source_only = sys.argv[2] == '--source-only'
app = pathlib.Path(sys.argv[2])
base = {'com.apple.security.app-sandbox': True}
group_key = 'com.apple.security.application-groups'
group_template = '$(TeamIdentifierPrefix)ru.local.GoldenGateCalendar.shared'
shared = {**base, group_key: [group_template]}
fetcher_expected = {**base, 'com.apple.security.network.client': True}
def read_plist(path):
    return plistlib.loads(path.read_bytes())
assert read_plist(root/'Calendar/Resources/Calendar-Local.entitlements') == base, 'CLI entitlements must contain only App Sandbox.'
assert read_plist(root/'Calendar/Resources/Calendar.entitlements') == shared, 'Unexpected signed app entitlements.'
assert read_plist(root/'CalendarWidget/Resources/CalendarWidget.entitlements') == shared, 'App/widget source App Groups must match.'
assert read_plist(root/'ScheduleFetcherXPC/Resources/ScheduleFetcher.entitlements') == fetcher_expected, 'XPC must have only App Sandbox and outgoing network.'
assert read_plist(root/'ScheduleFetcherXPC/Resources/Info.plist')['XPCService']['ServiceType'] == 'Application'
app_source_info = read_plist(root/'Calendar/Resources/Info.plist')
widget_source_info = read_plist(root/'CalendarWidget/Resources/Info.plist')
assert app_source_info['PlannerAppGroupIdentifier'] == widget_source_info['PlannerAppGroupIdentifier'] == group_template
assert app_source_info['PlannerStorageRole'] == 'app' and widget_source_info['PlannerStorageRole'] == 'widget'
assert app_source_info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['goldencalendar']
assert widget_source_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
for directory in ['Calendar', 'CalendarWidget']:
    for path in (root/directory).rglob('*.swift'):
        source = path.read_text()
        forbidden = r'\b(URLSession|URLRequest|NWConnection|NWListener|WKWebView|WebView|CFReadStreamCreateForHTTPRequest|SCPreferences|AXUIElement|CGRequestScreenCaptureAccess)\b|\bimport\s+(Network|WebKit|CFNetwork)\b'
        assert not re.search(forbidden, source), f'Forbidden API found: {path}'
for path in (root/'ScheduleFetcherXPC').rglob('*.swift'):
    source = path.read_text()
    forbidden = r'\b(NWConnection|NWListener|WKWebView|WebView|CFReadStreamCreateForHTTPRequest|SCPreferences|AXUIElement|CGRequestScreenCaptureAccess)\b|\bimport\s+(Network|WebKit|CFNetwork)\b'
    assert not re.search(forbidden, source), f'Forbidden XPC API found: {path}'
assert not list(root.rglob('Package.resolved')), 'Unexpected resolved external dependencies.'
# Validate the target graph without requiring full Xcode or running build scripts.
project = json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(root/'Calendar.xcodeproj/project.pbxproj')]))
objects = project['objects']
assert all(len(key) == 24 for key in objects), 'Invalid Xcode object identifier.'
targets = {value['name']: (key, value) for key, value in objects.items() if value.get('isa') == 'PBXNativeTarget'}
app_id, app_target = targets['Calendar']
widget_id, widget_target = targets['CalendarWidget']
fetcher_id, fetcher_target = targets['ScheduleFetcherXPC']
assert fetcher_target['productType'] == 'com.apple.product-type.xpc-service'
assert any(objects[item].get('target') == fetcher_id for item in app_target['dependencies']), 'Missing XPC dependency.'
assert widget_target['productType'] == 'com.apple.product-type.app-extension'
assert any(objects[item].get('target') == widget_id for item in app_target['dependencies']), 'Missing widget build dependency.'
embed_phases = [objects[item] for item in app_target['buildPhases'] if objects[item]['isa'] == 'PBXCopyFilesBuildPhase']
assert any(phase['dstSubfolderSpec'] == '13' and any(objects[item]['fileRef'] == widget_target['productReference'] and 'CodeSignOnCopy' in objects[item]['settings']['ATTRIBUTES'] for item in phase['files']) for phase in embed_phases), 'Widget must be embedded and signed on copy.'
assert any(phase['dstSubfolderSpec'] == '16' and phase['dstPath'] == '$(CONTENTS_FOLDER_PATH)/XPCServices' and any(objects[item]['fileRef'] == fetcher_target['productReference'] and 'CodeSignOnCopy' in objects[item]['settings']['ATTRIBUTES'] for item in phase['files']) for phase in embed_phases), 'XPC must be embedded in Contents/XPCServices and signed on copy.'
shared_names = {'Models.swift','CalendarMath.swift','SharedPlannerStorage.swift','CalendarStore.swift','WidgetSupport.swift','WidgetIntents.swift','UniversitySchedule.swift','ScheduleImportTypes.swift'}
widget_phases = [objects[item] for item in widget_target['buildPhases'] if objects[item]['isa'] == 'PBXSourcesBuildPhase']
actual_shared = {pathlib.Path(objects[objects[item]['fileRef']]['path']).name for phase in widget_phases for item in phase['files']}
assert actual_shared == shared_names, f'Unexpected widget shared sources: {actual_shared}'
for target in [app_target, widget_target, fetcher_target]:
    for config_id in objects[target['buildConfigurationList']]['buildConfigurations']:
        settings = objects[config_id]['buildSettings']
        if settings.get('DEVELOPMENT_TEAM'):
            assert re.fullmatch(r'[A-Z0-9]{10}', settings['DEVELOPMENT_TEAM']), 'Choose a valid signing Team in Xcode.'
        assert settings['CODE_SIGN_STYLE'] == 'Automatic' and settings['CODE_SIGN_IDENTITY'] != '-'
for scheme in ['Calendar', 'CalendarWidget']:
    ET.parse(root/f'Calendar.xcodeproj/xcshareddata/xcschemes/{scheme}.xcscheme')
print('PASS: Xcode app/WidgetKit/XPC targets, dependency/embedding, shared App Group, URL scheme and source audit.')
if source_only:
    print('Только исходники: сборка, подпись, App Intents metadata и регистрация виджета не проверялись.')
    sys.exit(0)
assert app.is_dir(), f'Build the application first: {app}'
signing_metadata = {
    'application-identifier', 'com.apple.application-identifier',
    'com.apple.developer.team-identifier', 'com.apple.security.get-task-allow',
}
def signed_entitlements(bundle, fetcher=False):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
    result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], capture_output=True, check=True)
    actual = plistlib.loads(result.stdout)
    assert actual.get('com.apple.security.app-sandbox') is True, f'App Sandbox missing: {bundle}'
    allowed = set(fetcher_expected) if fetcher else set(base) | {group_key}
    assert not (set(actual) - allowed - signing_metadata), f'Unexpected signed entitlements: {actual}'
    assert not any('files.' in key for key in actual), 'File access entitlement found.'
    if fetcher:
        assert actual.get('com.apple.security.network.client') is True and group_key not in actual, 'XPC must have outgoing network and no App Group.'
    else:
        assert not any('network.' in key for key in actual), 'Main app and widget must have no network entitlement.'
    return actual

def check_bundle(bundle, role):
    info = read_plist(bundle/'Contents/Info.plist')
    assert info['LSMinimumSystemVersion'] == '27.0'
    assert info['PlannerStorageRole'] == role
    assert '$(' not in str(info), f'Unexpanded Info.plist build variable: {bundle}'
    binary = bundle/'Contents/MacOS'/info['CFBundleExecutable']
    build_versions = subprocess.run(['/usr/bin/xcrun', 'vtool', '-show-build', str(binary)], capture_output=True, text=True, check=True).stdout
    minimum_versions = re.findall(r'\bminos\s+(\S+)', build_versions)
    assert minimum_versions and all(version == '27.0' for version in minimum_versions), 'Mach-O minimum macOS version must be 27.0.'
    return info, signed_entitlements(bundle, fetcher=role == 'fetcher')

info, actual = check_bundle(app, 'app')
assert info['LSUIElement'] is True
assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['goldencalendar']
xpcs = sorted((app/'Contents/XPCServices').glob('*.xpc'))
assert len(xpcs) == 1 and xpcs[0].name == 'ScheduleFetcher.xpc', 'App must embed exactly ScheduleFetcher.xpc.'
fetcher_info, fetcher_actual = check_bundle(xpcs[0], 'fetcher')
assert fetcher_info['CFBundleIdentifier'] == 'ru.local.GoldenGateCalendar.ScheduleFetcher'
assert fetcher_info['XPCService']['ServiceType'] == 'Application'
def signing_team(bundle):
    result = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=2', str(bundle)], capture_output=True, text=True, check=True)
    match = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', result.stderr, re.MULTILINE)
    return match.group(1) if match else None
assert signing_team(app) == signing_team(xpcs[0]), 'Main app and XPC signing Teams must match.'
groups = actual.get(group_key)
widgets = sorted((app/'Contents/PlugIns').glob('*.appex'))
if groups is None:
    assert info['PlannerAppGroupIdentifier'] == '', 'Local CLI build must explicitly use its own container.'
    assert not widgets, 'CLI build must not embed an unregistered widget.'
    assert not list((app/'Contents').rglob('Metadata.appintents')), 'CLI build must not retain stale App Intents metadata.'
    print('PASS: локальная CLI-подпись — App Sandbox, без App Groups и embedded виджета.')
else:
    assert len(widgets) == 1 and widgets[0].name == 'CalendarWidget.appex', 'Signed Xcode app must embed exactly CalendarWidget.appex.'
    details = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True, check=True)
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', details.stderr, re.MULTILINE)
    assert team, 'Shared App Group requires a real Apple signing Team; ad-hoc signing is insufficient.'
    expected_groups = [team.group(1)+'.ru.local.GoldenGateCalendar.shared']
    assert groups == expected_groups and info['PlannerAppGroupIdentifier'] == groups[0], 'Signed App Group does not match Team/Info.plist.'
    for widget in widgets:
        widget_info, widget_actual = check_bundle(widget, 'widget')
        assert widget_actual.get(group_key) == groups, 'App/widget signed App Groups must match.'
        widget_details = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=2', str(widget)], capture_output=True, text=True, check=True)
        widget_team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', widget_details.stderr, re.MULTILINE)
        assert widget_team and widget_team.group(1) == team.group(1), 'App/widget signing Teams must match.'
        assert widget_info['PlannerAppGroupIdentifier'] == groups[0]
        assert widget_info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
        assert widget_info['CFBundleIdentifier'] == info['CFBundleIdentifier']+'.widget'
        assert widget_info['CFBundleVersion'] == info['CFBundleVersion'] and widget_info['CFBundleShortVersionString'] == info['CFBundleShortVersionString'], 'App/widget versions must match.'
    print(f'PASS: подписанная общая группа и embedded WidgetKit extensions: {len(widgets)}.')
print('PASS: подпись, App Sandbox, macOS 27.0; main/widget без сетевых разрешений, отдельный XPC только network.client, файловых исключений нет.')
print('App Intents metadata, регистрация WidgetKit, сетевое выполнение XPC и интерфейс требуют отдельной проверки.')
PY
