#!/bin/bash

#set -xeu

function annotate_nodes() {
    MACHINES="$(oc get machines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name | wc -l)"
    if [[ ${MACHINES} -le 0 ]];then
        echo "There is not machines or machineSets in the Hosted ControlPlane namespace, exiting..."
        echo "HC Namespace: ${HC_CLUSTER_NS}"
        echo "HC Clusted Name: ${HC_CLUSTER_NAME}"
        exit 1
    fi 

    echo "Annotating Nodes to avoid Draining"
    oc annotate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} machines --all "machine.cluster.x-k8s.io/exclude-node-draining="
    echo "Nodes annotated!"
}

function scale_down_component() {

    # Validated that the nodes in AWS Scale down instantly, they take sometime to dissapear inside of Openshift
    # but the draining is avoided for sure
    echo "Scalling down the nodes for ${HC_CLUSTER_NAME} cluster"
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')
    oc scale nodepool/${NODEPOOLS} --namespace ${HC_CLUSTER_NS} --replicas=0
    echo "NodePool ${NODEPOOLS} scaled down!"
}


REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
echo "Hybernation proccess summoned"

if [[ $# -lt 3 ]];then
    echo "No arguments supplied"
    echo "We need at least the Kubeconfig, the hostedCluster Name and Namespace"
    echo "Sample: hybernate.sh <KUBECONFIG> <HC Namespace> <HC Name>"
    exit 1
fi

if [[ ! -f ${1} ]];then
    echo "Kubeconfig file does not exists"
    exit 1
fi

export KUBECONFIG="${1}"

CHECK_NS="$(oc get ns -o name ${2})"
if [[ -z "${CHECK_NS}" ]];then
    echo "Namespace does not exists in the Management Cluster"
    exit 1
fi

export HC_CLUSTER_NS=${2}

CHECK_HC="$(oc get hc -n ${HC_CLUSTER_NS} -o name ${3})"
if [[ -z "${CHECK_HC}" ]];then
    echo "HC ${3} does not exists in the namespace ${2} of the Management Cluster"
    exit 1
fi

export HC_CLUSTER_NAME=${3}

echo
echo "========="
echo "Kubeconfig: ${KUBECONFIG}"
echo "Cluster To Hibernate: ${HC_CLUSTER_NAME}"
echo "Namespace: ${HC_CLUSTER_NS}"
echo "========="
echo

annotate_nodes
scale_down_component
