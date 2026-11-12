#!/usr/bin/env bash
# Fixture tests for detect-legacy-fips.sh (OCPSTRAT-3842).
#
# Run from anywhere:  bash tests/detect-legacy-fips.test.sh
# Requires bash + jq (both present in the SCI worker image).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../detect-legacy-fips.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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

run() { bash "${SCRIPT}" "$1"; }

# Every fixture needs Go source: the initiative covers golang binaries and a
# repo without any .go file is deliberately out of scope.
mk_go() { printf 'package main\n\nfunc main() {}\n' > "$1/main.go"; }

# The build root is what actually selects the toolchain. `.ci-operator.yaml`
# is the source of truth for an OCP-built repo, so most fixtures are one file.
mk_buildroot() { # mk_buildroot <dir> <tag>
  cat > "$1/.ci-operator.yaml" <<EOF
build_root_image:
  name: release
  namespace: openshift
  tag: $2
EOF
}

# ── migrated: golang 1.26 build root targeting 5.1 ───────────────────────────
migrated="${WORK}/migrated"
mkdir -p "${migrated}"
mk_go "${migrated}"
mk_buildroot "${migrated}" rhel-9-release-golang-1.26-openshift-5.1
out="$(run "${migrated}")"
check "5.1 build root is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "5.1 build root has severity info" "info" "$(jq -r '.severity' <<<"${out}")"
check "5.1 build root has no hits" "0" "$(jq -r '.hits | length' <<<"${out}")"
check "5.1 build root needs no implementation_spec" "" "$(jq -r '.implementation_spec' <<<"${out}")"

# ── native toolchain but still targeting an older payload ────────────────────
t50="${WORK}/ocp50"
mkdir -p "${t50}"
mk_go "${t50}"
mk_buildroot "${t50}" rhel-9-release-golang-1.26-openshift-5.0
out="$(run "${t50}")"
check "golang 1.26 on a 5.0 build root is affected" "true" "$(jq -r '.affected' <<<"${out}")"
check "golang 1.26 on a 5.0 build root is severity low" "low" "$(jq -r '.severity' <<<"${out}")"
check "5.0 build root hit points at the tag line" ".ci-operator.yaml:4" \
  "$(jq -r '.hits[0] | "\(.file):\(.line)"' <<<"${out}")"

# ── the primary case: build root predates the native module ──────────────────
old="${WORK}/legacy-buildroot"
mkdir -p "${old}"
mk_go "${old}"
mk_buildroot "${old}" rhel-9-release-golang-1.23-openshift-4.22
out="$(run "${old}")"
check "golang 1.23 build root is affected" "true" "$(jq -r '.affected' <<<"${out}")"
check "golang 1.23 build root is severity medium" "medium" "$(jq -r '.severity' <<<"${out}")"
check "the offending tag is quoted back in the hit" \
  "rhel-9-release-golang-1.23-openshift-4.22" "$(jq -r '.hits[0].match' <<<"${out}")"
check "affected result carries an implementation_spec" "true" \
  "$(jq -r '.implementation_spec | length > 0' <<<"${out}")"

# golang 1.26 is the requirement, not 1.2x: 1.9 must not sort as "newer".
nine="${WORK}/golang19"
mkdir -p "${nine}"
mk_go "${nine}"
mk_buildroot "${nine}" rhel-9-release-golang-1.9-openshift-4.14
check "golang 1.9 is compared numerically, not lexicographically" "true" \
  "$(jq -r '.affected' <<<"$(run "${nine}")")"

# ── legacy build_root.image_stream_tag form ─────────────────────────────────
legacy_style="${WORK}/image-stream-tag"
mkdir -p "${legacy_style}"
mk_go "${legacy_style}"
cat > "${legacy_style}/.ci-operator.yaml" <<'EOF'
build_root:
  image_stream_tag:
    cluster: https://api.ci.openshift.org
    namespace: ocp
    name: release
    tag: golang-1.15
