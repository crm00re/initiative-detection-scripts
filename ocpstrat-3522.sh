#!/bin/bash
# Detection script for initiative OCPSTRAT-3522
#
# Goal: Remove CVE surface from unused RPM-based components in the base
# image of Red Hat operator and layered-product container images by
# switching to UBI10 micro.
#
# Scope: operator images delivered in redhat-operator-index plus related
# images (operands) maintained by the same engineering team.
#
# Contract: prints exactly one JSON object to stdout, exits 0.
# stderr is debug logging. See docs/detection-scripts/detection-scripts.md.

IMAGE_REF="${1}"

emit_unaffected() {
    jq -n --arg s "${1:-Not affected}" \
        '{"affected":false,"summary":$s,"severity":"info","hits":[],"implementation_spec":""}'
}

emit_error() {
    # Never crash: emit an explanatory unaffected result
    emit_unaffected "Error inspecting image: ${1:-unknown error}"
}

if [[ -z "${IMAGE_REF}" ]]; then
    emit_unaffected "No image reference provided"
    exit 0
fi

# Bases that already satisfy the OCPSTRAT-3522 goal (RHEL10-based micro).
# 'ubi-micro' is the rolling alias for the latest micro image.
COMPLIANT_BASE_PATTERN="ubi10-micro|ubi-micro"

# Bases that are micro, but still RHEL8/RHEL9-based. These are affected:
# the initiative aligns with the RHEL10-based control plane (OCP 5.3).
OLDER_MICRO_BASE_PATTERN="ubi8-micro|ubi9-micro"

echo "Inspecting image: ${IMAGE_REF}" >&2

# Fetch full OCI config (includes history and labels)
CONFIG_JSON=$(skopeo inspect --override-arch amd64 --config "docker://${IMAGE_REF}" 2>&1)
CONFIG_EXIT=$?

if [[ ${CONFIG_EXIT} -ne 0 ]]; then
    ERROR_MSG=$(echo "${CONFIG_JSON}" | head -3 | tr '"' "'" | tr '\n' ' ')
    emit_error "${ERROR_MSG}"
    exit 0
fi

echo "Successfully retrieved image config" >&2

# ---- OSBS label-walking heuristic ----
# Red Hat/OSBS-built images carry LABEL instructions in the build history.
# The *first* LABEL entry with a resolvable (non-templated) name= value
# identifies the base image, because later LABEL entries overwrite those
# keys with the final image's identity.
base_name=""
base_version=""
base_component=""

while IFS= read -r created_by; do
    [[ "$created_by" == *"LABEL"* ]] || continue

    # Extract name="..." value — require whitespace before name= to
    # avoid matching $name= (templated). Skip values containing $.
    name=$(echo "$created_by" | sed -nE 's/.*[[:space:]]name="([^"]+)".*/\1/p' | head -1)
    [[ -z "$name" || "$name" == *'$'* ]] && continue

    base_name="$name"
    base_version=$(echo "$created_by" | sed -nE 's/.*version="([^"]+)".*/\1/p' | head -1)
    base_component=$(echo "$created_by" | sed -nE 's/.*com\.redhat\.component="([^"]+)".*/\1/p' | head -1)
    break
done < <(jq -r '.history[]?.created_by // empty' <<<"$CONFIG_JSON")

echo "Detected base image: name=${base_name:-unknown} version=${base_version:-} component=${base_component:-}" >&2

# ---- Outcome 1: compliant — already on a UBI10 micro base ----
if [[ -n "${base_name}" ]] && echo "${base_name}" | grep -qiE "(${COMPLIANT_BASE_PATTERN})"; then
    echo "Base image '${base_name}' is a UBI10 micro base" >&2
    emit_unaffected "Base image '${base_name}' (version=${base_version:-unknown}, component=${base_component:-unknown}) is already a UBI10 micro base"
    exit 0
fi

# ---- Outcome 2: older micro (RHEL8/RHEL9-based) ----
if [[ -n "${base_name}" ]] && echo "${base_name}" | grep -qiE "(${OLDER_MICRO_BASE_PATTERN})"; then
    echo "Base image '${base_name}' is micro but RHEL8/9-based" >&2
    MATCH="base_name=${base_name}"
    [[ -n "${base_version}" ]] && MATCH="${MATCH}; base_version=${base_version}"
    [[ -n "${base_component}" ]] && MATCH="${MATCH}; base_component=${base_component}"

    jq -n \
        --arg file        "${IMAGE_REF}" \
        --arg match       "${MATCH}" \
        --arg description "Base image '${base_name}' is a UBI micro base, but it is RHEL8/RHEL9-based. OCPSTRAT-3522 requires switching to UBI10 micro to align with the RHEL10-based control plane and worker node RHCOS images shipped with OpenShift 5.3." \
        --arg suggestion  "Rebase this image FROM registry.access.redhat.com/ubi10/micro. Because UBI10 micro has no package manager until DNF5 ships, rebuild the image with any required content copied in at build time rather than installing RPMs." \
        --arg summary     "Base image '${base_name}' is micro but not UBI10 micro" \
        --arg spec        "OCPSTRAT-3522 requires operator and related-product images to use UBI10 micro as their base image. This image currently builds FROM '${base_name}' (version=${base_version:-unknown}, component=${base_component:-unknown}), which is a micro base but RHEL8/RHEL9-based. Rebase the Dockerfile/Containerfile to FROM registry.access.redhat.com/ubi10/micro. Note that until DNF5 is available in micro images, RPM dependencies cannot be installed at build time — copy required content into the image instead. If the operator's RPM dependencies make the switch infeasible, close the tracker as a child item of the OCPSTRAT-3522 initiative with that justification." \
        '{
            "affected": true,
            "summary": $summary,
            "severity": "low",
            "hits": [
                {
                    "file":        $file,
                    "line":        0,
                    "match":       $match,
                    "description": $description,
                    "suggestion":  $suggestion
                }
            ],
            "implementation_spec": $spec
        }'
    exit 0
