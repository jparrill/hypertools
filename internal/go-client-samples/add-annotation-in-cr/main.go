package main

import (
	"context"
	"fmt"

	//	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	//	corev1 "k8s.io/api/core/v1"
	//	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/openshift/hypershift/hypershift-operator/controllers/manifests"
	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	capiv1 "sigs.k8s.io/cluster-api/api/v1beta1"
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
	client, err := e2eutil.GetClient()
	if err != nil {
		panic(err)
	}
	machines := &capiv1.MachineList{}

	guestNamespace := manifests.HostedControlPlaneNamespace(ns, hcName).Name
	err = client.List(ctx, machines, &crclient.ListOptions{
		Namespace: guestNamespace,
	})
	if err != nil {
		panic(err)
	}

	for _, m := range machines.Items {
		newA := m.GetAnnotations()
		newA[annotationDrain] = ""
		m.SetAnnotations(newA)
		err := client.Update(context.Background(), &m)
		if err != nil {
			panic(err)
		}
		fmt.Println(m.GetAnnotations())
	}
}
