#!/bin/bash

set -xeu

function restore_etcd {

    ETCD_PODS="etcd-0"
    if [ "${CONTROL_PLANE_AVAILABILITY_POLICY}" = "HighlyAvailable" ]; then
      ETCD_PODS="etcd-0 etcd-1 etcd-2"
    fi
    
    HC_RESTORE_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}-restore.yaml
    HC_BACKUP_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    cat > ${HC_RESTORE_FILE} <<EOF
        restoreSnapshotURL:
EOF
    
    for POD in ${ETCD_PODS}; do
      # Create a pre-signed URL for the etcd snapshot
      ETCD_SNAPSHOT="s3://${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
      ETCD_SNAPSHOT_URL=$(aws s3 presign ${ETCD_SNAPSHOT})
    
      # FIXME no CLI support for restoreSnapshotURL yet
      cat >> ${HC_RESTORE_FILE} <<EOF
        - "${ETCD_SNAPSHOT_URL}"
EOF
    done

    cat ${HC_RESTORE_FILE}
    
    if ! grep ${HC_CLUSTER_NAME}-snapshot.db ${HC_BACKUP_FILE}; then
      sed -i '' -e "/type: PersistentVolume/r ${HC_RESTORE_FILE}" ${HC_BACKUP_FILE}
      sed -i '' -e '/pausedUntil:/d' ${HC_BACKUP_FILE}
    fi
    
    HC=$(oc get hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME} -o name)
    if [[ -z ${HC} ]];then
        echo "Deploying HC Cluster: ${HC_CLUSTER_NAME} in ${HC_CLUSTER_NS} namespace"
        oc apply -f ${HC_BACKUP_FILE}
    else
        echo "HC Cluster ${HC_CLUSTER_NAME} already exists, avoiding step"

    fi
 
}

function restore_object {
    if [[ -z ${1} || ${1} == " " ]]; then
        echo "I need an argument to deploy K8s objects"
        exit 1
    fi

    case ${1} in
        "secret" | "hc")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid)' $f | oc apply -f -
            done
            ;;
        "np")
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid)' $f | oc apply -f -
            done
            ;;
        *)
            echo "K8s object not supported: ${1}"
            exit 1
            ;;
    esac

}

function regenerate_kubeconfig {
    while ! ${HYPERSHIFT_CLI} create kubeconfig | grep -q "name: clusters-${HC_CLUSTER_NAME}"; do
      echo "Waiting for cluster clusters-${HC_CLUSTER_NAME} to be ready"
      sleep 10
    done
    ${HYPERSHIFT_CLI} create kubeconfig > ${HC_CLUSTER_DIR}/kubeconfig-migrated

    echo "Hosted cluster ${HC_CLUSTER_NAME} created"
    echo "export KUBECONFIG=${HC_CLUSTER_DIR}/hosted-cluster-kubeconfig to access"
}

REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

# MGMT2 Context
MGMT2_REGION=us-west-1
MGMT2_CLUSTER_NAME="${USER}-dest"
MGMT2_CLUSTER_NS=${USER}
MGMT2_CLUSTER_DIR="${BASE_PATH}/hosted_clusters/${MGMT2_CLUSTER_NS}-${MGMT2_CLUSTER_NAME}"
MGMT2_KUBECONFIG="${MGMT2_CLUSTER_DIR}/kubeconfig"

if [[ ! -f ${MGMT2_KUBECONFIG} ]]; then
    echo "Destination Cluster Kubeconfig does not exists"
    echo "Dir: ${MGMT2_KUBECONFIG}"
    exit 1
fi

export KUBECONFIG=${MGMT2_KUBECONFIG}
BACKUP_DIR=${HC_CLUSTER_DIR}/backup
oc new-project ${HC_CLUSTER_NS} || oc project ${HC_CLUSTER_NS}
restore_object "secret"
restore_etcd
restore_object "np"
