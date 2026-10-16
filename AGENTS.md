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


