#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJECT_PATH="$ROOT_DIR/SimDeckStudio.xcodeproj"
SCHEME="SimDeckStudio"
CONFIGURATION="Release"
EXPORT_OPTIONS_PLIST="$ROOT_DIR/ExportOptions.plist"
DESTINATION="generic/platform=iOS"

VERSION=""
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
ARCHIVE_PATH=""
EXPORT_PATH=""
DERIVED_DATA_PATH=""
ALLOW_PROVISIONING_UPDATES=1
CLEAN_BEFORE_ARCHIVE=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage:
  scripts/publish-testflight-xcodebuild.sh [options]

Archives and uploads SimDeckStudio to App Store Connect using xcodebuild.
The export step uses destination=upload, so this is the Xcode/TestFlight upload
flow rather than ASC CLI.

Options:
  --version VERSION        Marketing version to archive, e.g. the next release.
                           Defaults to the project's MARKETING_VERSION.
  --build-number NUMBER    Build number to archive. Defaults to timestamp.
  --archive-path PATH      Archive output path. Defaults to /tmp.
  --export-path PATH       Export/upload work path. Defaults to /tmp.
  --derived-data-path PATH DerivedData path. Defaults to /tmp.
  --project PATH           Xcode project path.
  --scheme NAME            Xcode scheme. Defaults to SimDeckStudio.
  --configuration NAME     Build configuration. Defaults to Release.
  --export-options PATH    ExportOptions.plist path.
  --no-clean               Archive without running xcodebuild clean first.
  --no-provisioning-updates
                           Do not pass -allowProvisioningUpdates.
  --dry-run                Print the xcodebuild commands without running them.
  -h, --help               Show this help.

Examples:
  scripts/publish-testflight-xcodebuild.sh --version VERSION
  scripts/publish-testflight-xcodebuild.sh --version VERSION --build-number BUILD_NUMBER
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

trim() {
  awk '{$1=$1; print}'
}

read_project_version() {
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -showBuildSettings \
    2>/dev/null |
    awk -F= '/MARKETING_VERSION/ { print $2; exit }' |
    trim
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" == "0" ]]; then
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      [[ $# -ge 2 ]] || fail "--build-number requires a value"
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --archive-path)
      [[ $# -ge 2 ]] || fail "--archive-path requires a value"
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --export-path)
      [[ $# -ge 2 ]] || fail "--export-path requires a value"
      EXPORT_PATH="$2"
      shift 2
      ;;
    --derived-data-path)
      [[ $# -ge 2 ]] || fail "--derived-data-path requires a value"
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || fail "--project requires a value"
      PROJECT_PATH="$2"
      shift 2
      ;;
    --scheme)
      [[ $# -ge 2 ]] || fail "--scheme requires a value"
      SCHEME="$2"
      shift 2
      ;;
    --configuration)
      [[ $# -ge 2 ]] || fail "--configuration requires a value"
      CONFIGURATION="$2"
      shift 2
      ;;
    --export-options)
      [[ $# -ge 2 ]] || fail "--export-options requires a value"
      EXPORT_OPTIONS_PLIST="$2"
      shift 2
      ;;
    --no-clean)
      CLEAN_BEFORE_ARCHIVE=0
      shift
      ;;
    --no-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -d "$PROJECT_PATH" ]] || fail "project not found: $PROJECT_PATH"
[[ -f "$EXPORT_OPTIONS_PLIST" ]] || fail "export options plist not found: $EXPORT_OPTIONS_PLIST"

if [[ -z "$VERSION" ]]; then
  VERSION="$(read_project_version)"
  [[ -n "$VERSION" ]] || fail "could not read MARKETING_VERSION from project"
fi

ARCHIVE_BASENAME="${SCHEME}-${VERSION}-${BUILD_NUMBER}"
ARCHIVE_PATH="${ARCHIVE_PATH:-/tmp/${ARCHIVE_BASENAME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-/tmp/${ARCHIVE_BASENAME}-export}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/${ARCHIVE_BASENAME}-DerivedData}"
TEMP_EXPORT_OPTIONS="$(mktemp "/tmp/${ARCHIVE_BASENAME}-ExportOptions.XXXXXX")"
trap 'rm -f "$TEMP_EXPORT_OPTIONS"' EXIT

cp "$EXPORT_OPTIONS_PLIST" "$TEMP_EXPORT_OPTIONS"
plutil -replace destination -string upload "$TEMP_EXPORT_OPTIONS"
plutil -replace method -string app-store-connect "$TEMP_EXPORT_OPTIONS"
plutil -replace manageAppVersionAndBuildNumber -bool NO "$TEMP_EXPORT_OPTIONS"

PROVISIONING_ARGS=()
if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
  PROVISIONING_ARGS=(-allowProvisioningUpdates)
fi

ARCHIVE_ACTIONS=(archive)
if [[ "$CLEAN_BEFORE_ARCHIVE" == "1" ]]; then
  ARCHIVE_ACTIONS=(clean archive)
fi

echo "Publishing $SCHEME $VERSION ($BUILD_NUMBER) via xcodebuild upload"
echo "Archive: $ARCHIVE_PATH"
echo "Export:  $EXPORT_PATH"

run xcodebuild \
  "${ARCHIVE_ACTIONS[@]}" \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  "MARKETING_VERSION=$VERSION" \
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
  "${PROVISIONING_ARGS[@]}"

INFO_PLIST="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 2 -name Info.plist -print -quit 2>/dev/null || true)"
if [[ "$DRY_RUN" == "0" ]]; then
  [[ -n "$INFO_PLIST" ]] || fail "archived app Info.plist not found"
  ARCHIVED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
  ARCHIVED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
  [[ "$ARCHIVED_VERSION" == "$VERSION" ]] || fail "archive version was $ARCHIVED_VERSION, expected $VERSION"
  [[ "$ARCHIVED_BUILD" == "$BUILD_NUMBER" ]] || fail "archive build was $ARCHIVED_BUILD, expected $BUILD_NUMBER"
fi

run xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$TEMP_EXPORT_OPTIONS" \
  "${PROVISIONING_ARGS[@]}"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete. No archive or upload was run."
else
  echo "Upload requested. App Store Connect will finish TestFlight processing asynchronously."
fi
