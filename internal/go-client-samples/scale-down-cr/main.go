package main

import (
	"context"
	"fmt"
	"time"

	//	e2eutil "github.com/openshift/hypershift/test/e2e/util"

	//	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	hyperv1 "github.com/openshift/hypershift/api/v1alpha1"
	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	"k8s.io/apimachinery/pkg/util/wait"
	crclient "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	ns              = "jparrill"
	hcName          = "jparrill-dev"
	annotationDrain = "machine.cluster.x-k8s.io/exclude-node-draining"
)

func main() {
	//var c client.Client
	ctx := context.TODO()
	var zeroReplicas int32 = 1
	client, err := e2eutil.GetClient()
	if err != nil {
		panic(err)
	}
	nodePools := &hyperv1.NodePoolList{}

	err = client.List(ctx, nodePools, &crclient.ListOptions{
		Namespace: ns,
	})
	if err != nil {
		panic(err)
	}

	numNodes := 1
	for _, nodePool := range nodePools.Items {
		fmt.Printf("Waiting for NodePool and Nodes \n", nodePool.Name, zeroReplicas)
		e2eutil.WaitForNReadyNodes(t, ctx, client, numNodes, "AWS")
	}

	// Update NodePools
	for _, nodePool := range nodePools.Items {
		err = client.Get(ctx, crclient.ObjectKeyFromObject(&nodePool), &nodePool)
		if err != nil {
			panic(err)
		}
		fmt.Printf("Updating NodePool %s Replicas to %d\n", nodePool.Name, zeroReplicas)
		original := nodePool.DeepCopy()
		nodePool.Spec.Replicas = &zeroReplicas
		err = client.Patch(ctx, &nodePool, crclient.MergeFrom(original))
		if err != nil {
			panic(err)
		}
	}

	// Wait for NodePools to get updated
	for _, nodePool := range nodePools.Items {
		err := wait.PollUntil(10*time.Second, func() (done bool, err error) {
			fmt.Printf("Waiting until NodePool scales to the desired state: Nodepool %s Replicas %d\n", nodePool.Name, zeroReplicas)
			err = client.Get(ctx, crclient.ObjectKeyFromObject(&nodePool), &nodePool)
			if err != nil {
				panic(err)
			}

			return nodePool.Status.Replicas == *nodePool.Spec.Replicas, nil
		}, ctx.Done())
		if err != nil {
			panic(err)
		}
	}
}