EOF
out="$(run "${legacy_style}")"
check "legacy image_stream_tag build root is affected" "true" "$(jq -r '.affected' <<<"${out}")"
check "legacy image_stream_tag hit points at its tag line" ".ci-operator.yaml:6" \
  "$(jq -r '.hits[0] | "\(.file):\(.line)"' <<<"${out}")"

# ── a build root with no golang version in it ───────────────────────────────
# openshift/boilerplate:latest is the shared builder for the OSD/srep operators.
# Its toolchain is decided by that image, not by the consuming repository, so the
# repo cannot be judged from a clone. That is the same conclusion as having no
# build root, and it must be reported the same way instead of asserting that the
# binary "links OpenSSL" - which the script cannot know.
boilerplate="${WORK}/boilerplate-latest"
mkdir -p "${boilerplate}"
mk_go "${boilerplate}"
cat > "${boilerplate}/.ci-operator.yaml" <<'EOF'
build_root_image:
  name: boilerplate
  namespace: openshift
  tag: latest
EOF
out="$(run "${boilerplate}")"
check "boilerplate:latest is not reported as affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "boilerplate:latest is not claimed to link OpenSSL" "false" \
  "$(jq -r '.summary | test("OpenSSL")' <<<"${out}")"
check "the inherited build root is named in full" "true" \
  "$(jq -r '.summary | test("openshift/boilerplate:latest")' <<<"${out}")"
check "boilerplate:latest is routed to manual review" "true" \
  "$(jq -r '.summary | test("manual review"; "i")' <<<"${out}")"

# A floating tag with no name/namespace: still unresolved, and the summary must
# still name the tag rather than an anonymous "unparseable version".
opaque="${WORK}/floating-tag"
mkdir -p "${opaque}"
mk_go "${opaque}"
mk_buildroot "${opaque}" latest
out="$(run "${opaque}")"
check "a floating tag is not reported as affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "a floating tag is named in the summary" "true" \
  "$(jq -r '.summary | test("latest")' <<<"${out}")"

# Flow-style build_root_image must yield the same identity as the block form.
flow="${WORK}/flow-style"
mkdir -p "${flow}"
mk_go "${flow}"
cat > "${flow}/.ci-operator.yaml" <<'EOF'
build_root_image: {name: boilerplate, namespace: openshift, tag: latest}
EOF
out="$(run "${flow}")"
check "flow-style build root is parsed" "true" \
  "$(jq -r '.summary | test("openshift/boilerplate:latest")' <<<"${out}")"

# Flow-style with a golang tag must still reach the real verdict.
flowgo="${WORK}/flow-style-golang"
mkdir -p "${flowgo}"
mk_go "${flowgo}"
cat > "${flowgo}/.ci-operator.yaml" <<'EOF'
build_root_image: {name: release, namespace: openshift, tag: rhel-9-release-golang-1.23-openshift-4.22}
EOF
check "flow-style golang build root is judged on its tag" "true" \
  "$(jq -r '.affected' <<<"$(run "${flowgo}")")"

# No Go source wins over an unparseable build root: the initiative covers golang
# binaries, so the tag is never consulted.
nogo="${WORK}/non-go-floating"
mkdir -p "${nogo}"
printf '#include <stdio.h>\n' > "${nogo}/main.c"
mk_buildroot "${nogo}" latest
out="$(run "${nogo}")"
check "non-Go repo with a floating build root is out of scope" "false" "$(jq -r '.affected' <<<"${out}")"
check "non-Go repo reports no Go source" "true" \
  "$(jq -r '.summary | test("No Go source")' <<<"${out}")"

# ── no build root: state the limitation instead of guessing ─────────────────
nobr="${WORK}/no-buildroot"
mkdir -p "${nobr}"
mk_go "${nobr}"
out="$(run "${nobr}")"
check "missing build root is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "missing build root says manual review is needed" "true" \
  "$(jq -r '.summary | test("manual review"; "i")' <<<"${out}")"

