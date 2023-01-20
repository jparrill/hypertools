package main

import (
	"context"
	"fmt"

	//	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	corev1 "k8s.io/api/core/v1"
	//	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	crclient "sigs.k8s.io/controller-runtime/pkg/client"
)

func main() {
	ctx := context.TODO()
	client, err := e2eutil.GetClient()
	if err != nil {
		panic(err)
	}
	nodes := &corev1.NodeList{}
	if err := client.List(ctx, nodes); err != nil {
		panic(err)
	}

	if err = LabelNodes(ctx, client, nodes, "test", "prueba"); err != nil {
		panic(err)
	}

}

func LabelNodes(ctx context.Context, client crclient.Client, nodes *corev1.NodeList, key, value string) error {
	for _, n := range *&nodes.Items {
		original := n.DeepCopy()
		fmt.Printf("Labeling node %v with '%v':'%v' label\n", n.Name, key, value)
		n.Labels[key] = value
		if err := client.Patch(ctx, &n, crclient.MergeFrom(original)); err != nil {
			return fmt.Errorf("failed to update node labels in %s node: %v", n.Name, err)
		}
		fmt.Println(n.Labels)
	}
	return nil
}