fi

# ---- Outcome 3: non-micro base (minimal, standard UBI, or unknown) ----
echo "Base image '${base_name:-unknown}' is not a UBI10 micro base" >&2

# Build a descriptive match string from the detected base
MATCH=""
if [[ -n "${base_name}" ]]; then
    MATCH="base_name=${base_name}"
    [[ -n "${base_version}" ]] && MATCH="${MATCH}; base_version=${base_version}"
    [[ -n "${base_component}" ]] && MATCH="${MATCH}; base_component=${base_component}"
else
    # Fallback: pull from final config labels if OSBS heuristic found nothing
    COMPONENT=$(echo "${CONFIG_JSON}" | jq -r '.config.Labels["com.redhat.component"] // ""' 2>/dev/null)
    IMAGE_NAME_LABEL=$(echo "${CONFIG_JSON}" | jq -r '.config.Labels["name"] // ""' 2>/dev/null)
    BASE_IMAGE_LABEL=$(echo "${CONFIG_JSON}" | jq -r '
        .config.Labels["io.buildah.base-image"] //
        .config.Labels["base-image"] //
        .config.Labels["org.opencontainers.image.base.name"] //
        ""
    ' 2>/dev/null)

    CONTEXT_PARTS=""
    [[ -n "${COMPONENT}" ]]        && CONTEXT_PARTS="${CONTEXT_PARTS}com.redhat.component=${COMPONENT}; "
    [[ -n "${IMAGE_NAME_LABEL}" ]] && CONTEXT_PARTS="${CONTEXT_PARTS}name=${IMAGE_NAME_LABEL}; "
    [[ -n "${BASE_IMAGE_LABEL}" ]] && CONTEXT_PARTS="${CONTEXT_PARTS}base-image=${BASE_IMAGE_LABEL}; "
    MATCH="${CONTEXT_PARTS:-No base image identity could be determined from image history or labels}"
    MATCH="${MATCH%%; }"
fi

if [[ -n "${base_name}" ]] && echo "${base_name}" | grep -qiE "minimal"; then
    SUMMARY="Base image '${base_name}' is an RPM-based minimal base, not UBI10 micro"
    SEVERITY="medium"
    DESC_DETAIL="The UBI minimal base still carries the RPM package manager and pre-installed RPM components. These are unnecessary for most Golang-based Kubernetes controllers and represent a CVE surface that continues to grow over time."
else
    SUMMARY="Image base is not a UBI10 micro base"
    SEVERITY="medium"
    DESC_DETAIL="OCPSTRAT-3522 requires operator and related-product images to use UBI10 micro as their base to eliminate the CVE surface of pre-installed RPM-based components."
fi

jq -n \
    --arg file        "${IMAGE_REF}" \
    --arg match       "${MATCH}" \
    --arg description "${DESC_DETAIL}" \
    --arg suggestion  "Rebuild this image using registry.access.redhat.com/ubi10/micro as the FROM instruction. Because UBI10 micro has no package manager until DNF5 ships, copy any required content into the image at build time rather than installing RPMs." \
    --arg summary     "${SUMMARY}" \
    --arg severity    "${SEVERITY}" \
    --arg spec        "OCPSTRAT-3522: this image must be rebased to UBI10 micro (registry.access.redhat.com/ubi10/micro). Detected base: ${MATCH}. Steps: (1) Change the Dockerfile/Containerfile FROM instruction to registry.access.redhat.com/ubi10/micro. (2) Because UBI10 micro has no package manager until DNF5 is available, remove any RPM install steps (dnf/microdnf/yum) and instead copy required binaries, libraries, and configuration into the image at build time. (3) Rebuild and verify the operator functions (most Golang-based Kubernetes controllers do not require the RPM-based components present in minimal bases). (4) If the amount of RPM dependencies the operator distribution introduces outweighs the RPMs present in the UBI minimal base image, the switch may not be effective — in that case close this tracker as a child item of the OCPSTRAT-3522 initiative with that justification. Timeline: align with the OpenShift 5.3 GA date (Oct 2027); platform-aligned operators have a 4-week grace period after GA." \
    '{
        "affected": true,
        "summary": $summary,
        "severity": $severity,
        "hits": [
            {
                "file":        $file,
                "line":        0,
                "match":       $match,
                "description": $description,
                "suggestion":  $suggestion
            }
        ],
        "implementation_spec": $spec
    }'

exit 0