# A Konflux-built repo has no ci-operator build root at all; the pipeline owns
# the toolchain, so the verdict must say so rather than claim compliance.
konflux="${WORK}/konflux"
mkdir -p "${konflux}/.tekton"
mk_go "${konflux}"
printf 'apiVersion: tekton.dev/v1\n' > "${konflux}/.tekton/build.yaml"
check "Konflux repo is routed to manual review" "true" \
  "$(jq -r '.summary | test("Konflux"; "i")' <<<"$(run "${konflux}")")"

# ── out of scope: no Go source at all ──────────────────────────────────────
c_repo="${WORK}/non-go"
mkdir -p "${c_repo}"
mk_buildroot "${c_repo}" rhel-9-release-golang-1.20-openshift-4.14
printf '#include <stdio.h>\n' > "${c_repo}/main.c"
out="$(run "${c_repo}")"
check "repo with no Go source is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "repo with no Go source explains it is out of scope" "true" \
  "$(jq -r '.summary | test("No Go source")' <<<"${out}")"

# ── explicit overrides ─────────────────────────────────────────────────────
# GOFIPS140 in the build files selects the native module even on an old root.
pinned="${WORK}/explicit-native"
mkdir -p "${pinned}"
mk_go "${pinned}"
mk_buildroot "${pinned}" rhel-9-release-golang-1.23-openshift-4.22
cat > "${pinned}/Dockerfile" <<'EOF'
FROM registry.access.redhat.com/ubi9/go-toolset:1.23 AS builder
ENV GOFIPS140=v1.26.0
RUN CGO_ENABLED=0 go build -o /app ./cmd/app
EOF
out="$(run "${pinned}")"
check "explicit GOFIPS140=v1.26.0 overrides an old build root" "false" "$(jq -r '.affected' <<<"${out}")"
check "explicit GOFIPS140 result names the pin" "true" \
  "$(jq -r '.summary | test("1.26.0")' <<<"${out}")"

# ... but only when the pin actually reaches the required version.
too_old="${WORK}/explicit-native-too-old"
mkdir -p "${too_old}"
mk_go "${too_old}"
mk_buildroot "${too_old}" rhel-9-release-golang-1.23-openshift-4.22
printf 'FROM ubi9/go-toolset:1.23\nENV GOFIPS140=v1.24.0\n' > "${too_old}/Dockerfile"
check "GOFIPS140 below v1.26.0 does not count as migrated" "true" \
  "$(jq -r '.affected' <<<"$(run "${too_old}")")"

# An explicit legacy setting beats a migrated build root: boringcrypto links
# OpenSSL no matter which toolchain the build root provides.
override="${WORK}/override-on-migrated"
mkdir -p "${override}"
mk_go "${override}"
mk_buildroot "${override}" rhel-9-release-golang-1.26-openshift-5.1
printf 'FROM ubi9/go-toolset:1.26\nENV GOEXPERIMENT=boringcrypto\n' > "${override}/Dockerfile"
out="$(run "${override}")"
check "explicit boringcrypto beats a migrated build root" "true" "$(jq -r '.affected' <<<"${out}")"
check "explicit legacy override is severity medium" "medium" "$(jq -r '.severity' <<<"${out}")"

# ── every legacy indicator, on a repo with no build root ───────────────────
legacy="${WORK}/legacy"
mkdir -p "${legacy}/cmd/app"
cat > "${legacy}/Dockerfile" <<'EOF'
FROM registry.access.redhat.com/ubi9/go-toolset:1.23 AS builder
ENV GOEXPERIMENT=boringcrypto
ENV GOFIPS=1
ENV GOLANG_FIPS=1
RUN go build -o /app ./cmd/app
EOF
cat > "${legacy}/Makefile" <<'EOF'
build:
	go build -tags openssl -o bin/app ./cmd/app
EOF
cat > "${legacy}/cmd/app/main.go" <<'EOF'
package main

