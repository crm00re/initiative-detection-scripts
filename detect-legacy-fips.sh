#!/usr/bin/env bash
# detect-legacy-fips.sh
# Initiative Engine detection script for OCPSTRAT-3842
# "Build OCP 5.1 with golang-native FIPS crypto"
#
# Type: script  (operates on a cloned repo)
#
# Detects repositories still using legacy OpenSSL-backed FIPS crypto
# that need to migrate to golang-native FIPS (GOFIPS140).
#
# Legacy indicators (repo IS affected):
#   1. GOEXPERIMENT=boringcrypto  â€” old BoringCrypto shim
#   2. GOFIPS=1 without GOFIPS140 â€” legacy FIPS env var
#   3. import "crypto/tls/fipsonly" â€” deprecated fipsonly package
#   4. Build tags referencing "openssl" (e.g. -tags openssl)
#   5. GOLANG_FIPS=1 in Dockerfiles â€” runtime var misused at build time
#
# Already-migrated (NOT affected):
#   - GOFIPS140=v1.26.0 or GOFIPS140=certified
#   - -tags no_openssl
#   - Repos with no FIPS-related settings at all

set -euo pipefail

REPO_DIR="${1:-.}"
cd "$REPO_DIR" || exit 1

# Stable byte order so two dry runs of the same commit produce identical JSON.
export LC_ALL=C

# Build files where FIPS settings live. Shared by the "already migrated" probe
# and the individual indicators so the two cannot disagree about what counts.
BUILD_INCLUDES=(
  --include='Dockerfile*' --include='Containerfile*' --include='*.containerfile'
  --include='Makefile*' --include='makefile' --include='GNUmakefile' --include='*.mk'
  --include='*.sh' --include='*.env' --include='*.yaml' --include='*.yml'
)
SCRIPT_INCLUDES=(
  --include='Dockerfile*' --include='Containerfile*' --include='*.containerfile'
  --include='Makefile*' --include='makefile' --include='GNUmakefile' --include='*.mk'
  --include='*.sh'
)
EXCLUDES=(--exclude-dir=.git)

# â”€â”€ helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
debug() { echo "[DEBUG] $*" >&2; }

HITS_JSON="[]"

add_hit() {
  local file="$1" line="$2" match="$3" description="$4" suggestion="$5"
  # AGENTS.md requires repo-relative hit paths; "$REPO_DIR" is absolute in the
  # worker, and grep reports it verbatim unless we strip the prefix here.
  file="${file#./}"
  HITS_JSON=$(echo "$HITS_JSON" | jq \
    --arg file      "$file" \
    --arg line      "$line" \
    --arg match     "$match" \
    --arg desc      "$description" \
    --arg suggest   "$suggestion" \
    '. + [{
        "file":        $file,
        "line":        ($line | tonumber),
        "match":       $match,
        "description": $desc,
        "suggestion":  $suggest
      }]')
}

# â”€â”€ early exit: check if already migrated â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
#
# Only a GOFIPS140 setting in *build* configuration means the repo is migrated.
# Scanning every file for the string meant a repo that merely documented the
# migration (README, issue template, vendored notes) was reported clean even
# when its Dockerfile still set GOEXPERIMENT=boringcrypto.

if grep -rqE 'GOFIPS140[[:space:]]*[:=]' "${BUILD_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null; then
  debug "Build configuration already sets GOFIPS140 - not affected."
  jq -n '{
    affected: false,
    severity: "info",
    summary: "Repository build configuration already sets GOFIPS140 (golang-native FIPS). No migration needed.",
    hits: [],
    implementation_spec: ""
  }'
  exit 0
fi

# â”€â”€ 1. GOEXPERIMENT=boringcrypto â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
debug "Scanning for GOEXPERIMENT=boringcryptoâ€¦"
while IFS=: read -r file lineno match; do
  add_hit "$file" "$lineno" "$match" \
    "Sets GOEXPERIMENT=boringcrypto, which links against OpenSSL for FIPS." \
    "Remove GOEXPERIMENT=boringcrypto and set GOFIPS140=v1.26.0 instead. Add CGO_ENABLED=0 if no other cgo dependencies exist."
