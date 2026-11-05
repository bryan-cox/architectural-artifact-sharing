package nodepool

import (
	"encoding"
	"encoding/binary"
	"fmt"
	"hash/fnv"
	"strconv"
	"testing"

	hyperv1 "github.com/openshift/hypershift/api/hypershift/v1beta1"
	supportutil "github.com/openshift/hypershift/support/util"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// These are the observed rollout hashes reported in AROSLSRE-2719, not hashes
// calculated from a complete historical customer configuration. Restoring the
// FNV state tests an appended-input hypothesis without needing the old preimage.
func continueIncidentFNV(t *testing.T, previous, suffix string) string {
	t.Helper()
	value, err := strconv.ParseUint(previous, 16, 32)
	if err != nil {
		t.Fatal(err)
	}
	h := fnv.New32a()
	state, err := h.(encoding.BinaryMarshaler).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	binary.BigEndian.PutUint32(state[len(state)-4:], uint32(value))
	if err = h.(encoding.BinaryUnmarshaler).UnmarshalBinary(state); err != nil {
		t.Fatal(err)
	}
	if _, err = h.Write([]byte(suffix)); err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%08x", h.Sum32())
}

func TestIncidentProductionHashContinuation(t *testing.T) {
	for _, tc := range []struct{ region, previous, target string }{
		{"UK", "2862414f", "a9ac72f5"},
		{"AU", "321ab288", "f907c476"},
	} {
		t.Run(tc.region, func(t *testing.T) {
			actual := continueIncidentFNV(t, tc.previous, "private=true")
			if actual != tc.target {
				t.Fatalf("continued %s with private=true: got %s, want %s", tc.previous, actual, tc.target)
			}
			for _, other := range []string{"private=false", "private=true,port=6443"} {
				if got := continueIncidentFNV(t, tc.previous, other); got == tc.target {
					t.Fatalf("negative control %q unexpectedly matched", other)
				}
			}
			if supportutil.HashSimple(tc.previous+"private=true") == tc.target {
				t.Fatal("rehashing hexadecimal text must not be confused with restoring the FNV state")
			}
			t.Logf("%s: old state %s + bytes private=true = %s, exact reported target", tc.region, tc.previous, actual)
		})
	}
}

func TestIncidentProductionHashFormula(t *testing.T) {
	// Validate state continuation against the actual target HashSimple and
	// RolloutHashWithoutVersion methods, using known synthetic preimages.
	for _, input := range []string{"", "sanitized-core-config", "another-core-config\n"} {
		cg := &ConfigGenerator{rolloutConfig: &rolloutConfig{
			rolloutMcoRawConfig: input,
			pullSecretName:      "pull-secret",
			endpointConfig:      "private=true",
		}}
		legacy := supportutil.HashSimple(cg.rolloutMcoRawConfig + cg.pullSecretName + cg.additionalTrustBundleName + cg.rolloutGlobalConfig + cg.rhelStream)
		if got, want := continueIncidentFNV(t, legacy, cg.endpointConfig), cg.RolloutHashWithoutVersion(); got != want {
			t.Fatalf("actual old/new formula check: got %s, want %s", got, want)
		}
	}
}

func TestIncidentProductionHashEndpoint(t *testing.T) {
	t.Setenv("MANAGED_SERVICE", hyperv1.AroHCP)
	for _, tc := range []struct {
		name     string
		topology hyperv1.AzureTopologyType
		legacy   bool
	}{
		{name: "Azure private", topology: hyperv1.AzureTopologyPrivate},
		{name: "Azure public and private", topology: hyperv1.AzureTopologyPublicAndPrivate},
		{name: "legacy ARO Swift", legacy: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			hc := &hyperv1.HostedCluster{
				ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{}},
				Spec: hyperv1.HostedClusterSpec{Platform: hyperv1.PlatformSpec{
					Type:  hyperv1.AzurePlatform,
					Azure: &hyperv1.AzurePlatformSpec{Topology: tc.topology},
				}},
			}
			if tc.legacy {
				hc.Annotations[hyperv1.SwiftPodNetworkInstanceAnnotation] = "synthetic-swift-network"
			}
			// No API server advertise-address or port is set. A private path
			// needs no kubeconfig, Service object or Kubernetes client.
			got, err := endpointConfigString(t.Context(), nil, hc)
			if err != nil {
				t.Fatal(err)
			}
			if got != "private=true" {
				t.Fatalf("got endpoint string %q, want private=true", got)
			}
			t.Logf("%s produces endpointConfig=%q", tc.name, got)
		})
	}
}