import (
	_ "crypto/tls/fipsonly"
)

func main() {}
EOF
out="$(run "${legacy}")"
check "legacy repo is affected" "true" "$(jq -r '.affected' <<<"${out}")"
check "legacy repo reports 5 hits" "5" "$(jq -r '.hits | length' <<<"${out}")"
check "hit paths are repo-relative" "0" \
  "$(jq -r '[.hits[].file] | map(select(startswith("/") or startswith("./"))) | length' <<<"${out}")"
check "hit paths match the fixture exactly" \
  "Dockerfile:2 Dockerfile:3 Dockerfile:4 Makefile:2 cmd/app/main.go:4" \
  "$(jq -r '[.hits[] | "\(.file):\(.line)"] | join(" ")' <<<"${out}")"
check "hit paths are sorted" "true" \
  "$(jq -r '[.hits[].file] as $f | ($f == ($f | sort))' <<<"${out}")"
check "hit line numbers are integers" "true" \
  "$(jq -r '[.hits[].line] | all(type == "number")' <<<"${out}")"
check "affected result carries an implementation_spec" "true" \
  "$(jq -r '.implementation_spec | length > 0' <<<"${out}")"

# ── determinism: the dry-run can be repeated and diffed ────────────────────
check "two runs of the same tree are byte-identical" "same" \
  "$([ "$(run "${legacy}")" = "$(run "${legacy}")" ] && echo same || echo different)"

# ── line numbers sort numerically, not lexicographically ───────────────────
ordering="${WORK}/ordering"
mkdir -p "${ordering}"
{ for n in $(seq 1 12); do
    if [ "${n}" -eq 2 ] || [ "${n}" -eq 10 ]; then
      echo "ENV GOLANG_FIPS=1"
    else
      echo "# filler ${n}"
    fi
  done; } > "${ordering}/Dockerfile"
printf 'package main\n\nfunc main() {}\n' > "${ordering}/main.go"
out="$(run "${ordering}")"
check "line 2 sorts before line 10" "10" \
  "$(jq -r '.hits | map(.line) | last' <<<"${out}")"
check "line numbers stay numeric in JSON" "true" \
  "$(jq -r '[.hits[].line] | all(type == "number")' <<<"${out}")"

# ── regression: documentation mentioning GOFIPS140 is not a migration ──────
docs="${WORK}/docs-mention"
cp -r "${legacy}" "${docs}"
mkdir -p "${docs}/docs"
cat > "${docs}/docs/migration.md" <<'EOF'
# Migrating off legacy FIPS
Set GOFIPS140=v1.26.0 and drop GOEXPERIMENT=boringcrypto.
EOF
out="$(run "${docs}")"
check "doc mention of GOFIPS140 does not suppress hits" "true" \
  "$(jq -r '.affected' <<<"${out}")"
check "doc mention does not change the hit count" "5" \
  "$(jq -r '.hits | length' <<<"${out}")"

# ── .git is not traversed ──────────────────────────────────────────────────
# ── vendor/ is not scanned ───────────────────────────────────────────────────
# Regression from real repos: golangci-lint's vendored gci formatter ships a
# list of standard packages containing `"crypto/tls/fipsonly": {}`, which
# matched as an import and flagged machine-api-operator and
# aws-load-balancer-operator as affected. Vendored code is not built into the
# repository's own binaries.
vendored="${WORK}/vendored"
mkdir -p "${vendored}/vendor/github.com/golangci/golangci-lint/pkg/gci"
mk_go "${vendored}"
mk_buildroot "${vendored}" rhel-9-release-golang-1.26-openshift-5.1
cat > "${vendored}/vendor/github.com/golangci/golangci-lint/pkg/gci/standard_list.go" <<'EOF'
package gci

