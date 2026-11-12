#!/usr/bin/env bash
# detect-legacy-fips.sh
# Initiative Engine detection script for OCPSTRAT-3842
# "Build OCP 5.1 with golang-native FIPS crypto"
#
# Type: script  (operates on a cloned repo)
#
# Decides whether a repository still builds against the legacy
# OpenSSL-backed FIPS crypto path instead of the golang-native FIPS
# module (GOFIPS140, golang >= 1.26).
#
# PRIMARY SIGNAL: the ci-operator build root
#   OCP Go builds take their toolchain from the build root image declared
#   in .ci-operator.yaml, not from the repository's own Dockerfile:
#
#     build_root_image:
#       name: release
#       namespace: openshift
#       tag: rhel-9-release-golang-1.26-openshift-5.1
#
#   The `golang-X.Y` component is what decides native vs OpenSSL FIPS, and
#   `openshift-X.Y` says which payload the repo currently targets. Grepping
#   Dockerfiles for GOEXPERIMENT/GOFIPS misses this entirely, which is why
#   it is checked first.
#
# SECONDARY SIGNAL: explicit build settings that override the toolchain
#   GOEXPERIMENT=boringcrypto, GOFIPS=1, GOLANG_FIPS=1, `-tags openssl`,
#   `import "crypto/tls/fipsonly"` force the OpenSSL path even on a newer
#   build root, so they make a repo affected regardless of its tag.
#   GOFIPS140=v1.26.0 does the opposite and marks the repo migrated.
#
# NOT GO -> NOT IN SCOPE
#   The initiative covers golang binaries. A repository that ships no Go
#   source is not affected even if its build root is older.
#
# Emits the JSON contract documented in AGENTS.md. Always exits 0: the
# worker treats a non-zero exit or invalid JSON as a scan failure and
# silently drops the repo from the run.
#
# Environment: bash, grep, awk, sed, jq (no python). 5 minute timeout.

set -uo pipefail

REPO_DIR="${1:-.}"

# Stable byte order so two dry runs of the same commit produce identical JSON.
export LC_ALL=C

debug() { echo "[DEBUG] $*" >&2; }

emit() {
  # emit <affected> <severity> <summary> <hits-json> <implementation_spec>
  jq -n \
    --argjson affected "$1" \
    --arg     severity "$2" \
    --arg     summary  "$3" \
    --argjson hits     "$4" \
    --arg     spec     "$5" \
    '{affected: $affected, summary: $summary, severity: $severity,
      hits: $hits, implementation_spec: $spec}'
}

pass() { # pass <summary>
  emit false info "$1" '[]' ""
  exit 0
}

if ! cd "${REPO_DIR}" 2>/dev/null; then
  pass "Cannot inspect ${REPO_DIR}: directory is not readable. Treated as not affected by the contract; verify the clone before relying on this result."
fi

# vendor/ is excluded: vendored third-party code is not built into the repo's
# own binaries, and Go tooling vendored by linters legitimately contains lists
# of standard packages, e.g. `"crypto/tls/fipsonly": {}` in golangci-lint's
# gci formatter. That matched as an import and flagged machine-api-operator and
# aws-load-balancer-operator as affected while their own code was clean.
EXCLUDES=(--exclude-dir=.git --exclude-dir=vendor)

# ── helpers ──────────────────────────────────────────────────────────────────

HITS_JSON="[]"

add_hit() {
  # add_hit <file> <line> <match> <description> <suggestion>
  local file="${1#./}"
  HITS_JSON=$(printf '%s' "${HITS_JSON}" | jq \
    --arg file    "${file}" \
    --argjson line "${2:-0}" \
    --arg match   "$3" \
    --arg desc    "$4" \
    --arg suggest "$5" \
    '. + [{file: $file, line: $line, match: $match,
           description: $desc, suggestion: $suggest}]')
}

