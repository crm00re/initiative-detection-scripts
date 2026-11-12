#!/usr/bin/env bash
# Fixture tests for detect-golang-native-fips.sh.
#
# Run from anywhere:  bash tests/detect-golang-native-fips.test.sh
#
# The script inspects a container image, so the fixtures are images. Building
# them needs go, podman and skopeo; when any is missing the suite reports SKIP
# and exits 0 so `for t in tests/*.test.sh` still works on a bare checkout.
# No registry and no credentials are required: the fixtures are built locally
# and handed to the script as oci: layouts.
#
# The image path is where the two bugs this suite exists to catch were found:
#   - layers that do not unpack (gzip blobs, read-only directories) make every
#     image look like it ships no Go binaries;
#   - matching bare "fips140v1.26" matches an OpenSSL build too, because Go
#     lays string constants adjacently, so the dangerous state reads as clean.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../detect-golang-native-fips.sh"

pass=0
fail=0

check() {
  local desc="$1" want="$2" got="$3"
  if [ "${want}" = "${got}" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "${desc}"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     want: %s\n     got:  %s\n' "${desc}" "${want}" "${got}"
  fi
}

missing=""
for tool in go podman skopeo jq; do
  command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if [ -n "${missing}" ]; then
  printf 'SKIP detect-golang-native-fips: missing tool(s):%s\n' "${missing}"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'chmod -R u+rwX "${WORK}" 2>/dev/null; rm -rf "${WORK}"' EXIT

run() { bash "${SCRIPT}" "$1"; }

# build_image <name> <dir>  -> oci layout at ${WORK}/oci-<name>
build_image() {
  local name="$1" ctx="${WORK}/ctx-${1}"
  mkdir -p "${ctx}"
  cp "${WORK}/app-${name}" "${ctx}/app"
  printf 'FROM scratch\nCOPY app /usr/bin/app\n' > "${ctx}/Dockerfile"
  ( cd "${ctx}" && podman build -q -t "local/app-${name}" . >/dev/null 2>&1 ) || return 1
  skopeo copy "containers-storage:localhost/local/app-${name}:latest" \
    "oci:${WORK}/oci-${name}:latest" >/dev/null 2>&1 || return 1
}

# ── fixtures ────────────────────────────────────────────────────────────────
# Two binaries from the same source, differing only in how FIPS was selected.
mkdir -p "${WORK}/src"
printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("hi") }\n' > "${WORK}/src/main.go"
printf 'module fixture\ngo 1.24\n' > "${WORK}/src/go.mod"
( cd "${WORK}/src" && GOFIPS140=v1.26.0 CGO_ENABLED=0 go build -o "${WORK}/app-native" . ) || {
  printf 'SKIP detect-golang-native-fips: could not build the Go fixtures\n'; exit 0; }
( cd "${WORK}/src" && CGO_ENABLED=0 go build -o "${WORK}/app-plain" . ) || {
  printf 'SKIP detect-golang-native-fips: could not build the Go fixtures\n'; exit 0; }

# An image that ships no Go at all must not be counted as compliant.
mkdir -p "${WORK}/ctx-nogo"
printf 'FROM scratch\nCOPY app /usr/bin/notgo\n' > "${WORK}/ctx-nogo/Dockerfile"
printf 'not a go binary\n' > "${WORK}/ctx-nogo/app"
podman build -q -t local/app-nogo "${WORK}/ctx-nogo" >/dev/null 2>&1 || true

skopeo copy "containers-storage:localhost/local/app-nogo:latest" \
  "oci:${WORK}/oci-nogo:latest" >/dev/null 2>&1 || true

if ! build_image native || ! build_image plain; then
  printf 'SKIP detect-golang-native-fips: could not build the image fixtures\n'
  exit 0
fi

# ── native ──────────────────────────────────────────────────────────────────
out="$(run "oci:${WORK}/oci-native:latest")"
check "GOFIPS140 build is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "GOFIPS140 build is severity info" "info" "$(jq -r '.severity' <<<"${out}")"
check "GOFIPS140 build has no hits" "0" "$(jq -r '.hits | length' <<<"${out}")"
check "native verdict names the module" "true" \
  "$(jq -r '.summary | test("native golang FIPS"; "i")' <<<"${out}")"

# ── plain build: no FIPS marker either way ─────────────────────────────────
out="$(run "oci:${WORK}/oci-plain:latest")"
check "unqualified build is affected" "true" "$(jq -r '.affected' <<<"${out}")"
check "unqualified build reports one hit" "1" "$(jq -r '.hits | length' <<<"${out}")"
check "unqualified hit names the binary" "/usr/bin/app" \
  "$(jq -r '.hits[0].match | split(" ")[0]' <<<"${out}")"
check "unqualified hit says no FIPS marker" "true" \
  "$(jq -r '.hits[0].match | test("no FIPS marker")' <<<"${out}")"
check "unqualified hit carries the go version" "true" \
  "$(jq -r '.hits[0].match | test("go1\\.[0-9]+")' <<<"${out}")"
check "affected result carries an implementation_spec" "true" \
  "$(jq -r '.implementation_spec | length > 0' <<<"${out}")"
check "implementation_spec names the real control point" "true" \
  "$(jq -r '.implementation_spec | test("ocp-build-data")' <<<"${out}")"
check "hit file is the image reference, not a path" "true" \
  "$(jq -r '.hits[0].file | startswith("oci:")' <<<"${out}")"
check "hit line is 0 for image scans" "0" "$(jq -r '.hits[0].line' <<<"${out}")"

# ── an image with no Go binaries is not a pass ─────────────────────────────
out="$(run "oci:${WORK}/oci-nogo:latest")"
check "image without Go binaries is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "image without Go binaries says why" "true" \
  "$(jq -r '.summary | test("no Go binaries")' <<<"${out}")"
check "no-Go verdict carries no hits" "0" "$(jq -r '.hits | length' <<<"${out}")"

# ── determinism: a dry run can be repeated and diffed ──────────────────────
check "two runs of the same image are byte-identical" "same" \
  "$([ "$(run "oci:${WORK}/oci-plain:latest")" = "$(run "oci:${WORK}/oci-plain:latest")" ] && echo same || echo different)"

# ── uninspectable target: explain, never claim compliance ──────────────────
out="$(run "oci:${WORK}/does-not-exist:latest")"
check "unpullable image is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "unpullable image says it proves nothing about compliance" "true" \
  "$(jq -r '.summary | test("not evidence that the image is compliant")' <<<"${out}")"

# ── contract completeness ──────────────────────────────────────────────────
for fixture in native plain nogo; do
  out="$(run "oci:${WORK}/oci-${fixture}:latest")"
  check "contract complete: ${fixture}" "true" \
    "$(jq -r '(.affected|type=="boolean") and (.summary|type=="string") and
              (.severity|type=="string") and (.hits|type=="array") and
              (.implementation_spec|type=="string")' <<<"${out}")"
done

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