var standardPackages = map[string]struct{}{
	"crypto/tls/fipsonly": {},
}
EOF
out="$(run "${vendored}")"
check "vendored mention of the fipsonly package is not a hit" "false" "$(jq -r '.affected' <<<"${out}")"
check "vendored fixture reports no hits" "0" "$(jq -r '.hits | length' <<<"${out}")"

# ── .git is not traversed ────────────────────────────────────────────────────
withgit="${WORK}/with-git"
mkdir -p "${withgit}"
mk_go "${withgit}"
mk_buildroot "${withgit}" rhel-9-release-golang-1.26-openshift-5.1
git -C "${withgit}" init -q .
printf 'ENV GOLANG_FIPS=1\n' > "${withgit}/.git/Dockerfile"
check ".git contents are not scanned" "false" "$(jq -r '.affected' <<<"$(run "${withgit}")")"

# ── Containerfile-only repo: include globs must cover it ───────────────────
containerfile="${WORK}/containerfile"
mkdir -p "${containerfile}"
mk_go "${containerfile}"
cat > "${containerfile}/Containerfile" <<'EOF'
FROM registry.access.redhat.com/ubi9/go-toolset:1.23
ENV GOLANG_FIPS=1
EOF
check "Containerfile GOLANG_FIPS=1 is detected" "true" \
  "$(jq -r '.affected' <<<"$(run "${containerfile}")")"

# ── the -tags forms that actually work in practice ─────────────────────────
# `-tags openssl`, `-tags=openssl` and `-tags="openssl"` are all valid; an
# earlier version only matched the first, so a repo using the equals form was
# reported clean.
for form in '-tags openssl' '-tags=openssl' '-tags="openssl"' '-tags "openssl"'; do
  tdir="${WORK}/tags-$(printf '%s' "${form}" | tr -c 'a-zA-Z0-9' '_')"
  mkdir -p "${tdir}"
  mk_go "${tdir}"
  printf 'FROM x\nRUN go build %s -o /a ./cmd\n' "${form}" > "${tdir}/Dockerfile"
  check "openssl build tag detected in form: ${form}" "true" \
    "$(jq -r '.affected' <<<"$(run "${tdir}")")"
done

# ── golang 1.27+ qualifies regardless of the build group ────────────────────
# golang_builder_FIPS_wrapper.sh defaults GO_COMPLIANCE_BUILTIN_FIPS_INCLUDE to
# '.*' from 1.27 on; only 1.26 needs an openshift-5.1+ group.
g127="${WORK}/golang127-old-group"
mkdir -p "${g127}"
mk_go "${g127}"
mk_buildroot "${g127}" rhel-9-release-golang-1.27-openshift-5.0
check "golang 1.27 on a 5.0 build root is not affected" "false" \
  "$(jq -r '.affected' <<<"$(run "${g127}")")"

# ── no_openssl alone is not a hit ──────────────────────────────────────────
noopenssl="${WORK}/no-openssl"
mkdir -p "${noopenssl}"
mk_go "${noopenssl}"
mk_buildroot "${noopenssl}" rhel-9-release-golang-1.26-openshift-5.1
cat > "${noopenssl}/Makefile" <<'EOF'
build:
	go build -tags no_openssl -o bin/app ./cmd/app
EOF
check "no_openssl tag alone is not affected" "false" \
  "$(jq -r '.affected' <<<"$(run "${noopenssl}")")"

# ── contract completeness on every path ────────────────────────────────────
for fixture in "${migrated}" "${old}" "${nobr}" "${legacy}"; do
  out="$(run "${fixture}")"
  check "contract complete: $(basename "${fixture}")" "true" \
    "$(jq -r '(.affected|type=="boolean") and (.summary|type=="string") and
              (.severity|type=="string") and (.hits|type=="array") and
              (.implementation_spec|type=="string")' <<<"${out}")"
  check "no duplicate hits: $(basename "${fixture}")" "true" \
    "$(jq -r '[.hits[] | "\(.file):\(.line):\(.match)"] | (length == (unique | length))' <<<"${out}")"
done

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
