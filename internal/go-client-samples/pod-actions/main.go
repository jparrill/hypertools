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
	pods := &corev1.PodList{}
	if err := client.List(ctx, pods, &crclient.ListOptions{Namespace: "kube-system"}); err != nil {
		panic(err)
	}

	for _, p := range pods.Items {
		fmt.Println(p.Labels)
	}
}
