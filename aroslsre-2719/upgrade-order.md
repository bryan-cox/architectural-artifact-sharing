# Staged versus combined operator upgrades

The new Dan/Cesar results distinguish whether #9818 had a chance to reconcile the NodePool before #9988 changed the full payload. They do not contradict the combined-upgrade Azure reproduction.

In exact #9818 commit 1a91907c4a, capi.go lines533-538 return before status reconciliation when propagateVersionAndTemplate changes the workload spec. If the bootstrap reference and template stay unchanged, status reconciliation runs. For an already-complete MachineDeployment, lines797-801 replace the stored rollout baseline with the calculated target.

Therefore, with unchanged specs and a settled workload:

- Introduce the new rollout formula alone: C mismatches but F stays unchanged, so the bootstrap reference stays unchanged. The complete MD lets the controller advance C to the new formula without replacing workers.
- Add #9988 afterward: F changes but C already matches. The guard preserves the deployed bootstrap reference.
- Introduce the new formula and changed payload together: C mismatches while F differs, so the new bootstrap reference reaches the MD. The template update skips the status/completion branch and C stays old until rollout completion.

## Source and test verification

`git diff 1a91907c4a 225d8d22 -- hypershift-operator/controllers/nodepool/capi.go hypershift-operator/controllers/nodepool/token.go hypershift-operator/controllers/nodepool/config.go` is empty. The tested guard, token and hash code is identical across those revisions.

`incident_upgrade_order_test.go` adds two cases to the existing upstream rolloutFixture. Run by copying it into the nodepool package of the archived target source and executing:

```sh
go test ./hypershift-operator/controllers/nodepool -run '^TestIncidentStagedVersusCombinedUpgrade$' -count=1 -v
```

Results on November5:

```text
staged=true  oldC=1ed659f5 newC=b7c33673 baselineAfter=b7c33673
             oldF=1dcd3cd9 calculatedNewF=b4cc1db9 deployedF=1dcd3cd9 bootstrapChanged=false
staged=false oldC=1ed659f5 newC=b7c33673 baselineAfter=1ed659f5
             oldF=1dcd3cd9 calculatedNewF=b4cc1db9 deployedF=b4cc1db9 bootstrapChanged=true
PASS
```

The fixture simulates an already-complete CAPI workload before either change. It uses synthetic payload strings and the fixture's release4.18.5, calls the real guard/token/status functions, and does not run an API server, full operator upgrade or actual workers. It is a targeted control-flow test, not a second live Azure experiment. The historical-baseline provenance limitation remains. The actual combined-upgrade Azure worker replacement is separately documented in the parent README and private artifacts.

## What remains unconfirmed

Cesar's staged run is consistent with baseline absorption, but his resource snapshots are needed to show that this actually happened in that run. The useful comparison is NP nodePoolCurrentRolloutConfig plus MD bootstrap reference/revision immediately before and after the #9818-only step, then before #9988.

For production, determine whether the affected NodePool still had an incompatible old baseline when the build containing both #9818 and #9988 first reconciled it. Anthony's reported mismatched baseline and changed MD bootstrap support that branch, but baseline provenance and all contemporaneous inputs have not been reconstructed. These lab tests do not settle the customer incident by themselves.
