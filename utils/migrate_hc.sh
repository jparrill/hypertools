
#!/bin/bash

set -xeu

function stop_reconciliation {
    # Pause reconciliation of the HostedCluster
    PAUSED_UNTIL="true"
    oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
    oc patch -n ${HC_CLUSTER_NS} nodepools/${NODEPOOLS} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
    
    # Stop etcd-writer deployments
    oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 kube-apiserver openshift-apiserver openshift-oauth-apiserver
    
    # Scale down nodepools (FIXME unless reusing nodes)
    oc scale nodepool -n ${HC_CLUSTER_NS} --replicas=0 ${NODEPOOLS}
}

function backup_etcd {
    # ETCD Backup
    ETCD_PODS="etcd-0"
    if [ "${CONTROL_PLANE_AVAILABILITY_POLICY}" = "HighlyAvailable" ]; then
      ETCD_PODS="etcd-0 etcd-1 etcd-2"
    fi
    
    for POD in ${ETCD_PODS}; do
      # Create an etcd snapshot
      oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl --cacert /etc/etcd/tls/client/etcd-client-ca.crt --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key --endpoints=localhost:2379 snapshot save /var/lib/data/snapshot.db
      oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl -w table snapshot status /var/lib/data/snapshot.db
    
      FILEPATH="/${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
      CONTENT_TYPE="application/x-compressed-tar"
      DATE_VALUE=`date -R`
      SIGNATURE_STRING="PUT\n\n${CONTENT_TYPE}\n${DATE_VALUE}\n${FILEPATH}"
    
      set +x
      ACCESS_KEY=$(grep aws_access_key_id ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
      SECRET_KEY=$(grep aws_secret_access_key ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
      SIGNATURE_HASH=`echo -en ${SIGNATURE_STRING} | openssl sha1 -hmac ${SECRET_KEY} -binary | base64`
      set -x
    
      # FIXME: this is pushing to the OIDC bucket
      oc exec -it etcd-0 -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- curl -X PUT -T "/var/lib/data/snapshot.db" \
        -H "Host: ${BUCKET_NAME}.s3.amazonaws.com" \
        -H "Date: ${DATE_VALUE}" \
        -H "Content-Type: ${CONTENT_TYPE}" \
        -H "Authorization: AWS ${ACCESS_KEY}:${SIGNATURE_HASH}" \
        https://${BUCKET_NAME}.s3.amazonaws.com/${HC_CLUSTER_NAME}-${POD}-snapshot.db
    done
    
}

function render_hc_objects {
    # Backup resources
    rm -fr ${BACKUP_DIR}
    mkdir -p ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}
    chmod 700 ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}

    # HostedCluster
    oc get hc ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    sed -i '' -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # NodePool
    oc get np ${NODEPOOLS} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml
    sed -i '' -e '/^status:$/,$ d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml 
    
    # Secrets
    for s in $(oc get secret -n ${HC_CLUSTER_NS} | grep "^${HC_CLUSTER_NAME}" | awk '{print $1}'); do
      oc get secret -n ${HC_CLUSTER_NS} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done
}


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
    echo "export KUBECONFIG=${HC_CLUSTER_DIR}/kubeconfig to access"
}

function backup_hc {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
    # Create a ConfigMap on the guest so we can tell which management cluster it came from
    export KUBECONFIG=${HC_KUBECONFIG}
    oc create configmap ${USER}-dev-cluster -n default --from-literal=from=${MGMT_CLUSTER_NAME} || true
    
    # Change kubeconfig to management cluster
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    oc annotate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} machines --all "machine.cluster.x-k8s.io/exclude-node-draining="
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS}  -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')
    
    stop_reconciliation
    backup_etcd
    render_hc_objects
}

function restore_hc {
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
}



REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

backup_hc
restore_hc
