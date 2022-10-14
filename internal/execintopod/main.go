package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go/aws/credentials"
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
	contentType    = "application/x-compressed-tar"
)

// Main function will execute an etcd backup command into an ETCD Pod and
// Upload the content to S3 bucket
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
	date := time.Now().Format(time.RFC1123Z)
	CPns := fmt.Sprintf("%s-%s", nsName, hcName)
	EtcdPod, err := client.CoreV1().Pods(CPns).Get(contxt, "etcd-0", metav1.GetOptions{})
	if err != nil {
		panic(err)
	}
	path := fmt.Sprintf("/%s/%s-%s-snapshot.db", bucketName, hcName, EtcdPod.Name)
	postUrl := fmt.Sprintf("https://%s.s3.amazonaws.com", bucketName)
	postUri := fmt.Sprintf("%s-%s-snapshot.db", hcName, EtcdPod.Name)

	sout, serr, err := ExecuteRemoteCommand(EtcdPod, snapshotSave)
	if err != nil {
		panic(err)
	}

	sout, serr, err = ExecuteRemoteCommand(EtcdPod, snapshotStatus)
	if err != nil {
		fmt.Printf("STDOUT: %v\nSTDERR: %v\n", sout, serr)
		panic(err)
	}
	fmt.Printf("STDOUT: %v\nSTDERR: %v\n", sout, serr)

	// Configure AWS Client
	AWSCreds := credentials.NewSharedCredentials("/Users/jparrill/.aws/credentials", "default")
	secretAWSK, err := AWSCreds.Get()
	if err != nil {
		panic(err)
	}

	signatureString := fmt.Sprintf("PUT\n\n%v\n%v\n%s", contentType, date, path)
	authstring, err := presignUrlCreator(signatureString, secretAWSK)
	if err != nil {
		panic(err)
	}

	curlCommand := fmt.Sprintf(`/usr/bin/curl -X PUT "%s/%s" -H "Host: %s.s3.amazonaws.com" -H "Date: %v" -H "Content-Type: %s" -H "%s" --upload-file "%s"`, postUrl, postUri, bucketName, date, contentType, authstring, etcdBackupPath)

	sout, serr, err = ExecuteRemoteCommand(EtcdPod, curlCommand)
	if err != nil {
		fmt.Printf("STDOUT: %v\nSTDERR: %v\n", sout, serr)
		panic(err)
	}

}

func presignUrlCreator(signatureString string, creds credentials.Value) (string, error) {

	key := []byte(creds.SecretAccessKey)
	h := hmac.New(sha1.New, key)
	h.Write([]byte(signatureString))
	signatureHash := base64.StdEncoding.EncodeToString(h.Sum(nil))
	authstring := fmt.Sprintf("Authorization: AWS %s:%s", creds.AccessKeyID, signatureHash)
	return authstring, nil
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
