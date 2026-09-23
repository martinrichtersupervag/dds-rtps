# GitHub Actions: Interoperability Tests & Runner Documentation

This document describes the GitHub Actions workflow setup, runner environments, hosted machine marks, and test selection tools for the OMG DDS-RTPS interoperability testing suite.

---

## 1. Overview of Workflows

The repository includes GitHub Actions workflows under [`.github/workflows/`](file:///root/dds-rtps/.github/workflows/):

| Workflow | File | Description |
| :--- | :--- | :--- |
| **1 - Run Interoperability Tests** | [`1_run_interoperability_tests.yml`](file:///root/dds-rtps/.github/workflows/1_run_interoperability_tests.yml) | Executes matrix interoperability tests across selected DDS publishers and subscribers. Supports both cloud and local runners. |
| **2 - Upload Test Results to Drive** | [`2_upload_artifact.yml`](file:///root/dds-rtps/.github/workflows/2_upload_artifact.yml) | Packages test artifacts (HTML, Excel, XML, timestamps, runner metadata) and synchronizes them to Google Drive via Rclone. |
| **3 - Batch Run & Compare Reports** | [`batch_run_and_compare.yml`](file:///root/dds-rtps/.github/workflows/batch_run_and_compare.yml) | Runs multiple iterations ($N$ times) of Workflows 1 and 2, then compares and summarizes variations. |

---

## 2. Runner Environment Selection

Both `1_run_interoperability_tests.yml` and `2_upload_artifact.yml` feature a unified **Runner environment** dropdown (`type: choice`):

- **`ubuntu-latest` (GitHub-hosted):**
  - Runs in GitHub's managed cloud VMs.
  - Python requirements and scripts execute directly in the runner environment.
- **`self-hosted` (Local runner):**
  - Runs on a local machine configured as a GitHub self-hosted runner (e.g. Debian/Ubuntu).
  - Tests automatically execute inside isolated Docker containers via [`run_in_docker.sh`](file:///root/dds-rtps/run_in_docker.sh) to isolate DDS multicast traffic (`239.255.0.1`) from the local LAN.

---

## 3. Hosted Machine Marks in Results

Every test execution explicitly records whether it ran on `ubuntu-latest` or `self-hosted`:

### 3.1 GitHub Actions Interface
- **Dynamic Run Name:** Displayed at the top of the workflow page and in the Actions runs list:
  ```
  Run Interoperability Tests (ubuntu-latest)
  Run Interoperability Tests (self-hosted)
  ```
- **Job Summary (`$GITHUB_STEP_SUMMARY`):** Rendered under the run's **Summary** tab on GitHub:
  | Parameter | Value |
  | :--- | :--- |
  | **Hosted Machine / Runner** | `ubuntu-latest` (or `self-hosted`) |
  | **Timestamp** | `2026-09-23-03_10_22` |
  | **Triggered By** | `@username` |
  | **Workflow** | `1 - Run Interoperability Tests` |

### 3.2 Excel Report (`Summary` Sheet)
In the generated Excel report ([`interoperability_report.xlsx`](file:///root/dds-rtps/interoperability_report.xlsx)), the `Summary` worksheet header includes the runner mark directly below the Date:

```
+-------------------------------------------------------------+
| RTPS Interoperability tests                                  |
| Summary                                                     |
|                                                             |
| [DDS Logo]   Date               2026-09-23 03:10:22         |
|              Hosted machine     self-hosted                 |
|              Repo               https://github.com/omg-dds/..|
|              Documentation      https://omg-dds.github.io/..|
|              Unique tests count 1                           |
+-------------------------------------------------------------+
```

### 3.3 Archived Metadata
A `runner_env` file containing the environment string is packaged into the `interoperability_report_complete` artifact and preserved in Google Drive upload archives (`report_<timestamp>/`).

---

## 4. Publisher & Subscriber Selection

### 4.1 Supported DDS Implementations
```json
["connext_dds", "dust_dds", "eprosima_fastdds", "intercom_dds", "opendds", "toc_coredx_dds", "hdds", "eclipse_cyclone", "zzdds"]
```

### 4.2 Flexible Input Formats in Workflow Dispatch
You no longer need to write strictly formatted JSON when running from the GitHub UI:
- **`all`**: Runs all 9 DDS implementations.
- **Comma-separated list**: e.g. `connext_dds, opendds, dust_dds`.
- **JSON array**: e.g. `["connext_dds", "opendds"]`.

### 4.3 Interactive Selection Tool: `workflow_dispatcher.html`
An interactive web application ([`workflow_dispatcher.html`](file:///root/dds-rtps/workflow_dispatcher.html)) is provided in the repository root for selecting implementations with one click:

- **Features:**
  - **Publisher Selection Box:** Individual toggle chips with **[Select All]** and **[Deselect All]** buttons.
  - **Subscriber Selection Box:** Individual toggle chips with **[Select All]** and **[Deselect All]** buttons.
  - **Selection Modes:**
    - *Matrix Mode (Multi-select)*: Generates $M \times N$ test combinations.
    - *Pair Mode (Single-select / Radio)*: Quick 1-to-1 pair verification.
  - **Runner Toggle:** Easily switch between `ubuntu-latest` and `self-hosted`.
  - **One-Click Actions:**
    - **Copy JSON**: Copies the exact JSON array to paste into GitHub's modal.
    - **Copy Command**: Copies a ready-to-run `gh workflow run` CLI command.
    - **Trigger Workflow**: Optionally input a GitHub Personal Access Token (PAT) and dispatch the workflow directly via GitHub REST API without opening github.com.

---

## 5. Running from Command Line (`gh` CLI)

You can launch workflow runs directly using the GitHub CLI:

### Full Matrix Run (All implementations on ubuntu-latest)
```bash
gh workflow run "1 - Run Interoperability Tests" \
  -f runner="ubuntu-latest" \
  -f publishers="all" \
  -f subscribers="all"
```

### Selective Test Run on Self-Hosted Machine
```bash
gh workflow run "1 - Run Interoperability Tests" \
  -f runner="self-hosted" \
  -f publishers='["connext_dds","opendds"]' \
  -f subscribers='["opendds","dust_dds"]'
```

### Upload Results to Google Drive
```bash
gh workflow run "2 - Upload Test Results to Drive" \
  -f runner="ubuntu-latest"
```

---

## 6. Local Report Generation

When generating reports locally, pass the runner environment as an argument:

```bash
# Using the shell wrapper
./generate_reports.sh "self-hosted"
# or
./generate_reports.sh "ubuntu-latest"

# Or directly with Python
python3 generate_xlsx_report.py \
  --input junit_interoperability_report.xml \
  --output interoperability_report.xlsx \
  --runner "self-hosted"
```
If `--runner` is omitted, the script automatically checks for a local `runner_env` file, inspects the `RUNNER_ENVIRONMENT` environment variable, or defaults to `ubuntu-latest`.
