#!/bin/bash
set -xeu

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

if [[ -z ${1} || ${1} == " " ]];then
    echo "Give me 'mgmt' for Management cluster or 'hc' for Hosted cluster to deploy into Hypershift CI Environment"
    exit 1
fi

if [[ ${1} == "mgmt" ]]; then
    # Using AWS CI Cluster for MGMT Cluster
    export KUBECONFIG=${BASE_PATH}/AWS/Kubeconfig
    REGION=${MGMT_REGION}
    CLUSTER_NAME=${MGMT_CLUSTER_NAME}
    NS=${MGMT_CLUSTER_NS}
    CLUSTER_DIR=${MGMT_CLUSTER_DIR}
elif [[ ${1} == "hc" ]]; then
    # Using MGMT Cluster to deploy HC Cluster
    export KUBECONFIG=${MGMT_KUBECONFIG}
    REGION=${HC_REGION}
    CLUSTER_NAME=${HC_CLUSTER_NAME}
    NS=${HC_CLUSTER_NS}
    CLUSTER_DIR=${HC_CLUSTER_DIR}
else
    echo "Deployment cluster ${1} not implemented"
    exit 1
fi

echo "Deployment ${1} cluster in AWS Region: ${REGION}"

oc create ns ${NS} || true
${HYPERSHIFT_CLI} create cluster aws \
  --aws-creds ${AWS_CREDS} \
  --instance-type m6i.xlarge \
  --region ${REGION} \
  --auto-repair \
  --generate-ssh \
  --name ${CLUSTER_NAME} \
  --namespace ${NS} \
  --node-pool-replicas ${NODE_POOL_REPLICAS} \
  --pull-secret ${PULL_SECRET_FILE} \
  --base-domain ${BASE_DOMAIN} 

mkdir -p ${CLUSTER_DIR}
sleep 300

${HYPERSHIFT_CLI} create kubeconfig \
    --name ${CLUSTER_NAME} --namespace ${NS} > ${CLUSTER_DIR}/kubeconfig
echo "export KUBECONFIG=${CLUSTER_DIR}/kubeconfig"
