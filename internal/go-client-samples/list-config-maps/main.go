package main

import (
	"context"
	"fmt"

	//	e2eutil "github.com/openshift/hypershift/test/e2e/util"

	e2eutil "github.com/openshift/hypershift/test/e2e/util"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
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

	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: ns,
			Name:      "hugepages-tuned-test",
		},
	}
	err = client.Create(ctx, configMap)
	if !errors.IsAlreadyExists(err) {
		fmt.Println("Error creating the ConfigMap:", configMap)
	}

	fmt.Println(configMap)

}