# Numeric major/minor comparison: ver_ge 1.26 1.26 -> true, 1.9 1.26 -> false.
# Patch levels are ignored (1.26.0 == 1.26) because the initiative only cares
# which toolchain line a build root provides.
ver_ge() {
  local a="$1" b="$2" amaj amin bmaj bmin
  amaj="${a%%.*}"; amin="${a#*.}"; [ "${amin}" = "${a}" ] && amin=0; amin="${amin%%.*}"
  bmaj="${b%%.*}"; bmin="${b#*.}"; [ "${bmin}" = "${b}" ] && bmin=0; bmin="${bmin%%.*}"
  case "${amaj}${amin}${bmaj}${bmin}" in *[!0-9]*) return 1 ;; esac
  [ "${amaj}" -gt "${bmaj}" ] && return 0
  [ "${amaj}" -lt "${bmaj}" ] && return 1
  [ "${amin}" -ge "${bmin}" ]
}

# Prints "<line>\t<tag>" for the build root declared in .ci-operator.yaml.
# Handles the current block form, a flow-style one-liner, and the legacy
# build_root.image_stream_tag form. Prints nothing when undeclared.
ci_operator_build_root() {
  local f=".ci-operator.yaml"
  [ -f "${f}" ] || return 0

  awk '
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    function emit(v) { printf "%d\t%s\n", line, trim(v); found = 1; exit }

    # current style, flow form: build_root_image: {name: ..., tag: ...}
    /^[ \t]*build_root_image:[ \t]*\{/ {
      line = NR; v = $0
      if (match(v, /tag:[ \t]*[^,}]+/)) emit(substr(v, RSTART + 4))
      next
    }
    # current style, block form
    /^[ \t]*build_root_image:[ \t]*$/ { inbr = 1; next }
    inbr && /^[ \t]*tag:/ { line = NR; v = $0; sub(/^[ \t]*tag:[ \t]*/, "", v); emit(v) }
    inbr && /^[^ \t#]/ { inbr = 0 }
    # legacy style: build_root.image_stream_tag.tag
    /^[ \t]*image_stream_tag:[ \t]*$/ { inist = 1; next }
    inist && /^[ \t]*tag:/ { line = NR; v = $0; sub(/^[ \t]*tag:[ \t]*/, "", v); emit(v) }
    inist && /^[^ \t#]/ { inist = 0 }
  ' "${f}" | tr -d "\"'"
}

tag_version() { # tag_version <tag> <prefix>  -> e.g. 1.26 from "...-golang-1.26-..."
  printf '%s' "$1" | grep -oE "$2-[0-9]+\.[0-9]+" | head -1 | sed "s/$2-//"
}

# Build files where explicit FIPS settings can live.
BUILD_INCLUDES=(
  --include='Dockerfile*' --include='Containerfile*' --include='*.containerfile'
  --include='Makefile*' --include='makefile' --include='GNUmakefile' --include='*.mk'
  --include='*.sh' --include='*.env' --include='*.yaml' --include='*.yml'
)
CONTAINER_INCLUDES=(
  --include='Dockerfile*' --include='Containerfile*' --include='*.containerfile'
)
SCRIPT_INCLUDES=(
  "${CONTAINER_INCLUDES[@]}"
  --include='Makefile*' --include='makefile' --include='GNUmakefile' --include='*.mk'
  --include='*.sh'
)

# ── 0. only golang repositories are in scope ─────────────────────────────────
if [ -z "$(find . -name '*.go' -not -path './.git/*' -not -path './vendor/*' -print -quit 2>/dev/null)" ]; then
  debug "No Go source found - the golang FIPS migration does not apply."
  pass "No Go source in this repository, so the golang-native FIPS migration does not apply. If this repository ships a Go binary built elsewhere, it is out of this detection's scope."
fi

# ── 1. explicit build settings override the toolchain ────────────────────────
# Checked before the build root: these settings win over a newer toolchain.

debug "Scanning for explicit legacy FIPS settings..."
while IFS=: read -r file lineno match; do
  add_hit "${file}" "${lineno}" "${match}" \
    "Sets GOEXPERIMENT=boringcrypto, which links the binary against OpenSSL regardless of the build root's golang version." \
    "Drop GOEXPERIMENT=boringcrypto and rely on the golang 1.26 build root's native FIPS module instead."
done < <(grep -rnE 'GOEXPERIMENT[[:space:]]*[:=][[:space:]]*['\''"]?boringcrypto' \
  "${BUILD_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

while IFS=: read -r file lineno match; do
  grep -qE 'GOFIPS140' "${file}" 2>/dev/null && continue
  add_hit "${file}" "${lineno}" "${match}" \
    "Sets legacy GOFIPS=1 without GOFIPS140, which selects the old OpenSSL-backed path." \
    "Replace GOFIPS=1 with GOFIPS140=v1.26.0, or inherit it from the golang 1.26 build root."
done < <(grep -rnE '(^|[[:space:]])GOFIPS[[:space:]]*[:=][[:space:]]*1' \
  "${BUILD_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

while IFS=: read -r file lineno match; do
  add_hit "${file}" "${lineno}" "${match}" \
    "Imports the deprecated crypto/tls/fipsonly package, which is the pre-GOFIPS140 way to force FIPS TLS." \
    "Remove the crypto/tls/fipsonly import; a golang 1.26 build enforces FIPS-approved TLS automatically."
done < <(grep -rnE '"crypto/tls/fipsonly"' \
  --include='*.go' "${EXCLUDES[@]}" . 2>/dev/null || true)

while IFS=: read -r file lineno match; do
  printf '%s' "${match}" | grep -qE 'no_openssl' && continue
  add_hit "${file}" "${lineno}" "${match}" \
    "Uses an 'openssl' build tag, which links the binary against OpenSSL instead of the native FIPS module." \
    "Replace the openssl build tag with no_openssl and build with golang 1.26."
done < <(grep -rnE -- '-tags[[:space:]]+[^[:space:]]*openssl' \
  "${SCRIPT_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

while IFS=: read -r file lineno match; do
  add_hit "${file}" "${lineno}" "${match}" \
    "Sets GOLANG_FIPS=1 at build time. This is a runtime toggle that should not be set during a build." \
    "Remove GOLANG_FIPS=1 and use GOFIPS140=v1.26.0 from the build root's golang 1.26 toolchain."
done < <(grep -rnE 'GOLANG_FIPS[[:space:]]*[:=][[:space:]]*1' \
  "${CONTAINER_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

EXPLICIT_LEGACY=$(printf '%s' "${HITS_JSON}" | jq 'length')

# Explicit GOFIPS140 pins the native module even on an older build root. Only
# a v1.26+ pin (or the "certified" alias) selects the module the initiative
# requires, so the value is compared rather than merely matched.
EXPLICIT_NATIVE_LINE=""
EXPLICIT_NATIVE_VER=""
EXPLICIT_NATIVE_OK=""
while IFS= read -r hline; do
  EXPLICIT_NATIVE_LINE="${hline}"
  EXPLICIT_NATIVE_VER=$(printf '%s' "${hline}" | awk -F'GOFIPS140' '{print $2}' \
    | grep -oE '(certified|v?[0-9]+\.[0-9]+\.[0-9]+)' | head -1 | sed 's/^v//')
  break
done < <(grep -rnE 'GOFIPS140[[:space:]]*[:=]' \
  "${BUILD_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)
if [ -n "${EXPLICIT_NATIVE_VER}" ]; then
  if [ "${EXPLICIT_NATIVE_VER}" = "certified" ] || ver_ge "${EXPLICIT_NATIVE_VER}" 1.26; then
    EXPLICIT_NATIVE_OK="true"
  fi
fi

# ── 2. authoritative toolchain signal: the ci-operator build root ────────────
BR_LINE=""
BR_TAG=""
BR_RAW="$(ci_operator_build_root)"
if [ -n "${BR_RAW}" ]; then
  BR_LINE="${BR_RAW%%$'\t'*}"
  BR_TAG="${BR_RAW#*$'\t'}"
fi
GOLANG_VER=""
OCP_VER=""
[ -n "${BR_TAG}" ] && GOLANG_VER="$(tag_version "${BR_TAG}" golang)"
[ -n "${BR_TAG}" ] && OCP_VER="$(tag_version "${BR_TAG}" openshift)"
debug "Build root tag: ${BR_TAG:-<none>} (golang=${GOLANG_VER:-?} ocp=${OCP_VER:-?})"

SPEC=""
if [ -n "${GOLANG_VER}" ] && ver_ge "${GOLANG_VER}" 1.26; then
  SPEC=""
else
  SPEC="Every Go binary this repository ships to the OCP payload must be built with the golang-native FIPS module (golang 1.26+, GOFIPS140 v1.26.0) rather than linking OpenSSL. Determine where the payload toolchain is actually declared before editing: .ci-operator.yaml's build_root_image is the usual control point, but Konflux/Tekton pipelines, shared builder images, or a generated Dockerfile from another repository can override it. Do not edit Dockerfiles marked DO NOT EDIT; change the template that generates them."
fi

# ── 3. verdict ───────────────────────────────────────────────────────────────

if [ "${EXPLICIT_LEGACY}" -gt 0 ]; then
  # Explicit settings beat a migrated build root: they force the OpenSSL path.
  HITS_JSON=$(printf '%s' "${HITS_JSON}" | jq 'sort_by(.file, .line, .match)')
  COUNT=$(printf '%s' "${HITS_JSON}" | jq 'length')
  emit true medium \
    "Found ${COUNT} explicit legacy FIPS setting(s) that force the OpenSSL-backed path, regardless of the build root (${BR_TAG:-no build root declared})." \
    "${HITS_JSON}" "${SPEC}"
  exit 0
fi

if [ -n "${EXPLICIT_NATIVE_OK}" ]; then
  # A v1.26+ pin in the build files selects the native module regardless of
  # what the build root provides.
  pass "Build files pin GOFIPS140=${EXPLICIT_NATIVE_VER} (${EXPLICIT_NATIVE_LINE#./}), which selects the golang-native FIPS module directly. The ci-operator build root is ${BR_TAG:-not declared}. Confirm the pin covers every Go binary shipped in the OCP 5.1 payload."
fi

if [ -z "${BR_TAG}" ]; then
  if [ -d .tekton ] || [ -d .konflux ]; then
    pass "No ci-operator build root is declared; this repository appears to build through Konflux/Tekton. Its Go toolchain and FIPS settings are set by the Tekton pipeline and shared build images, which this detection does not inspect, so this needs manual review rather than an automatic verdict."
  fi
  pass "No ci-operator build root is declared and no explicit FIPS settings were found, so this detection cannot tell whether the Go toolchain is golang 1.26. Needs manual review rather than an automatic verdict."
fi

if [ -z "${GOLANG_VER}" ]; then
  add_hit ".ci-operator.yaml" "${BR_LINE}" "${BR_TAG}" \
    "Could not parse a golang version out of the build root tag, so its FIPS mode cannot be determined." \
    "Confirm the build root provides golang 1.26+ with the native FIPS module."
else
  if ver_ge "${GOLANG_VER}" 1.26; then
    if [ -n "${OCP_VER}" ] && ! ver_ge "${OCP_VER}" 5.1; then
      add_hit ".ci-operator.yaml" "${BR_LINE}" "${BR_TAG}" \
        "Build root provides golang ${GOLANG_VER} (native FIPS capable) but targets OCP ${OCP_VER}, not 5.1." \
        "Confirm this repository ships in the OCP 5.1 payload; if it does, move the build root to the golang-1.26 openshift-5.1 release image."
      HITS_JSON=$(printf '%s' "${HITS_JSON}" | jq 'sort_by(.file, .line, .match)')
      emit true low \
        "Go toolchain is already golang ${GOLANG_VER} (native FIPS), but the build root targets OCP ${OCP_VER} rather than 5.1." \
        "${HITS_JSON}" \
        "This repository already builds with the golang-native FIPS module. Confirm whether it produces any artifact consumed by the OCP 5.1 payload; if so, that build must use a golang-1.26 openshift-5.1 build root. Do not downgrade the toolchain while making that change."
      exit 0
    fi
    pass "Build root provides golang ${GOLANG_VER} and targets OCP ${OCP_VER:-unknown}, so Go binaries use the native FIPS module. No legacy FIPS settings were found in the build files."
  fi
  add_hit ".ci-operator.yaml" "${BR_LINE}" "${BR_TAG}" \
    "Build root provides golang ${GOLANG_VER}, which predates the golang-native FIPS module first shipped in golang 1.24 and required at v1.26.0." \
    "Move the build root to rhel-9-release-golang-1.26-openshift-5.1."
fi

HITS_JSON=$(printf '%s' "${HITS_JSON}" | jq 'sort_by(.file, .line, .match)')
emit true medium \
  "Build root still provides golang ${GOLANG_VER:-an unparseable version}, so the payload binary links OpenSSL for FIPS instead of using the native module." \
  "${HITS_JSON}" "${SPEC}"
exit 0
