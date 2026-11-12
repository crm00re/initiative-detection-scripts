#!/usr/bin/env bash
# detect-golang-native-fips.sh
# Initiative Engine detection script for OCPSTRAT-3842
# "Build OCP 5.1 with golang-native FIPS crypto"
#
# Type: image  (operates on a container image reference)
#
# Answers the requirement directly: were the Go binaries in this image built
# with the native golang FIPS crypto module (GOFIPS140=v1.26.0), or do they
# still link OpenSSL?
#
# WHY AN IMAGE SCAN
#   FIPS mode is chosen at build time by the ART shim
#   (openshift-eng/art-tools, doozer/doozlerib/golang_builder_FIPS_wrapper.sh):
#     golang >= 1.27                          -> native
#     golang == 1.26 && __doozer_group >= 5.1 -> native (GOFIPS140=v1.26.0)
#     otherwise                               -> GOFIPS140=off, OpenSSL backend
#   Neither the consuming repository nor its .ci-operator.yaml decides this -
#   the builder comes from ocp-build-data - so the only authoritative evidence
#   is the shipped binary. Grepping a repo for GOEXPERIMENT/GOFIPS cannot
#   answer the question, and a build root tag alone cannot either.
#
# HOW IT DECIDES
#   Pull the image with skopeo, unpack the layers, and find Go binaries by the
#   buildinfo magic they all carry ("Go buildinf:"). Then read the build
#   settings the toolchain embedded:
#     fips140v1.26 / GOFIPS140=v1.26.0 -> built with the native module
#     strictfipsruntime / boringcrypto -> built against OpenSSL
#   A binary with neither marker is an unqualified build and is reported as
#   such rather than assumed compliant.
#
#   An image with no Go binaries at all is NOT a pass: it means this detection
#   has nothing to say about it, and it is reported separately so it never
#   silently inflates the compliant count.
#
# Emits the JSON contract documented in AGENTS.md. Always exits 0: the worker
# drops an image (counts it as clean) when the script fails or prints invalid
# JSON, which would hide exactly what this is looking for.
#
# Environment: bash, skopeo, tar, grep, jq (all present in the SCI worker).
# 5 minute timeout per image.

set -uo pipefail

IMAGE_REF="${1:-}"
IMAGE_TIMEOUT_SECONDS="${SCI_DETECTION_TIMEOUT:-240}"

# Stable ordering so two runs of the same image produce identical JSON.
export LC_ALL=C

debug() { echo "[DEBUG] $*" >&2; }

emit() {
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

# Hits carry the image reference in "file" by convention: the worker rewrites
# that to the human-readable image name from the scan manifest. Per-binary
# detail therefore goes in "match" and "description".
add_hit() { # add_hit <match> <description> <suggestion>
  local match="$1" desc="$2" suggest="$3"
  HITS_JSON=$(printf '%s' "${HITS_JSON}" | jq \
    --arg image "${IMAGE_REF}" \
    --arg match "${match}" \
    --arg desc  "${desc}" \
    --arg suggest "${suggest}" \
    '. + [{file: $image, line: 0, match: $match,
           description: $desc, suggestion: $suggest}]')
}

HITS_JSON="[]"

if [ -z "${IMAGE_REF}" ]; then
  pass "No image reference was supplied, so nothing could be inspected. Verify the scan manifest for this item."
fi

# The manifest stores "<component>|<pull spec>", and while the batch image scan
# splits the two, the test-script path passes the raw pair through. Only the
# right-hand side is a valid reference, and a pull spec never contains "|", so
# tolerate both shapes rather than reporting an unpullable image - which reads as
# "not affected" and hides everything.
case "${IMAGE_REF}" in
  *"|"*) IMAGE_REF="${IMAGE_REF##*|}" ;;
esac

if ! command -v skopeo >/dev/null 2>&1; then
  pass "skopeo is not available in this worker, so ${IMAGE_REF} could not be inspected. This is an environment fault, not a finding about the image."
fi

WORKDIR="$(mktemp -d)" || pass "Could not create a working directory to inspect ${IMAGE_REF}."
trap 'rm -rf "${WORKDIR}"' EXIT

# ── 1. pull ─────────────────────────────────────────────────────────────────
IMG_DIR="${WORKDIR}/image"
ROOTFS="${WORKDIR}/rootfs"
mkdir -p "${ROOTFS}"

