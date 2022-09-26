#!/bin/bash
set -xeu

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

cd ${HYPERSHIFT_PATH}

if [[ -z "${KUBECONFIG}" ]]; then
    echo "Please set Kubeconfig ENV var to install Hypershift"
    exit 1
fi


if [[ ${BUILD} == true ]]; then
    ## Compile in container for k8s execution in cloud
    GOOS=linux GOARCH=amd64 make IMG=${HYPERSHIFT_IMAGE} docker-build docker-push
    
    ## Compile it for M1 processor
    make build
fi 

aws s3api create-bucket --acl public-read --bucket $BUCKET_NAME --create-bucket-configuration LocationConstraint=$MGMT_REGION --region $MGMT_REGION || true

# Clean up any old operator deployment then install
oc delete deployment operator -n hypershift || true
oc wait pod --selector hypershift.openshift.io/operator-component=operator --for=delete --timeout=60s

${HYPERSHIFT_CLI} install \
  $([ -n "${HYPERSHIFT_IMAGE}" ] && echo "--hypershift-image ${HYPERSHIFT_IMAGE}") --oidc-storage-provider-s3-bucket-name $BUCKET_NAME --oidc-storage-provider-s3-credentials $AWS_CREDS --oidc-storage-provider-s3-region $MGMT_REGION 

oc wait --for=condition=ready pod -l hypershift.openshift.io/operator-component=operator --timeout=300s -n hypershift

cd ${BASE_PATH}
