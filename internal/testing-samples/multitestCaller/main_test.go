package multitestcaller

import (
	"context"
	"fmt"
	"testing"

	hyperv1 "github.com/openshift/hypershift/api/v1alpha1"
	e2eutil "github.com/openshift/hypershift/test/e2e/util"

	//corev1 "k8s.io/api/core/v1"
	//metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	. "github.com/onsi/gomega"
	crclient "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	ns              = "jparrill"
	hcName          = "jparrill-dev"
	annotationDrain = "machine.cluster.x-k8s.io/exclude-node-draining"
)

func TestNodePoolMain(t *testing.T) {
	t.Parallel()
	g := NewWithT(t)

	ctx, cancel := context.WithCancel(context.TODO())
	defer cancel()

	client, err := e2eutil.GetClient()
	g.Expect(err).NotTo(HaveOccurred(), "failed to get k8s client")

	guestClusters := &hyperv1.HostedClusterList{}
	err = client.List(ctx, guestClusters, &crclient.ListOptions{
		Namespace: ns,
	})
	g.Expect(err).NotTo(HaveOccurred(), "failed to get k8s already created Cluster")

	//guestClient := e2eutil.WaitForGuestClient(&t, ctx, client, &guestClusters.Items[0])
	guestCluster := &guestClusters.Items[0]

	fmt.Println(guestCluster)
	g.Expect(guestCluster.Name).To(Equal(hcName))

	//t.Run("KillRandomMembers", testKillRandomMembers(ctx, client, cluster))
	//t.Run("KillAllMembers", testKillAllMembers(ctx, client, cluster))
}