# Workers pass a bare pull spec; an explicit transport (oci:, dir:,
# containers-storage:, ...) is honoured so the script can be exercised against
# a locally built layout without a registry.
SRC_REF="${IMAGE_REF}"
case "${IMAGE_REF}" in
  docker://*|oci:*|dir:*|containers-storage:*|docker-archive:*) ;;
  *) SRC_REF="docker://${IMAGE_REF}" ;;
esac

debug "Pulling ${SRC_REF}..."
if ! timeout "${IMAGE_TIMEOUT_SECONDS}" skopeo copy --quiet --retry-times 2 \
    "${SRC_REF}" "dir:${IMG_DIR}" >/dev/null 2>"${WORKDIR}/pull.err"; then
  pass "Could not pull ${IMAGE_REF} (registry unreachable, image removed, or credentials missing), so its FIPS mode was not determined. This is not evidence that the image is compliant."
fi

# ── 2. unpack ───────────────────────────────────────────────────────────────
# Layers are applied in manifest order, because a later layer overrides an
# earlier one. The dir: transport keeps each layer in its original compressed
# form and names the file by hex digest without the "sha256:" prefix, so the
# compression is detected from the magic bytes rather than assumed: gzip is the
# normal case, zstd appears on newer images, and skopeo also drops signature-*
# and a JSON config file next to the layers. Assuming plain tar here silently
# extracts nothing and every image then looks like it ships no Go binaries.
extract_layer() {
  local f="$1" magic
  # Keep the tree writable. Layers routinely ship read-only directories
  # (usr/bin is mode 555 in the OCP base images) and a later layer that adds a
  # file to one of them then fails to extract as an unprivileged user -- which
  # silently loses the very binaries this script is looking for.
  chmod -R u+rwX "${ROOTFS}" 2>/dev/null || true
  magic=$(head -c4 "${f}" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "${magic}" in
    1f8b*)                  gzip -dc "${f}" 2>/dev/null | tar -xf - -C "${ROOTFS}" 2>/dev/null || true ;;
    28b52ffd)               command -v zstd >/dev/null 2>&1 && \
                              zstd -dc "${f}" 2>/dev/null | tar -xf - -C "${ROOTFS}" 2>/dev/null || true ;;
    7b*)                   : ;;  # JSON (config blob / signatures), not a layer
    *)                      tar -xf "${f}" -C "${ROOTFS}" 2>/dev/null || true ;;
  esac
}

layers_applied=0
if [ -f "${IMG_DIR}/manifest.json" ]; then
  while IFS= read -r digest; do
    [ -n "${digest}" ] || continue
    layer="${IMG_DIR}/${digest#sha256:}"
    [ -f "${layer}" ] || layer="${IMG_DIR}/${digest}"
    [ -f "${layer}" ] || continue
    extract_layer "${layer}"
    layers_applied=$((layers_applied + 1))
  done < <(jq -r '(.layers // [])[] | .digest' "${IMG_DIR}/manifest.json" 2>/dev/null)
fi

