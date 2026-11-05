package nodepool

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	docker10 "github.com/openshift/api/image/docker10"
	imagev1 "github.com/openshift/api/image/v1"
	hyperv1 "github.com/openshift/hypershift/api/hypershift/v1beta1"
	"github.com/openshift/hypershift/support/api"
	"github.com/openshift/hypershift/support/releaseinfo"
	"github.com/openshift/hypershift/support/thirdparty/library-go/pkg/image/dockerv1client"
	supportutil "github.com/openshift/hypershift/support/util"
	fakeimage "github.com/openshift/hypershift/support/util/fakeimagemetadataprovider"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

// Investigation helper: captured live config inputs, no credentials or live writes.
func TestIncidentCapturedStagedRender(t *testing.T) {
	dir := os.Getenv("INCIDENT_STAGED_RUN")
	if dir == "" {
		t.Skip("explicit captured-input directory required")
	}
	var in struct {
		HC         hyperv1.HostedCluster `json:"hc"`
		NP         hyperv1.NodePool      `json:"np"`
		ConfigMaps corev1.ConfigMapList  `json:"configmaps"`
		Server     string                `json:"server"`
	}
	b, err := os.ReadFile(filepath.Join(dir, "private", "render-inputs.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(b, &in); err != nil {
		t.Fatal(err)
	}
	cfg := clientcmdapi.NewConfig()
	cfg.Clusters["captured"] = &clientcmdapi.Cluster{Server: in.Server}
	cfg.Contexts["captured"] = &clientcmdapi.Context{Cluster: "captured"}
	cfg.CurrentContext = "captured"
	kb, err := clientcmd.Write(*cfg)
	if err != nil {
		t.Fatal(err)
	}
	objs := []client.Object{&corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: in.HC.Status.KubeConfig.Name, Namespace: in.HC.Namespace}, Data: map[string][]byte{"kubeconfig": kb}}, &corev1.Secret{ObjectMeta: metav1.ObjectMeta{Name: in.HC.Spec.PullSecret.Name, Namespace: in.HC.Namespace}, Data: map[string][]byte{corev1.DockerConfigJsonKey: []byte("{}")}}}
	for i := range in.ConfigMaps.Items {
		objs = append(objs, &in.ConfigMaps.Items[i])
	}
	c := fake.NewClientBuilder().WithScheme(api.Scheme).WithObjects(objs...).Build()
	r := &NodePoolReconciler{Client: c, ImageMetadataProvider: &fakeimage.FakeRegistryClientImageMetadataProvider{Result: &dockerv1client.DockerImageConfig{Config: &docker10.DockerConfig{Labels: map[string]string{"io.openshift.hypershift.control-plane-operator-skips-haproxy": "true"}}}}}
	release := &releaseinfo.ReleaseImage{ImageStream: &imagev1.ImageStream{ObjectMeta: metav1.ObjectMeta{Name: "4.20.8"}}}
	raw, err := r.generateHAProxyRawConfig(t.Context(), &in.NP, &in.HC, release)
	if err != nil {
		t.Fatal(err)
	}
	cg, err := NewConfigGenerator(t.Context(), c, &in.HC, &in.NP, release, raw, "clusters-brcox-2719-1104-hc", "rhel-9")
	if err != nil {
		t.Fatal(err)
	}
	legacy := supportutil.HashSimple(cg.rolloutMcoRawConfig + cg.pullSecretName + cg.additionalTrustBundleName + cg.rolloutGlobalConfig + cg.rhelStream)
	t.Logf("captured old formula C=%s; new formula C=%s; desired full F=%s; endpoint=%s", legacy, cg.RolloutHashWithoutVersion(), cg.Hash(), cg.endpointConfig)
	if legacy != "93ad368a" || cg.RolloutHashWithoutVersion() != "f99c74a3" || cg.Hash() != "0609ba24" {
		t.Fatal("captured live inputs do not match the isolated baseline/payload change")
	}
	if err = os.WriteFile(filepath.Join(dir, "private", "calculated-target-mco-config.yaml"), []byte(cg.mcoRawConfig), 0600); err != nil {
		t.Fatal(err)
	}
}
