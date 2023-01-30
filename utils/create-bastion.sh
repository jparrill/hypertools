#!/bin/bash


function create_bastion() {

    if [[ -z "${1}" ]];then
        echo "Give me the AWS Region for HC"
        exit 1
    fi
    export ZONE_REGION=${1}
    export INFRA_ID=$(oc get hc -n ${CLUSTER_NS} ${CLUSTER_NAME} -o jsonpath={.spec.infraID})
    export SSH_KEY="${HOME}/.ssh/id_rsa.pub"

    if [[ ! -f ${SSH_KEY} ]];then
        echo "Please create the proper SSH Key located in ${HOME}/.ssh/id_rsa.pub"
        exit 1
    fi

    if [[ -z ${INFRA_ID} ]];then
        echo "Empty Infra ID for hosted cluster ${CLUSTER_NAME} in ${CLUSTER_NS} Namespace"

    fi

    
    ${HYPERSHIFT_CLI} create bastion aws --region ${ZONE_REGION} --aws-creds ${AWS_CREDS} --infra-id=${INFRA_ID} --ssh-key-file=${SSH_KEY}
    echo "This is your Bastion Node IP ^^^^^"
}

function create_kubeconfig() {
    echo "Creating Kubeconfig..."
    mkdir -p /tmp/${CLUSTER_NS}-${CLUSTER_NAME}
    ${HYPERSHIFT_CLI} create kubeconfig --name ${CLUSTER_NAME} --namespace ${CLUSTER_NS} > /tmp/${CLUSTER_NS}-${CLUSTER_NAME}/kubeconfig
    echo "your Kubeconfig it's in /tmp/${CLUSTER_NS}-${CLUSTER_NAME}/kubeconfig"
    echo "Please copy it into the Worker nodes when the whole process finishes"
}

function get_node_ip() {
    export NODES=$(aws ec2 describe-instances --region=${ZONE_REGION} --filter="Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" | jq '.Reservations[] | .Instances[] | select(.PublicDnsName=="") | .PrivateIpAddress')
    echo "Nodes IPs:"
    echo "${NODES}"
    echo
}

function finish() {
    echo
    echo "Your bastion is ready!"
    echo "Please use this command in order to access the nodes"
    echo "ssh -o ProxyCommand="ssh ec2-user@\$BASTION_IP -W %h:%p" core@\$NODE_IP"
    echo "The Bastion IP and Nodes IPs were prompted some seconds ago in the terminal"
}

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

if [[ -z ${1} ]];then
    echo "Please provide the Namespace which holds the HC"
    exit 1
fi

export CLUSTER_NS=${1}

if [[ -z ${2} ]];then
    echo "Please provide the HC Name"
    exit 1
fi

export CLUSTER_NAME=${2}

## Backup
echo "Creating Bastion Node"
create_bastion ${MGMT_REGION}
get_node_ip
create_kubeconfig
finish
echo "Bastion created!"

ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED

echo ""
