# AROSLSRE-2719 rollout investigation

This draft collects the investigation into unexpected worker replacement
during the November 3 and 4, 2026 HyperShift operator upgrades. We will update
it as we verify the customer history and compare the production payloads.

Start with the [production hash analysis](production-hash-analysis.md).
It explains the baseline comparison bug, the exact UK and AU hash matches,
and what remains unverified.

The [live Azure results](live-staged-upgrade.md) and
[upgrade-order analysis](upgrade-order.md) explain why installing #9818
before the HAProxy change kept the worker, while delivering both changes
together caused worker replacement in the reproduction.

The accompanying files contain the offline checks, saved Go test output,
operator decisions, image pins, and resource comparisons. Run the Python check
from the repository root:

```sh
python3 aroslsre-2719/check_production_hashes.py
```

The Go checks belong in the NodePool package of the pinned HyperShift source.
The reports describe that setup. These files do not include the complete
customer configuration or production bootstrap payloads.

Related issues: [AROSLSRE-2719](https://redhat.atlassian.net/browse/AROSLSRE-2719)
and [AROSLSRE-2720](https://redhat.atlassian.net/browse/AROSLSRE-2720).
