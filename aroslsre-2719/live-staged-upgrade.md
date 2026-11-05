# Live staged-upgrade result, November 5, 2026

The exact merge sequence `f5e967b312 -> 79dadac9ed -> 1a91907c4a ->
50cdb250c1` did **not replace the worker**. Installing #9818 by itself advanced
the completed rollout baseline while preserving the bootstrap reference.
Installing #9988 afterward preserved that reference and the same Ready worker.

This directly reproduces Cesar's staged result on our self-managed Azure pool.
Together with the earlier incident-style combined upgrade and the focused
guard/status test, it supports the upgrade-order explanation for the different
results. The earlier production baseline's historical origin remains unverified.

## Observed states

| Observation (UTC) | Operator | Completed baseline | Completed full hash / bootstrap suffix | MD generation / revision | Worker |
|---|---|---|---|---|---|
| 12:42:02 | #9797 `79dadac9ed` | `93ad368a` | `7aa4fd27` | 1 / 1 | Ready |
| 12:45:25 | #9818 `1a91907c4a` | `f99c74a3` | `7aa4fd27` | 1 / 1 | Same, Ready |
| 12:51:13 | #9988 `50cdb250c1` | `f99c74a3` | `7aa4fd27` | 1 / 1 | Same, Ready |

The first #9818 reconcile, `b493f255-4c9e-47de-b82a-841701746ab4`, logged
`NodePool config is updating` at 12:44:48 and `Rollout config update complete`
at 12:44:49: `93ad368a -> f99c74a3`. Its MD patch changed metadata; the entire
MD spec and generation remained unchanged. The added MD rollout-target annotation
was `6dece739`. No new bootstrap reference was
needed, allowing the already-complete workload's status path to acknowledge
the new baseline.

The #9988 leader's first observed reconciles at 12:47:59 reported the MD as
`unchanged`. The monitor required the expected new image to hold leadership
before starting a 180-second stability period. All identity and spec checks
passed through 12:51:13. The old `7aa4fd27` token Secret existed; a token Secret
for calculated new full hash `0609ba24` did not exist.

## Evidence of no replacement

- NodePool UID: `397cf3b3-526e-411f-b690-070075048b63`.
- MD UID: `8ebdb672-00b8-4536-99e9-717e819d8b73`; its entire spec was identical
  before #9818, after #9818, and after #9988.
- Machine UID: `1fca7fbd-5477-4b22-8da9-738b6c29e223`.
- Ready guest Node UID: `72e3c02b-3811-4006-880c-2bc3ea4332a6`.
- Azure VM ID: `e9f96ee3-14dd-40a4-aacc-ecfee4b78db7`, unchanged and Succeeded.
- HC and NP specs, release 4.20.8, pinned HAProxy image, and actual CPO image
  and pod UID stayed unchanged across the tested #9818 and #9988 upgrades.
- The pool had no in-progress rollout marker at the settled observations.

The captured-input Go generator check calculated legacy baseline `93ad368a`,
new baseline `f99c74a3`, and desired new full hash `0609ba24`. The fresh pool's
old raw MCO config matched the previous reproduction's old config byte for
byte; the calculated new config matched its new config byte for byte.
HAProxy and hash/guard source files are unchanged between the #9988 merge
and the earlier incident target. Stub credentials were used only for this
offline calculation; the worker observations above are live.

## Why this differs from the combined upgrade

In the November 4 incident-style upgrade, the old baseline and changed payload
arrived at the new controller together. The bootstrap changed from `7aa4fd27`
to `0609ba24`, the MD generation advanced from 1 to 2, and an actual Azure
worker replacement completed. The standalone #9818 step in this experiment
absorbed the baseline difference first. The subsequent #9988 management-side
payload change therefore encountered a matching baseline and was suppressed.

## Setup boundary and retained artifacts

The Azure test RG was externally deleted at 10:24:59, before this staged test.
The initial fresh worker attempt failed with 403 because its identities and
network had been deleted. The copied recovery script recreated the same RG
and infrastructure and updated the HC workload identity client IDs before the
fresh pool reached Ready and before either tested upgrade. Those recovery
changes are excluded from the fixed-spec comparison above. The previous
worker VM was also deleted externally; its November 4 reproduction evidence
remains intact. This is a self-managed Azure experiment using the documented
CPO compatibility pin, not a replay of all production conditions.

Full private artifacts are under
`/Users/brcox/azure-self-managed-artifacts/AROSLSRE-2719-20261104/staged-20261105`:
`live-staged-comparison.json`, `staged-timeline.jsonl`, per-stage state files,
operator decisions, image pins, VM identities, captures, and recovery logs.
The sanitized comparison and selected operator decisions accompany this report.

The original target HO (`225d8d22`) was restored and its actual leader image
verified. The temporary pause on the earlier pool was removed. At 2026-11-05T12:54:18.341974+00:00,
the staged pool remained Ready with the same bootstrap and worker identities.
The earlier pool remains unready because its VM was deleted before this test;
that VM was not recreated as part of the staged upgrade comparison.
