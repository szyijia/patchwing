#!/usr/bin/env bash

set -euo pipefail

readonly ENGINE_REVISION="e1eaecbcac6d9a32cb5590c646e21cf21252cf19"
readonly FLUTTER_ENGINE_REVISION="83675ed27633283e7fc296c8bca22e841224c096"
readonly CDN_ORIGIN="https://cdn.patchwing.net/patchwing"
readonly MC_TARGET="${MC_TARGET:-patchwing/patchwing}"
readonly SHOREBIRD_GCS="https://storage.googleapis.com/download.shorebird.dev"
readonly FLUTTER_GCS="https://storage.googleapis.com"
readonly CHECKSUM_MANIFEST="phase1-android-macos-arm64-v1.sha256"

usage() {
  printf '%s\n' \
    'Usage: scripts/sync_phase1_android_cdn.sh <sync|verify|list>' \
    '' \
    'Environment:' \
    '  MC_TARGET  mc alias and bucket (default: patchwing/patchwing)'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# destination|source
#
# The destination paths are the exact URLs requested by the unmodified
# Shorebird/Flutter download logic. Standard Flutter artifacts are copied from
# the upstream Flutter engine revision into the Shorebird engine namespace,
# matching Shorebird's artifact-proxy resolution without adding runtime
# fallback behavior to the CDN.
artifact_rows() {
  local engine_prefix="flutter_infra_release/flutter/${ENGINE_REVISION}"
  local flutter_prefix="flutter_infra_release/flutter/${FLUTTER_ENGINE_REVISION}"
  local maven_prefix="download.flutter.io/io/flutter"

  printf '%s\n' \
    "shorebird/${ENGINE_REVISION}/artifacts_manifest.yaml|${SHOREBIRD_GCS}/shorebird/${ENGINE_REVISION}/artifacts_manifest.yaml" \
    "shorebird/${ENGINE_REVISION}/patch-darwin-arm64.zip|${SHOREBIRD_GCS}/shorebird/${ENGINE_REVISION}/patch-darwin-arm64.zip" \
    "shorebird/${ENGINE_REVISION}/aot-tools.dill|${SHOREBIRD_GCS}/shorebird/${ENGINE_REVISION}/aot-tools.dill" \
    "${engine_prefix}/engine_stamp.json|${SHOREBIRD_GCS}/${engine_prefix}/engine_stamp.json" \
    "${engine_prefix}/dart-sdk-darwin-arm64.zip|${SHOREBIRD_GCS}/${engine_prefix}/dart-sdk-darwin-arm64.zip" \
    "${engine_prefix}/sky_engine.zip|${FLUTTER_GCS}/${flutter_prefix}/sky_engine.zip" \
    "${engine_prefix}/flutter_gpu.zip|${FLUTTER_GCS}/${flutter_prefix}/flutter_gpu.zip" \
    "${engine_prefix}/flutter_patched_sdk.zip|${FLUTTER_GCS}/${flutter_prefix}/flutter_patched_sdk.zip" \
    "${engine_prefix}/flutter_patched_sdk_product.zip|${SHOREBIRD_GCS}/${engine_prefix}/flutter_patched_sdk_product.zip" \
    "${engine_prefix}/darwin-arm64/artifacts.zip|${FLUTTER_GCS}/${flutter_prefix}/darwin-arm64/artifacts.zip" \
    "${engine_prefix}/darwin-arm64/font-subset.zip|${FLUTTER_GCS}/${flutter_prefix}/darwin-arm64/font-subset.zip" \
    "${engine_prefix}/android-arm-profile/darwin-x64.zip|${FLUTTER_GCS}/${flutter_prefix}/android-arm-profile/darwin-x64.zip" \
    "${engine_prefix}/android-arm-release/darwin-x64.zip|${SHOREBIRD_GCS}/${engine_prefix}/android-arm-release/darwin-x64.zip" \
    "${engine_prefix}/android-arm64-profile/darwin-x64.zip|${FLUTTER_GCS}/${flutter_prefix}/android-arm64-profile/darwin-x64.zip" \
    "${engine_prefix}/android-arm64-release/darwin-x64.zip|${SHOREBIRD_GCS}/${engine_prefix}/android-arm64-release/darwin-x64.zip" \
    "${engine_prefix}/android-x64-profile/darwin-x64.zip|${FLUTTER_GCS}/${flutter_prefix}/android-x64-profile/darwin-x64.zip" \
    "${engine_prefix}/android-x64-release/darwin-x64.zip|${SHOREBIRD_GCS}/${engine_prefix}/android-x64-release/darwin-x64.zip" \
    "flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip|${FLUTTER_GCS}/flutter_infra_release/flutter/fonts/3012db47f3130e62f7cc0beabff968a33cbec8d8/fonts.zip" \
    "flutter_infra_release/gradle-wrapper/fd5c1f2c013565a3bea56ada6df9d2b8e96d56aa/gradle-wrapper.tgz|${FLUTTER_GCS}/flutter_infra_release/gradle-wrapper/fd5c1f2c013565a3bea56ada6df9d2b8e96d56aa/gradle-wrapper.tgz" \
    "flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libimobiledevice/0bf0f9e941c85d06ce4b5909d7a61b3a4f2a6a05/libimobiledevice.zip|${FLUTTER_GCS}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libimobiledevice/0bf0f9e941c85d06ce4b5909d7a61b3a4f2a6a05/libimobiledevice.zip" \
    "flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libusbmuxd/19d6bec393c9f9b31ccb090059f59268da32e281/libusbmuxd.zip|${FLUTTER_GCS}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libusbmuxd/19d6bec393c9f9b31ccb090059f59268da32e281/libusbmuxd.zip" \
    "flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libplist/cf5897a71ea412ea2aeb1e2f6b5ea74d4fabfd8c/libplist.zip|${FLUTTER_GCS}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libplist/cf5897a71ea412ea2aeb1e2f6b5ea74d4fabfd8c/libplist.zip" \
    "flutter_infra_release/ios-usb-dependencies/arm64_x86_64/openssl/22dbb176deef7d9a80f5c94f57a4b518ea935f50/openssl.zip|${FLUTTER_GCS}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/openssl/22dbb176deef7d9a80f5c94f57a4b518ea935f50/openssl.zip" \
    "flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libimobiledeviceglue/050ff3bf8fdab6ce53a2ddc6ae49b11b1c02a168/libimobiledeviceglue.zip|${FLUTTER_GCS}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/libimobiledeviceglue/050ff3bf8fdab6ce53a2ddc6ae49b11b1c02a168/libimobiledeviceglue.zip" \
    "flutter_infra_release/ios-usb-dependencies/arm64_x86_64/ios-deploy/7a29ab0b6d611f2bf5de4b6f929a82a091866307/ios-deploy.zip|${FLUTTER_GCS}/flutter_infra_release/ios-usb-dependencies/arm64_x86_64/ios-deploy/7a29ab0b6d611f2bf5de4b6f929a82a091866307/ios-deploy.zip"

  local component
  for component in flutter_embedding_release armeabi_v7a_release arm64_v8a_release x86_64_release; do
    local base="${maven_prefix}/${component}/1.0.0-${ENGINE_REVISION}/${component}-1.0.0-${ENGINE_REVISION}"
    printf '%s\n' \
      "${base}.pom|${SHOREBIRD_GCS}/${base}.pom" \
      "${base}.jar|${SHOREBIRD_GCS}/${base}.jar"
  done
}

sync_artifacts() {
  require_command curl
  require_command mc
  require_command shasum

  local work_dir
  work_dir="$(mktemp -d)"
  trap "rm -rf -- '${work_dir}'" EXIT
  local checksum_file="${work_dir}/${CHECKSUM_MANIFEST}"
  : >"${checksum_file}"

  local destination source local_file size remote_size checksum
  while IFS='|' read -r destination source; do
    printf 'sync %s\n' "${destination}"
    local_file="${work_dir}/artifact"
    curl --fail --location --retry 3 --silent --show-error \
      --output "${local_file}" "${source}"
    size="$(stat -f '%z' "${local_file}")"
    [[ "${size}" -gt 0 ]] || die "empty artifact: ${source}"
    checksum="$(shasum -a 256 "${local_file}" | awk '{print $1}')"
    remote_size="$(mc stat --json "${MC_TARGET}/${destination}" 2>/dev/null | sed -n 's/.*"size":\([0-9][0-9]*\).*/\1/p' || true)"
    if [[ -n "${remote_size}" ]]; then
      [[ "${remote_size}" == "${size}" ]] || die "existing object size mismatch: ${destination}"
      printf 'skip existing %s\n' "${destination}"
    else
      mc cp --quiet "${local_file}" "${MC_TARGET}/${destination}"
      remote_size="$(mc stat --json "${MC_TARGET}/${destination}" | sed -n 's/.*"size":\([0-9][0-9]*\).*/\1/p')"
    fi
    [[ "${remote_size}" == "${size}" ]] || die "uploaded size mismatch: ${destination}"
    printf '%s  %s\n' "${checksum}" "${destination}" >>"${checksum_file}"
  done < <(artifact_rows)

  mc cp --quiet "${checksum_file}" "${MC_TARGET}/shorebird/${ENGINE_REVISION}/${CHECKSUM_MANIFEST}"
  printf 'uploaded checksum manifest: %s\n' "${MC_TARGET}/shorebird/${ENGINE_REVISION}/${CHECKSUM_MANIFEST}"
}

verify_artifacts() {
  require_command curl
  require_command shasum

  local work_dir
  work_dir="$(mktemp -d)"
  trap "rm -rf -- '${work_dir}'" EXIT
  local checksum_file="${work_dir}/${CHECKSUM_MANIFEST}"
  curl --fail --location --silent --show-error --output "${checksum_file}" \
    "${CDN_ORIGIN}/shorebird/${ENGINE_REVISION}/${CHECKSUM_MANIFEST}"

  local expected destination local_file actual
  while read -r expected destination; do
    [[ -n "${destination}" ]] || continue
    printf 'verify %s\n' "${destination}"
    local_file="${work_dir}/artifact"
    curl --fail --location --retry 3 --silent --show-error \
      --output "${local_file}" "${CDN_ORIGIN}/${destination}"
    actual="$(shasum -a 256 "${local_file}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || die "checksum mismatch: ${destination}"
  done <"${checksum_file}"

  local range_headers="${work_dir}/range.headers"
  curl --fail --silent --show-error --range 0-0 --dump-header "${range_headers}" \
    --output /dev/null \
    "${CDN_ORIGIN}/shorebird/${ENGINE_REVISION}/patch-darwin-arm64.zip"
  grep -Eq '^HTTP/[^ ]+ 206' "${range_headers}" || die 'CDN did not return HTTP 206 for a Range request'
  grep -Eiq '^cache-control:.*immutable' "${range_headers}" || die 'CDN response is missing immutable cache control'

  local missing_status
  missing_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    "${CDN_ORIGIN}/shorebird/phase1-missing-artifact/patch-darwin-arm64.zip")"
  [[ "${missing_status}" == '404' ]] || die "missing artifact returned HTTP ${missing_status}, expected 404"
  printf 'verified checksums, HTTP Range/cache behavior, and strict missing-artifact failure\n'
}

main() {
  [[ "$#" -eq 1 ]] || {
    usage
    exit 2
  }
  case "$1" in
    list) artifact_rows ;;
    sync) sync_artifacts ;;
    verify) verify_artifacts ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
