package multitestCaller

import (
	"context"
	"fmt"
	"testing"

	"github.com/aws/aws-sdk-go/service/ec2"
	hyperv1 "github.com/openshift/hypershift/api/v1alpha1"
	awsutil "github.com/openshift/hypershift/cmd/infra/aws/util"
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
	g := NewWithT(t)

	ctx, cancel := context.WithCancel(context.TODO())
	clusterOpts := globalOpts.DefaultClusterOptions(t)
	defer cancel()

	mgmtClient, err := e2eutil.GetClient()
	g.Expect(err).NotTo(HaveOccurred(), "failed to get k8s client")

	guestClusters := &hyperv1.HostedClusterList{}
	err = mgmtClient.List(ctx, guestClusters, &crclient.ListOptions{
		Namespace: ns,
	})
	g.Expect(err).NotTo(HaveOccurred(), "failed to get k8s already created Cluster")

	guestClient := e2eutil.WaitForGuestClient(t, ctx, mgmtClient, &guestClusters.Items[0])
	guestCluster := &guestClusters.Items[0]

	fmt.Println(guestCluster)
	g.Expect(guestCluster.Name).To(Equal(hcName))

	// Wait for the rollout to be reported complete
	t.Logf("Waiting for cluster rollout. Image: %s", globalOpts.LatestReleaseImage)
	e2eutil.WaitForImageRollout(t, ctx, mgmtClient, guestClient, guestCluster, globalOpts.LatestReleaseImage)

	t.Run("TestAutoRepair", testAutoRepair(ctx, mgmtClient, guestCluster, guestClient, clusterOpts))
	//t.Run("KillAllMembers", testKillAllMembers(ctx, client, cluster))
}

func ec2Client(awsCredsFile, region string) *ec2.EC2 {
	awsSession := awsutil.NewSession("e2e-autorepair", awsCredsFile, "", "", region)
	awsConfig := awsutil.NewConfig()
	return ec2.New(awsSession, awsConfig)
}
