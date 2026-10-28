# Initiative Detection Scripts

## What This Repo Is

A collection of shell scripts used by the Initiative Workflow Engine to detect whether a repository or container image is affected by an initiative. Each script is hosted here and referenced by URL in the initiative's Settings tab.

## How Detection Scripts Work

The SCI worker downloads the script at scan time and runs it against each repo or image in the initiative's scope. The script receives a single argument and must print a JSON result to stdout.

There is additional documentation at ~/code/initiative-engine-core/docs/detection-scripts

### Source Repo Scripts (`scanner_type = script`)

The script is invoked as:

```bash
bash detect-something.sh /path/to/cloned/repo
```

The argument is the local filesystem path to a shallow clone of the repository. The script can inspect any files in the repo (Dockerfiles, go.mod, package.json, YAML manifests, etc.) using standard unix tools.

### Image Scripts (`scanner_type = image`)

The script is invoked as:

```bash
bash detect-something.sh registry.redhat.io/org/image:tag
```

The argument is a fully qualified container image reference. The script can use `skopeo inspect` to examine image metadata, labels, and layer history. The worker environment has `skopeo` available. The script does NOT receive a cloned repo — image scans operate on the container image directly.

## Output Contract

The script must print exactly one JSON object to **stdout**. All diagnostic/progress messages should go to **stderr** (they are captured in logs but not parsed).

### Required JSON Fields

```json
{
  "affected": true,
  "summary": "Short description of what was detected",
  "severity": "medium",
  "hits": [
    {
      "file": "path/to/file or image reference",
      "line": 42,
      "match": "the specific text or value that triggered the hit",
      "description": "Detailed explanation of why this is a hit",
      "suggestion": "What the repo/image owner should do to remediate"
    }
  ],
  "implementation_spec": ""
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `affected` | boolean | yes | `true` if the repo/image needs action, `false` if it passes |
| `summary` | string | yes | One-line summary shown in the scan results table |
| `severity` | string | no | `"info"`, `"low"`, `"medium"`, `"high"`, `"critical"` |
| `hits` | array | yes | List of specific findings (can be empty `[]` if not affected) |
| `implementation_spec` | string | no | Additional implementation guidance (can be empty `""`) |

### Hit Object Fields

| Field | Type | Description |
|-------|------|-------------|
| `file` | string | For repo scans: relative path to the file. For image scans: the image reference. |
| `line` | number | Line number in the file (use `0` for image scans or when not applicable) |
| `match` | string | The specific value, label, or text that triggered detection |
| `description` | string | Detailed explanation shown in the expandable hit detail row |
| `suggestion` | string | Remediation guidance shown alongside the hit |

### Not-Affected Response

When the repo/image passes inspection, return:

```json
{
  "affected": false,
  "summary": "Everything looks good — reason why it passed",
  "severity": "info",
  "hits": [],
  "implementation_spec": ""
}
```

### Error Handling

If the script cannot inspect the target (e.g., image pull fails, missing tools), return `affected: false` with an explanatory summary rather than exiting non-zero. The worker treats non-zero exit codes and invalid JSON as scan failures.

## Writing `implementation_spec` Text

The `implementation_spec` is not just a comment on the finding — it becomes
the primary task description for the AI agent (Chai Bot) that implements the
fix, so how it is written directly determines whether the agent produces a
correct change. A real failure (SRVKS-1371 / openshift-knative/serving#1797)
is instructive: a spec that said "Change the Dockerfile/Containerfile FROM
instruction to registry.access.redhat.com/ubi10/micro" led the agent to edit
the FROM ARG in 29 Dockerfiles that were all marked `# DO NOT EDIT!
Generated Dockerfile`. The correct fix required changing Dockerfile
**templates** in a different repository, updating the Konflux
`imageOverrides` in that repository's build config, and reworking a template
that used `microdnf install`. The spec was prescriptive when it should have
been outcome-oriented.

### Outcome-oriented, not prescriptive

Describe the desired end state, not which specific file to edit. The solve
agent has access to the full source repository and can determine the correct
implementation path — the spec should tell it *what* to achieve, not *how*.

- Bad: "Change the Dockerfile FROM instruction to ubi10/micro."
- Good: "This image must use ubi10/micro as its runtime base. Determine
  where the base image reference is controlled before making changes."

### Acknowledge detection-level limitations

Image scripts (`scanner_type=image`) can only see OCI metadata — they don't
know whether Dockerfiles are hand-written or generated, whether the build
pipeline overrides values, or whether the source of truth is in a different
repository. The spec should explicitly note what the detection could and
could not see, so the agent knows to investigate further instead of assuming
that the first matching file is the thing to edit.

### Warn about common repo patterns

When writing a spec for a Dockerfile/image change, mention that the agent
should check for:

- **Generated files** — "DO NOT EDIT" markers, generator scripts such as
  `generate.sh`, Makefile targets that regenerate Dockerfiles
- **Build pipeline overrides** — Konflux `imageOverrides`, ci-operator
  configs, Tekton pipeline configs, Makefile ARG overrides
- **Cross-repo dependencies** — shared template repositories, external build
  configs owned by another team

### Keep it concise

The spec is injected into the agent's prompt alongside other instructions,
which have limited context. Long, overly detailed specs dilute the agent's
attention — focus on the goal, constraints, and investigation hints, not
step-by-step procedures.

### Include escape hatches

If the change might not be feasible for some repositories (e.g. heavy RPM
dependencies make a micro base infeasible), include guidance on how to close
the tracker with a justification instead of forcing a change that would
break the build or the operator.

## Environment

Scripts run inside the SCI worker container (Node.js 22 Alpine-based). Available tools:

- Standard unix: `bash`, `grep`, `find`, `awk`, `sed`, `jq`, `curl`
- Container tools: `skopeo` (for image inspection)
- Git: `git` (repo is already cloned; don't clone again)

Scripts have a **5-minute timeout**. If the script hasn't exited by then, it's killed and the item is reported as not affected with a timeout message.

## Naming Convention

Name scripts descriptively: `detect-<what-you-are-looking-for>.sh`

## Example: Image Scan Script

See `detect-non-ubi-minimal.sh` — inspects Red Hat container images to check whether they are built on an approved minimal base image (ubi9-minimal, ubi-micro, etc.). Demonstrates:

- Receiving an image reference as `$1`
- Using `skopeo inspect --config` to read OCI metadata
- Parsing image build history with `jq` to identify the base image
- Returning structured JSON with hit details when the base doesn't match


