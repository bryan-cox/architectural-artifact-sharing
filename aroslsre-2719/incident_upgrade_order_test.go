package nodepool

import (
	"testing"

	"github.com/go-logr/logr"
	hyperv1 "github.com/openshift/hypershift/api/hypershift/v1beta1"
	"k8s.io/utils/ptr"
)

// This isolates the guard/status ordering with synthetic payload strings.
// It simulates an already-complete CAPI workload, not actual worker replacement.
func TestIncidentStagedVersusCombinedUpgrade(t *testing.T) {
	for _, staged := range []bool{true, false} {
		name := "combined-endpoint-and-payload"
		if staged {
			name = "endpoint-first-then-payload"
		}
		t.Run(name, func(t *testing.T) {
			f := newRolloutFixture(t, hyperv1.UpgradeTypeReplace)
			c := f.capi
			f.complete(t) // Establish a completed workload before either change.
			oldC := c.nodePool.Annotations[nodePoolAnnotationCurrentRolloutConfig]
			oldF := c.Hash()
			oldBootstrap := ptr.Deref(f.md.Spec.Template.Spec.Bootstrap.DataSecretName, "")
			delete(f.md.Annotations, nodePoolAnnotationTargetRolloutConfig)

			// #9818 adds this input to rollout hashes; the full hash excludes it.
			c.endpointConfig = "private=false,server=https://api.example.com:6443"
			newC := c.RolloutHashWithoutVersion()
			if newC == oldC || c.Hash() != oldF {
				t.Fatal("endpoint addition must change C while preserving F")
			}
			if staged {
				if f.reconcile(t) {
					t.Fatal("mismatch without a payload change must preserve bootstrap")
				}
				if c.nodePool.Annotations[nodePoolAnnotationCurrentRolloutConfig] != oldC {
					t.Fatal("propagation alone must not advance the baseline")
				}
				// Match reconcileMachineDeployment: only an unchanged template
				// proceeds into status reconciliation. Do not simulate a new rollout.
				c.reconcileMachineDeploymentStatus(t.Context(), logr.Discard(), f.md, f.template)
				if c.nodePool.Annotations[nodePoolAnnotationCurrentRolloutConfig] != newC {
					t.Fatal("already-complete workload must absorb the new baseline")
				}
				if ptr.Deref(f.md.Spec.Template.Spec.Bootstrap.DataSecretName, "") != oldBootstrap {
					t.Fatal("baseline absorption must leave bootstrap unchanged")
				}
			}

			// Model #9988's management-only bytes: F changes, C does not.
			c.mcoRawConfig += " + management-side HAProxy DNS change"
			if c.Hash() == oldF || c.RolloutHashWithoutVersion() != newC {
				t.Fatal("management payload mutation must change only F")
			}
			changed := f.reconcile(t)
			if changed == staged {
				t.Fatalf("bootstrap changed=%v; staged=%v", changed, staged)
			}
			if staged {
				if f.bootstrapHash() != oldF {
					t.Fatal("staged management change must preserve old payload")
				}
			} else if f.bootstrapHash() != c.Hash() || c.nodePool.Annotations[nodePoolAnnotationCurrentRolloutConfig] != oldC {
				t.Fatal("combined upgrade must adopt new payload with old baseline still pending")
			}
			t.Logf("staged=%v oldC=%s newC=%s baselineAfter=%s oldF=%s calculatedNewF=%s deployedF=%s bootstrapChanged=%v", staged, oldC, newC, c.nodePool.Annotations[nodePoolAnnotationCurrentRolloutConfig], oldF, c.Hash(), f.bootstrapHash(), changed)
		})
	}
}