# Fall back to any remaining tarballs if the manifest could not be read.
if [ "${layers_applied}" -eq 0 ]; then
  for layer in "${IMG_DIR}"/*; do
    [ -f "${layer}" ] || continue
    extract_layer "${layer}"
  done
fi

debug "Applied ${layers_applied} layer(s)."

# ── 3. find Go binaries ─────────────────────────────────────────────────────
# Every Go binary carries the buildinfo blob, whose magic is "\xff Go buildinf:".
# Matching the printable part avoids depending on binary-safe grep quirks.
GO_BINARIES=$(grep -rlas -- 'Go buildinf:' "${ROOTFS}" 2>/dev/null | sed "s|^${ROOTFS}||" | sort)
GO_COUNT=$(printf '%s' "${GO_BINARIES}" | grep -c . || true)

if [ "${GO_COUNT}" -eq 0 ]; then
  debug "No Go binaries found in ${IMAGE_REF}."
  pass "${IMAGE_REF} contains no Go binaries, so the golang FIPS migration does not apply to it. Nothing was learned either way about components that ship Go binaries."
fi

debug "Found ${GO_COUNT} Go binary/binaries in ${IMAGE_REF}."

# ── 4. classify each binary ─────────────────────────────────────────────────
NATIVE=0
OPENSSL=0
UNQUALIFIED=0
DETAIL=""

while IFS= read -r rel; do
  [ -n "${rel}" ] || continue
  bin="${ROOTFS}${rel}"
  go_ver=$(grep -aoE 'go1\.[0-9]+(\.[0-9]+)?' "${bin}" 2>/dev/null | head -1)
  [ -n "${go_ver}" ] || go_ver="unknown go version"

  # Match whole build settings, never bare substrings. A bare "fips140v1.26"
  # appears in an OpenSSL build too - Go lays string constants out adjacently, so
  # "fips140" from a package path sits next to a "v1.26.0" constant - which
  # classified a real GOEXPERIMENT=strictfipsruntime binary as native. The
  # buildinfo writes "-tags=" and "GOFIPS140=" / "GOEXPERIMENT=" prefixed values,
  # and those are unambiguous.
  #
  # OpenSSL is tested first: it is the one state that must never be mistaken for
  # compliant.
  if grep -aqs -- 'GOEXPERIMENT=strictfipsruntime' "${bin}" 2>/dev/null ||
     grep -aqs -- '-tags=strictfipsruntime' "${bin}" 2>/dev/null ||
     grep -aqs -- 'GOEXPERIMENT=boringcrypto' "${bin}" 2>/dev/null ||
     grep -aqs -- '-tags=boringcrypto' "${bin}" 2>/dev/null; then
    state="openssl"
    OPENSSL=$((OPENSSL + 1))
    add_hit "${rel} (${go_ver}, openssl backend)" \
      "This binary was built against the OpenSSL-backed FIPS path (GOEXPERIMENT=strictfipsruntime or boringcrypto) rather than the native golang module. libopenssl is a runtime dependency of this image as a result." \
      "The toolchain and payload build group are controlled centrally by ART (ocp-build-data and the Doozer group), not by this repository. Confirm the component's OCP 5.1 build runs with golang 1.26+ on the openshift-5.1 group, then rebuild; change the repository only if it forces the OpenSSL path itself."
  elif grep -aqs -- '-tags=fips140v1.26' "${bin}" 2>/dev/null ||
       grep -aqs -- 'GOFIPS140=v1.26' "${bin}" 2>/dev/null; then
    state="native"
    NATIVE=$((NATIVE + 1))
  else
    state="unqualified"
    UNQUALIFIED=$((UNQUALIFIED + 1))
    add_hit "${rel} (${go_ver}, no FIPS marker)" \
      "This binary carries neither the native module marker (fips140v1.26) nor the OpenSSL marker (strictfipsruntime), so it was built without any FIPS configuration. It will not satisfy the FIPS requirement in either mode." \
      "Build this component with GOFIPS140=v1.26.0 on golang 1.26+ (openshift-5.1 build group), or explain why this binary does not need FIPS."
  fi
  DETAIL="${DETAIL}
  ${rel}: ${state}, ${go_ver}"
done <<< "${GO_BINARIES}"

debug "native=${NATIVE} openssl=${OPENSSL} unqualified=${UNQUALIFIED}"

SPEC="Every Go binary this image ships must be built with the golang-native FIPS module (golang 1.26+ on an openshift-5.1+ Doozer group, or golang 1.27+, with GOFIPS140=v1.26.0 rather than an OpenSSL-backed build). This evidence comes from the shipped image, not from the repository: the builder image is chosen in ocp-build-data and the FIPS mode is switched on by the ART build shim from the Doozer group, so editing Dockerfiles or .ci-operator.yaml will not change it. Establish whether this component's OCP 5.1 build already runs on the openshift-5.1 group before changing anything, and do not edit generated Dockerfiles marked DO NOT EDIT."

# ── 5. verdict ──────────────────────────────────────────────────────────────
if [ "${NATIVE}" -eq "${GO_COUNT}" ]; then
  pass "All ${GO_COUNT} Go binary/binaries in ${IMAGE_REF} were built with the native golang FIPS module (fips140v1.26).${DETAIL}"
fi

if [ "${OPENSSL}" -gt 0 ] && [ "${UNQUALIFIED}" -eq 0 ]; then
  SUMMARY="${OPENSSL} of ${GO_COUNT} Go binary/binaries in ${IMAGE_REF} were built against the OpenSSL-backed FIPS path."
elif [ "${UNQUALIFIED}" -gt 0 ] && [ "${OPENSSL}" -eq 0 ]; then
  SUMMARY="${UNQUALIFIED} of ${GO_COUNT} Go binary/binaries in ${IMAGE_REF} were built with no FIPS configuration at all."
else
  SUMMARY="${GO_COUNT} Go binary/binaries in ${IMAGE_REF} are not FIPS-native: ${OPENSSL} on the OpenSSL backend, ${UNQUALIFIED} with no FIPS configuration, ${NATIVE} native."
fi

HITS_JSON=$(printf '%s' "${HITS_JSON}" | jq 'sort_by(.match)')
emit true medium "${SUMMARY}" "${HITS_JSON}" "${SPEC}"
exit 0
