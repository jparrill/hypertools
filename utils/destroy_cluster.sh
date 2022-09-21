set -xeu

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

if [[ -z ${1} || ${1} == " " ]];then
    echo "Give me 'mgmt' for Management cluster or 'hc' for Hosted cluster to destroy into Hypershift CI Environment"
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

echo "are you sure you wanna delete the ${1}: ${CLUSTER_NAME} cluster in AWS Region ${REGION}?"
read

echo "Destroying ${1} cluster in AWS Region: ${REGION}"

${HYPERSHIFT_CLI} destroy cluster aws \
  --aws-creds ${AWS_CREDS} \
  --name ${CLUSTER_NAME} \
  --namespace ${NS}

rm -rf ${CLUSTER_DIR}
