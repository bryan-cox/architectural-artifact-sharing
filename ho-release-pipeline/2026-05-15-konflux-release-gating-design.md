# Konflux-based Release Promotion Pipeline for HyperShift Operator

**Date:** 2026-05-15
**Target Release:** 5.0 — ARO HCP only
**Feature:** [OCPSTRAT-3250](https://redhat.atlassian.net/browse/OCPSTRAT-3250)
**Design:** [CNTRLPLANE-1856](https://redhat.atlassian.net/browse/CNTRLPLANE-1856)
**Implementation Epic:** [CNTRLPLANE-3434](https://redhat.atlassian.net/browse/CNTRLPLANE-3434)

## Problem

Every merged HyperShift Operator (HO) build is auto-released to ACMD before platform-specific test results are available. Platform teams do run their own testing (ROSA regression tests, ARO HCP e2e tests), but these results do not gate the release. A bad image can be consumed by managed service teams before those tests complete. The gap is timing and gating — testing exists, but the auto-release does not wait for it.

## Solution

Add a parallel, gated promotion path alongside the existing auto-release. A nightly pipeline tests the latest HO image against platform-specific e2e suites and only promotes tested images to a verified repository. Each platform's promotion is independent — a failure on one does not block others.

The existing auto-release to ACMD continues unchanged.

## Architecture

```
Existing (unchanged):
  Push build → Snapshot → auto-release → ACMD (quay.io/acm-d/rhtap-hypershift-operator)

New (parallel, per platform):
  CronJob (nightly)
    → Resolve latest Snapshot from push builds
    → Run platform e2e tests against Snapshot image
    → Pass? → Create Konflux Release → Image promoted to verified repo
    → Fail? → Slack webhook notification
```

### Flow Detail

1. **Trigger:** A Kubernetes CronJob in the `crt-redhat-acm-tenant` namespace runs nightly.
2. **Resolve:** The CronJob queries Konflux Snapshots labeled with the push build's PipelineRun name, selects the most recent, and extracts the HO container image reference.
3. **Launch:** The CronJob creates a Tekton `PipelineRun` referencing the e2e test pipeline (`.tekton/pipelines/ho-release-gate.yaml`), passing the snapshot name and HO image as parameters.
4. **Test:** The pipeline deploys the resolved HO image and runs HyperShift e2e tests against it.
5. **Promote:** On pass, the pipeline's `finally` block creates a Konflux Release object referencing the tested Snapshot and a platform-specific ReleasePlan. Konflux's release pipeline pushes the image to the verified repository.
6. **Notify:** On failure, a Slack webhook fires with failure details (snapshot name, image ref, pipeline run link).

### Platform Extensibility

Each platform gets its own:
- `IntegrationTestScenario` (defines which tests to run)
- `ReleasePlan` (defines which verified repo to push to)
- Optionally its own CronJob schedule

Adding a new platform means creating these 2-3 Konflux resources. No pipeline code changes are needed.

ARO HCP is the pilot. ROSA HCP and GCP HCP follow the same pattern.

## Konflux Resources

### Nightly CronJob

```yaml
kind: CronJob
apiVersion: batch/v1
metadata:
  name: hypershift-operator-nightly-promotion
  namespace: crt-redhat-acm-tenant
spec:
  schedule: '15 3 * * *'  # 3:15 AM UTC, offset to avoid peak
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: resolve-and-test
            image: 'quay.io/konflux-ci/task-runner:v1'
            command: ["/bin/bash", "-c"]
            args:
            - |
              #!/bin/bash
              set -euo pipefail

              # Resolve the most recent Snapshot from push builds
              SNAPSHOT=$(oc get snapshot \
                --sort-by=.metadata.creationTimestamp \
                -l pac.test.appstudio.openshift.io/original-prname=hypershift-operator-main-on-push \
                -o jsonpath='{.items[-1].metadata.name}')
              HO_IMAGE=$(oc get snapshot $SNAPSHOT \
                -o jsonpath='{.spec.components[?(@.name=="hypershift-operator-main")].containerImage}')
              echo "Resolved snapshot: $SNAPSHOT"
              echo "HO image: $HO_IMAGE"

              # Create a PipelineRun to execute the e2e test pipeline
              oc create -f - <<EOF
              apiVersion: tekton.dev/v1
              kind: PipelineRun
              metadata:
                generateName: ho-release-gate-nightly-
                namespace: crt-redhat-acm-tenant
              spec:
                pipelineRef:
                  resolver: git
                  params:
                  - name: url
                    value: https://github.com/openshift/hypershift
                  - name: revision
                    value: main
                  - name: pathInRepo
                    value: .tekton/pipelines/ho-release-gate.yaml
                params:
                - name: snapshot-name
                  value: $SNAPSHOT
                - name: ho-image
                  value: $HO_IMAGE
                taskRunTemplate:
                  serviceAccountName: nightly-promotion-sa
              EOF
          serviceAccountName: nightly-promotion-sa
          restartPolicy: OnFailure
```

### RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nightly-promotion-sa
  namespace: crt-redhat-acm-tenant
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: nightly-promotion-role
  namespace: crt-redhat-acm-tenant
rules:
- apiGroups: ["appstudio.redhat.com"]
  resources: ["snapshots", "releases"]
  verbs: ["get", "list", "create"]
- apiGroups: ["appstudio.redhat.com"]
  resources: ["components"]
  verbs: ["get", "list", "patch"]
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns"]
  verbs: ["create", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nightly-promotion-binding
  namespace: crt-redhat-acm-tenant
subjects:
- kind: ServiceAccount
  name: nightly-promotion-sa
roleRef:
  kind: Role
  name: nightly-promotion-role
  apiGroup: rbac.authorization.k8s.io
```

### ReleasePlan (new, per-platform)

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: ReleasePlan
metadata:
  name: hypershift-operator-ho-release-gate-aro-hcp
  namespace: crt-redhat-acm-tenant
  labels:
    release.appstudio.openshift.io/auto-release: 'false'
spec:
  target: rhtap-releng-tenant
  application: hypershift-operator
```

A matching `ReleasePlanAdmission` in the `rhtap-releng-tenant` namespace is required. This may need coordination with the releng team.

### IntegrationTestScenario

```yaml
apiVersion: appstudio.redhat.com/v1beta2
kind: IntegrationTestScenario
metadata:
  name: hypershift-ho-release-gate-aro-hcp
  namespace: crt-redhat-acm-tenant
spec:
  application: hypershift-operator
  resolverRef:
    resolver: git
    params:
    - name: url
      value: https://github.com/openshift/hypershift
    - name: revision
      value: main
    - name: pathInRepo
      value: .tekton/pipelines/ho-release-gate.yaml
  contexts:
  - name: application
    description: HyperShift e2e tests for ARO HCP promotion gating
```

### Release Object (created programmatically on test pass)

```yaml
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  generateName: hypershift-operator-ho-release-gate-aro-hcp-
  namespace: crt-redhat-acm-tenant
spec:
  snapshot: <snapshot-name-that-passed-tests>
  releasePlan: hypershift-operator-ho-release-gate-aro-hcp
  gracePeriodDays: 7
```

## E2E Test Pipeline

A new Tekton pipeline at `.tekton/pipelines/ho-release-gate.yaml`.

### Tasks

| Task | Purpose |
|------|---------|
| `extract-image` | Parse Snapshot, extract HO image reference |
| `setup-test-env` | Provision or connect to test infrastructure |
| `deploy-ho` | Deploy the HO image under test |
| `run-e2e` | Execute the e2e test suite |
| `cleanup` | Tear down test resources |

### Finally Tasks

| Task | Condition | Purpose |
|------|-----------|---------|
| `create-release` | `run-e2e` succeeded | Create Konflux Release object |
| `notify-slack` | `run-e2e` failed | Send Slack webhook notification |

### Slack Notification

```yaml
- name: notify-slack
  when:
  - input: $(tasks.run-e2e.status)
    operator: in
    values: ["Failed"]
  taskSpec:
    steps:
    - name: send-notification
      image: curlimages/curl:latest
      script: |
        #!/bin/sh
        curl -X POST -H 'Content-type: application/json' \
          --data "{
            \"text\": \"HyperShift nightly promotion FAILED\nSnapshot: $(params.snapshot-name)\nImage: $(params.ho-image)\nPipeline: $(context.pipelineRun.name)\"
          }" \
          "${SLACK_WEBHOOK_URL}"
      env:
      - name: SLACK_WEBHOOK_URL
        valueFrom:
          secretKeyRef:
            name: slack-webhook
            key: url
```

### MVP Test Coverage

For the MVP, run HyperShift's own e2e suite from `test/e2e/`. Future iterations add platform-specific tests (ARO HCP e2e via Azure ARM API).

Minimum coverage targets from OCPSTRAT-3250:
- Every supported CPO latest 4.y.z
- Every supported CPO latest-minus-one 4.y.z
- Every supported minor release 4.y.0

Start with basic cluster lifecycle and one upgrade path, expand over time. Test matrix is configured via pipeline parameters.

## Error Handling

| Failure | Impact | Handling |
|---------|--------|----------|
| CronJob fails to resolve Snapshot | No test run | Slack alert + manual re-trigger |
| E2e tests fail | Image not promoted to verified repo | Slack alert. ACMD auto-release unaffected. |
| E2e tests flake | Unnecessary block | Manual re-trigger. Future: add retry logic. |
| Release creation fails | Tested image not promoted | Slack alert. Manual Release creation as fallback. |
| No promotion in N days | ARO HCP running stale image | Stale promotion alert (configurable threshold, default 3 days) |

### Manual Re-trigger

```bash
oc create job --from=cronjob/hypershift-operator-nightly-promotion manual-$(date +%s) -n crt-redhat-acm-tenant
```

### Stale Promotion Alert

A separate check (within the nightly CronJob or as its own CronJob) queries the last successful Release timestamp. If older than the configured threshold, fires a Slack alert. Corresponds to [CNTRLPLANE-3451](https://redhat.atlassian.net/browse/CNTRLPLANE-3451).

## Files to Create/Modify

| Location | File/Resource | Action |
|----------|---------------|--------|
| Repo | `.tekton/pipelines/ho-release-gate.yaml` | Create: E2E test pipeline |
| Konflux namespace | `ReleasePlan/hypershift-operator-ho-release-gate-aro-hcp` | Create: Gated release plan |
| Releng tenant | `ReleasePlanAdmission` | Create: Admission policy (releng coordination needed) |
| Konflux namespace | `IntegrationTestScenario/hypershift-ho-release-gate-aro-hcp` | Create: Wire e2e as Snapshot gate |
| Konflux namespace | `CronJob/hypershift-operator-nightly-promotion` | Create: Nightly trigger |
| Konflux namespace | `ServiceAccount/nightly-promotion-sa` | Create: CronJob identity |
| Konflux namespace | `Role/nightly-promotion-role` | Create: RBAC permissions |
| Konflux namespace | `RoleBinding/nightly-promotion-binding` | Create: RBAC binding |
| Konflux namespace | `Secret/slack-webhook` | Create: Webhook URL |

## Strategy Alignment

| Solution Element | Strategy / Feature | Implementation |
|---|---|---|
| Gated promotion path (nightly pipeline, test, promote) | [OCPSTRAT-3250](https://redhat.atlassian.net/browse/OCPSTRAT-3250) | [CNTRLPLANE-3434](https://redhat.atlassian.net/browse/CNTRLPLANE-3434) (epic), [CNTRLPLANE-3447](https://redhat.atlassian.net/browse/CNTRLPLANE-3447), [CNTRLPLANE-3449](https://redhat.atlassian.net/browse/CNTRLPLANE-3449) |
| ARO HCP as pilot platform | [OCPSTRAT-3250](https://redhat.atlassian.net/browse/OCPSTRAT-3250), [OCPSTRAT-2856](https://redhat.atlassian.net/browse/OCPSTRAT-2856) | [CNTRLPLANE-3448](https://redhat.atlassian.net/browse/CNTRLPLANE-3448) (ARO HCP e2e gate), [CNTRLPLANE-3452](https://redhat.atlassian.net/browse/CNTRLPLANE-3452) (credentials) |
| Independent promotion per platform | [OCPSTRAT-3250](https://redhat.atlassian.net/browse/OCPSTRAT-3250) | [CNTRLPLANE-3434](https://redhat.atlassian.net/browse/CNTRLPLANE-3434) (architecture) |
| Existing auto-release unchanged | [OCPSTRAT-3250](https://redhat.atlassian.net/browse/OCPSTRAT-3250) | No work needed — parallel path, not replacement |
| ROSA HCP — same pattern | [CNTRLPLANE-3438](https://redhat.atlassian.net/browse/CNTRLPLANE-3438) | Future — follows ARO HCP pilot template |
| GCP HCP — same pattern | [CNTRLPLANE-3439](https://redhat.atlassian.net/browse/CNTRLPLANE-3439) | Future — follows ARO HCP pilot template |
| Failure notifications & stale alerting | [OCPSTRAT-3250](https://redhat.atlassian.net/browse/OCPSTRAT-3250) | [CNTRLPLANE-3451](https://redhat.atlassian.net/browse/CNTRLPLANE-3451) (stale alert), [CNTRLPLANE-3450](https://redhat.atlassian.net/browse/CNTRLPLANE-3450) (re-trigger) |

## Open Questions

- **Test infrastructure:** Where do the e2e tests run? The pipeline needs a cluster with cloud credentials (Azure for ARO HCP, AWS for ROSA HCP). We need to coordinate with each platform team to get tests that can run on their infrastructure. See [CNTRLPLANE-3452](https://redhat.atlassian.net/browse/CNTRLPLANE-3452).
- **ReleasePlanAdmission:** Requires coordination with the releng team (`rhtap-releng-tenant`). What policies govern the verified repo? What approval workflows are needed?
- **Verified repo location:** Which quay.io repository serves as the verified/promoted destination? We need to create a new quay repo that the managed service teams (ARO HCP, ROSA HCP) can also reach.
- **Platform e2e test integration:** Bryan is working with the ARO HCP team to integrate their platform-specific e2e tests into the HyperShift repo, following the same pattern used for HyperShift's existing presubmit e2e tests.

## Related Issues

- [CNTRLPLANE-3446](https://redhat.atlassian.net/browse/CNTRLPLANE-3446) — Disable auto-release (NOT in our scope — we keep auto-release)
- [CNTRLPLANE-3447](https://redhat.atlassian.net/browse/CNTRLPLANE-3447) — Nightly snapshot resolution
- [CNTRLPLANE-3448](https://redhat.atlassian.net/browse/CNTRLPLANE-3448) — ARO HCP e2e gate
- [CNTRLPLANE-3449](https://redhat.atlassian.net/browse/CNTRLPLANE-3449) — Release creation on pass
- [CNTRLPLANE-3450](https://redhat.atlassian.net/browse/CNTRLPLANE-3450) — Manual re-trigger
- [CNTRLPLANE-3451](https://redhat.atlassian.net/browse/CNTRLPLANE-3451) — Stale promotion alerting
- [CNTRLPLANE-3452](https://redhat.atlassian.net/browse/CNTRLPLANE-3452) — Credential setup
