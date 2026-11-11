#!/usr/bin/env bash
# Fixture tests for detect-legacy-fips.sh.
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

# ── fixture: repo using every legacy indicator ────────────────────────────────
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

# ── determinism: the dry-run can be repeated and diffed ──────────────────────
check "two runs of the same tree are byte-identical" "same" \
  "$([ "$(run "${legacy}")" = "$(run "${legacy}")" ] && echo same || echo different)"

# ── line numbers sort numerically, not lexicographically ─────────────────────
ordering="${WORK}/ordering"
mkdir -p "${ordering}"
{ for n in $(seq 1 12); do
    if [ "${n}" -eq 2 ] || [ "${n}" -eq 10 ]; then
      echo "ENV GOLANG_FIPS=1"
    else
      echo "# filler ${n}"
    fi
  done; } > "${ordering}/Dockerfile"
out="$(run "${ordering}")"
check "line 2 sorts before line 10" "10" \
  "$(jq -r '.hits | map(.line) | last' <<<"${out}")"
check "line numbers stay numeric in JSON" "true" \
  "$(jq -r '[.hits[].line] | all(type == "number")' <<<"${out}")"

# ── regression: documentation mentioning GOFIPS140 is not a migration ────────
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

# ── already migrated: GOFIPS140 in build config ──────────────────────────────
migrated="${WORK}/migrated"
mkdir -p "${migrated}"
cat > "${migrated}/Dockerfile" <<'EOF'
FROM registry.access.redhat.com/ubi9/go-toolset:1.26 AS builder
ENV GOFIPS140=v1.26.0
RUN CGO_ENABLED=0 go build -tags no_openssl -o /app ./cmd/app
EOF
out="$(run "${migrated}")"
check "migrated repo is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "migrated result has severity info" "info" "$(jq -r '.severity' <<<"${out}")"
check "migrated result has empty hits" "0" "$(jq -r '.hits | length' <<<"${out}")"

# ── clean repo: no FIPS settings at all ──────────────────────────────────────
clean="${WORK}/clean"
mkdir -p "${clean}"
printf 'FROM scratch\n' > "${clean}/Dockerfile"
printf 'module example.com/clean\n\ngo 1.26\n' > "${clean}/go.mod"
out="$(run "${clean}")"
check "clean repo is not affected" "false" "$(jq -r '.affected' <<<"${out}")"
check "clean result is contract-complete" "true" \
  "$(jq -r 'has("severity") and has("hits") and has("implementation_spec")' <<<"${out}")"

# ── .git is not traversed ────────────────────────────────────────────────────
withgit="${WORK}/with-git"
mkdir -p "${withgit}"
printf 'FROM scratch\n' > "${withgit}/Dockerfile"
git -C "${withgit}" init -q .
printf 'ENV GOLANG_FIPS=1\n' > "${withgit}/.git/Dockerfile"
out="$(run "${withgit}")"
check ".git contents are not scanned" "false" "$(jq -r '.affected' <<<"${out}")"

# ── Containerfile-only repo: include globs must cover it ─────────────────────
containerfile="${WORK}/containerfile"
mkdir -p "${containerfile}"
cat > "${containerfile}/Containerfile" <<'EOF'
FROM registry.access.redhat.com/ubi9/go-toolset:1.23
ENV GOLANG_FIPS=1
EOF
out="$(run "${containerfile}")"
check "Containerfile GOLANG_FIPS=1 is detected" "true" "$(jq -r '.affected' <<<"${out}")"

# ── no_openssl alone is not a hit ────────────────────────────────────────────
noopenssl="${WORK}/no-openssl"
mkdir -p "${noopenssl}"
cat > "${noopenssl}/Makefile" <<'EOF'
build:
	go build -tags no_openssl -o bin/app ./cmd/app
EOF
out="$(run "${noopenssl}")"
check "no_openssl tag alone is not affected" "false" "$(jq -r '.affected' <<<"${out}")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
