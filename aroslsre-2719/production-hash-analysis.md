# Production rollout-hash analysis, November 5, 2026

Both reported production hash changes match the addition of `private=true`,
an endpoint setting that #9818 added to the rollout hash calculation. Python
checks and tests using HyperShift's Go functions produced the exact UK and AU
target hashes.

The operator saves a rollout hash on each NodePool. It compares that saved
hash with its current calculation to decide whether the worker configuration
has changed. This report calls the saved hash the baseline.

| Region | Reported saved baseline | Added bytes | Calculated hash | Reported target |
|---|---|---|---|---|
| UK | `2862414f` | `private=true` | `a9ac72f5` | `a9ac72f5` |
| AU | `321ab288` | `private=true` | `f907c476` | `f907c476` |

Anthony Vollmer reported these values in
[AROSLSRE-2719](https://redhat.atlassian.net/browse/AROSLSRE-2719), including his
November 4 comment at 19:47 UTC. I read that issue and AROSLSRE-2720 through
the Jira connector. I did not obtain new production Kusto results or snapshots
of customer resources.

## What the source establishes

The original #8698 merge `f5e967b312` calculates the saved baseline from:

```go
HashSimple(rolloutMcoRawConfig + pullSecretName + additionalTrustBundleName + rolloutGlobalConfig + rhelStream)
```

The #9818 merge `1a91907c4a` and incident target `225d8d22` calculate:

```go
HashSimple(rolloutMcoRawConfig + pullSecretName + additionalTrustBundleName + rolloutGlobalConfig + rhelStream + endpointConfig)
```

Both versions use the same `nodePoolCurrentRolloutConfig` annotation. The
#9818 initialization function keeps the annotation if it already exists.
The token and Cluster API code then compare its old value with the new hash.

That comparison is the bug. The two versions calculate the hash differently,
but #9818 does not account for an existing baseline from the old calculation.
The operator can therefore report a configuration change even when the endpoint
has stayed the same.

The #9797 revert `79dadac9ed` and immediate predecessor `51bfaf4a` have no
`nodePoolAnnotationCurrentRolloutConfig` references in the NodePool controller.
Neither version updates or removes this annotation. An old value can therefore
remain on a NodePool until #9818 reads it.

Relevant source:

- [Original calculation](https://github.com/openshift/hypershift/blob/f5e967b3129661723de45ecf69cc1f60d8a4e66d/hypershift-operator/controllers/nodepool/config.go).
- [Target calculation and endpoint resolver](https://github.com/openshift/hypershift/blob/225d8d2265006815d4487423b7ddac7571325d77/hypershift-operator/controllers/nodepool/config.go#L219).
- [Baseline preservation](https://github.com/openshift/hypershift/blob/225d8d2265006815d4487423b7ddac7571325d77/hypershift-operator/controllers/nodepool/nodepool_controller.go#L1032).
- [CAPI rollout comparison](https://github.com/openshift/hypershift/blob/225d8d2265006815d4487423b7ddac7571325d77/hypershift-operator/controllers/nodepool/capi.go#L647).

## Why the endpoint string can be private=true

The endpoint function starts its string with `private=<IsPrivateHC result>`.
It adds an API address or port only if the HostedCluster networking spec sets
one. For a private worker connection, the server resolver returns an empty
string before it looks up a shared-ingress Service or kubeconfig. The resulting
endpoint string can therefore be just `private=true`.

I tested the target endpoint function with synthetic Azure Private,
Azure PublicAndPrivate, and legacy ARO Swift clusters. Each returned
`private=true` when the API advertise-address and port were unset.
A cluster can have a public API while its workers use a private connection.
Its public API alone does not tell us which string this function returns.

These tests use constructed cluster objects. I have not retrieved the
customer's corresponding networking and Swift fields.

## Verification

`HashSimple` uses FNV-1a, a 32-bit hash printed as eight hexadecimal digits.
Those digits represent the hash function's saved numeric state. We can restore
that state and feed it the next string, `private=true`. The result is the hash
of the original input followed by that string. We do not need the original
input to perform this check.

This is different from hashing the text `2862414fprivate=true`, which would
give the wrong result.

The Python check implements this calculation for both reported hash pairs.
The Go tests restore the state through the standard library's FNV implementation
and compare the results with the reported targets. They also check the method
against HyperShift's `HashSimple` and `RolloutHashWithoutVersion` functions
using known inputs, then test the endpoint function with the Azure objects
described above. Adding `private=false` or `private=true,port=6443` does not
match either region's reported target.

Before running the tests, I checked that the archived `config.go`,
`support/util/util.go` and `support/netutil/visibility.go` matched commit
`225d8d22` byte for byte. I ran the tests in that source archive. I did not
edit the main source checkout or run commands against a live cluster.

```sh
python3 aroslsre-2719/check_production_hashes.py
# Copy incident_production_hash_test.go into the pinned archive's nodepool package.
go test -mod=vendor ./hypershift-operator/controllers/nodepool -run '^TestIncidentProductionHash' -count=1 -v
```

All three Go tests passed, including both regional hash checks and the three
Azure endpoint cases. The log is `production-hash-go-results.txt`.
These tests check the hash calculation and endpoint function. They do not
replay the customer's complete configuration.

## When this causes worker replacement

A false configuration-change decision does not always replace workers. If the
bootstrap payload stays the same, the operator can keep the MachineDeployment's
bootstrap reference. It can then see that the existing rollout is complete and
update the saved baseline.

If the payload also changes, the false decision can allow the operator to
change the bootstrap reference. Cluster API then replaces workers to apply
the new MachineDeployment template.

Dan kept the starting history the same and added only the HAProxy patch to
the upgrade that had not replaced workers. With that patch, his test replaced
workers. Our live Azure tests produced the same behavior when both changes
arrived together. Installing #9818 first let the operator update the baseline
before the HAProxy change arrived, and the worker stayed. See
`live-staged-upgrade.md`.

## What remains unverified

The same field addition explains the exact UK and AU hash differences. No
actual endpoint change is needed for that calculation. This supports #9818's
handling of an old baseline as the cause of the false configuration-change
decision in production.

A 32-bit hash can represent different inputs. The matches cannot rule out a
hash collision or other input changes that happen to produce the same result.
I have not recovered all historical inputs, identified which operator wrote
the customer annotations, or compared the old and new production payload bytes.

The source and live tests establish the baseline comparison bug. The production
hash matches support it as the incident's cause. The missing annotation history
and payload comparison still limit how much of the customer incident we can
prove.
