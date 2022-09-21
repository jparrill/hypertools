#!/bin/bash
set -xeu

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

# Using AWS CI Cluster for MGMT Cluster
export KUBECONFIG=${BASE_PATH}/AWS/Kubeconfig

${HYPERSHIFT_CLI} create cluster aws \
  --aws-creds ${AWS_CREDS} \
  --instance-type m6i.xlarge \
  --region $MGMT_REGION \
  --auto-repair \
  --generate-ssh \
  --name ${MGMT_CLUSTER_NAME} \
  --namespace ${MGMT_NS} \
  --node-pool-replicas ${NODE_POOL_REPLICAS} \
  --pull-secret ${PULL_SECRET_FILE} \
  --base-domain ${BASE_DOMAIN} 

mkdir -p ${MGMT_CLUSTER_DIR}
oc config use-context cluster-admin
sleep 300
${HYPERSHIFT_CLI} create kubeconfig \
    --name ${MGMT_CLUSTER_NAME} --namespace ${MGMT_NS} > ${MGMT_CLUSTER_DIR}/kubeconfig
echo "export KUBECONFIG=${MGMT_CLUSTER_DIR}/kubeconfig"
export KUBECONFIG=${MGMT_CLUSTER_DIR}/kubeconfig
