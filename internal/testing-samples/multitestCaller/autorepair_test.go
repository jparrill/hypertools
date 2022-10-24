package multitestCaller

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/service/ec2"
	. "github.com/onsi/gomega"
	hyperv1 "github.com/openshift/hypershift/api/v1alpha1"
	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	"k8s.io/apimachinery/pkg/util/wait"
	crclient "sigs.k8s.io/controller-runtime/pkg/client"
)

func testAutoRepair(parentCtx context.Context, mgmtClient crclient.Client, guestCluster *hyperv1.HostedCluster, guestClient crclient.Client, clusterOpts *options) func(t *testing.T) {
	return func(t *testing.T) {
		g := NewWithT(t)
		ctx, cancel := context.WithCancel(parentCtx)
		defer cancel()

		nodePools := &hyperv1.NodePoolList{}
		err := mgmtClient.List(ctx, nodePools, &crclient.ListOptions{
			Namespace: guestCluster.Namespace,
		})
		g.Expect(err).NotTo(HaveOccurred(), "failed to get NodePools")

		// Check nodes and Nodepool replicas

		numZones := int32(1)
		numNodes := int32(numZones * 2)
		t.Logf("Waiting for Nodes %d\n", numNodes)
		nodes := e2eutil.WaitForNReadyNodes(t, ctx, guestClient, numNodes, guestCluster.Spec.Platform.Type)

		for _, nodePool := range nodePools.Items {
			t.Logf("Checking availble Nodes at Region %s in Nodepool: %s", guestCluster.Spec.Platform.AWS.CloudProviderConfig.Zone, nodePool.Name)
			g.Expect(nodePool.Status.Replicas).To(Equal(nodePool.Spec.Replicas))
		}

		// Terminate one of the machines belonging to the cluster
		nodeToReplace := nodes[0].Name
		awsSpec := nodes[0].Spec.ProviderID
		g.Expect(len(awsSpec)).NotTo(BeZero())
		instanceID := awsSpec[strings.LastIndex(awsSpec, "/")+1:]
		t.Logf("Terminating AWS instance: %s", instanceID)
		ec2client := ec2Client(clusterOpts.AWSPlatform.AWSCredentialsFile, clusterOpts.AWSPlatform.Region)
		_, err = ec2client.TerminateInstances(&ec2.TerminateInstancesInput{
			InstanceIds: []*string{aws.String(instanceID)},
		})
		g.Expect(err).NotTo(HaveOccurred(), "failed to terminate AWS instance")

		// Wait for nodes to be ready again, without the node that was terminated
		t.Logf("Waiting for %d available nodes without %s", numNodes, nodeToReplace)
		err = wait.PollUntil(30*time.Second, func() (done bool, err error) {
			nodes := e2eutil.WaitForNReadyNodes(t, ctx, guestClient, numNodes, guestCluster.Spec.Platform.Type)
			for _, node := range nodes {
				if node.Name == nodeToReplace {
					return false, nil
				}
			}
			return true, nil
		}, ctx.Done())
		g.Expect(err).NotTo(HaveOccurred(), "failed to wait for new node to become available")
	}
}
