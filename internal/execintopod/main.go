package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/remotecommand"
)

const (
	etcdBackupPath = "/var/lib/data/snapshot.db"
	snapshotSave   = "env ETCDCTL_API=3 /usr/bin/etcdctl --cacert /etc/etcd/tls/client/etcd-client-ca.crt --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key --endpoints=localhost:2379 snapshot save " + etcdBackupPath
	snapshotStatus = "env ETCDCTL_API=3 /usr/bin/etcdctl -w table snapshot status " + etcdBackupPath
)

func main() {
	// Get MGMT Cluster Kubeconfig
	config, err := clientcmd.BuildConfigFromFlags("", "/Users/jparrill/RedHat/RedHat_Engineering/hypershift/AWS/Kubeconfig")
	if err != nil {
		println("config build error")
	}

	contxt := context.TODO()

	client, err := kubernetes.NewForConfig(config)

	// Indentify number of ETCD pods
	hcName := "jparrill-dev"
	nsName := "jparrill"
	bucketName := "jparrill-hosted-us-west-1"
	CPns := fmt.Sprintf("%s-%s", nsName, hcName)
	EtcdPod, err := client.CoreV1().Pods(CPns).Get(contxt, "etcd-0", metav1.GetOptions{})
	if err != nil {
		panic(err)
	}

	sout, serr, err := ExecuteRemoteCommand(EtcdPod, snapshotSave)
	if err != nil {
		panic(err)
	}

	fmt.Printf("STDOUT: %v\nSTDERR: %v\n", sout, serr)
	sout, serr, err = ExecuteRemoteCommand(EtcdPod, snapshotStatus)
	if err != nil {
		panic(err)
	}
	fmt.Printf("STDOUT: %v\nSTDERR: %v\n", sout, serr)

	// Configure AWS Client
	AWSCreds := credentials.NewSharedCredentials("/Users/jparrill/.aws/credentials", "default")

	sess, err := session.NewSession(&aws.Config{
		Region:      aws.String("us-west-2"),
		Credentials: AWSCreds,
	})
	presignedUrl, err := presignUrlCreator(sess, bucketName, etcdBackupPath)
	if err != nil {
		panic(err)
	}

	fmt.Printf("%s", presignedUrl)

}

func GetEnvWithKey(key string) string {
	return os.Getenv(key)
}

func presignUrlCreator(sess *session.Session, key, value string) (string, error) {
	svc := s3.New(sess)
	req, _ := svc.GetObjectRequest(&s3.GetObjectInput{
		Bucket: aws.String(key),
		Key:    aws.String(value),
	})
	presignedUrl, err := req.Presign(15 * time.Minute)
	if err != nil {
		return presignedUrl, fmt.Errorf("Failed to sign request", err)
	}

	return presignedUrl, nil
}

func ExecuteRemoteCommand(pod *v1.Pod, command string) (string, string, error) {
	kubeCfg := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(),
		&clientcmd.ConfigOverrides{},
	)
	restCfg, err := kubeCfg.ClientConfig()
	if err != nil {
		return "", "", err
	}
	coreClient, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		return "", "", err
	}

	buf := &bytes.Buffer{}
	errBuf := &bytes.Buffer{}
	request := coreClient.CoreV1().RESTClient().
		Post().
		Namespace(pod.Namespace).
		Resource("pods").
		Name(pod.Name).
		SubResource("exec").
		VersionedParams(&v1.PodExecOptions{
			Command: []string{"/bin/sh", "-c", command},
			Stdin:   false,
			Stdout:  true,
			Stderr:  true,
			TTY:     true,
		}, scheme.ParameterCodec)
	exec, err := remotecommand.NewSPDYExecutor(restCfg, "POST", request.URL())
	err = exec.Stream(remotecommand.StreamOptions{
		Stdout: buf,
		Stderr: errBuf,
	})
	if err != nil {
		return "", "", fmt.Errorf("%w Failed executing command %s on %v/%v", err, command, pod.Namespace, pod.Name)
	}

	return buf.String(), errBuf.String(), nil
}