done < <(grep -rnE 'GOEXPERIMENT\s*[:=]\s*['\''"]?boringcrypto' \
  "${BUILD_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

# â”€â”€ 2. GOFIPS=1 (legacy env var) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
debug "Scanning for GOFIPS=1â€¦"
while IFS=: read -r file lineno match; do
  # skip if the same file also sets GOFIPS140 (unlikely, but safe)
  if grep -qE 'GOFIPS140' "$file" 2>/dev/null; then
    debug "  Skipping $file â€” also contains GOFIPS140."
    continue
  fi
  add_hit "$file" "$lineno" "$match" \
    "Sets legacy GOFIPS=1 without GOFIPS140. This uses the old OpenSSL-backed path." \
    "Replace GOFIPS=1 with GOFIPS140=v1.26.0."
done < <(grep -rnE '(^|[[:space:]])GOFIPS\s*[:=]\s*1' \
  "${BUILD_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

# â”€â”€ 3. import "crypto/tls/fipsonly" â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
debug "Scanning for crypto/tls/fipsonly importsâ€¦"
while IFS=: read -r file lineno match; do
  add_hit "$file" "$lineno" "$match" \
    "Imports the deprecated crypto/tls/fipsonly package." \
    "Remove the crypto/tls/fipsonly import. When built with GOFIPS140, FIPS-approved TLS configuration is enforced automatically."
done < <(grep -rnE '"crypto/tls/fipsonly"' \
  --include='*.go' "${EXCLUDES[@]}" . 2>/dev/null || true)

# â”€â”€ 4. Build tags referencing "openssl" â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
debug "Scanning for openssl build tagsâ€¦"
while IFS=: read -r file lineno match; do
  # Ignore lines that are *removing* openssl (e.g. -tags no_openssl)
  if echo "$match" | grep -qE 'no_openssl'; then
    debug "  Skipping no_openssl usage in $file:$lineno"
    continue
  fi
  add_hit "$file" "$lineno" "$match" \
    "Uses an 'openssl' build tag, which links the binary against OpenSSL." \
    "Replace the openssl build tag with '-tags no_openssl' and set GOFIPS140=v1.26.0."
done < <(grep -rnE -- '-tags\s+\S*openssl' \
  "${SCRIPT_INCLUDES[@]}" "${EXCLUDES[@]}" . 2>/dev/null || true)

# â”€â”€ 5. GOLANG_FIPS=1 in Dockerfiles â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
debug "Scanning for GOLANG_FIPS=1â€¦"
while IFS=: read -r file lineno match; do
  add_hit "$file" "$lineno" "$match" \
    "Sets GOLANG_FIPS=1 at build time. This is a runtime toggle that should not be set during builds." \
    "Remove GOLANG_FIPS=1 and use GOFIPS140=v1.26.0 to enable golang-native FIPS at build time."
done < <(grep -rnE 'GOLANG_FIPS\s*[:=]\s*1' \
  --include='Dockerfile*' --include='Containerfile*' --include='*.containerfile' \
  "${EXCLUDES[@]}" . 2>/dev/null || true)

# â”€â”€ emit results â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
HITS_JSON=$(printf '%s' "$HITS_JSON" | jq 'sort_by(.file, .line, .match)')
HIT_COUNT=$(echo "$HITS_JSON" | jq 'length')
debug "Found $HIT_COUNT legacy FIPS indicator(s)."

if [ "$HIT_COUNT" -eq 0 ]; then
  jq -n '{
    affected: false,
    severity: "info",
    summary: "No legacy FIPS crypto indicators found. Repository either has no FIPS settings or is already using a non-OpenSSL approach.",
    hits: [],
    implementation_spec: ""
  }'
else
  jq -n \
    --argjson hits "$HITS_JSON" \
    --arg count "$HIT_COUNT" \
    --arg summary "Found $HIT_COUNT legacy OpenSSL-backed FIPS indicator(s). Migrate to GOFIPS140=v1.26.0 with -tags no_openssl." \
    '{
      affected: true,
      summary: $summary,
      severity: "medium",
      hits: $hits,
      implementation_spec: "Replace all legacy FIPS build settings (GOEXPERIMENT=boringcrypto, GOFIPS=1, GOLANG_FIPS=1, openssl build tags, crypto/tls/fipsonly imports) with GOFIPS140=v1.26.0 and -tags no_openssl. Set CGO_ENABLED=0 where no other cgo dependency exists."
    }'
fi

exit 0
