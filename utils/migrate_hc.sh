#!/bin/bash

set -xeu

function change_reconciliation {

    if [[ -z "${1}" ]];then
        echo "Give me the status <start|stop>"
        exit 1
    fi

    case ${1} in
        "stop")
            # Pause reconciliation of HC and NP and ETCD writers
            PAUSED_UNTIL="true"
            oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc patch -n ${HC_CLUSTER_NS} nodepools/${NODEPOOLS} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
            ;;
        "start")
            # Restart reconciliation of HC and NP and ETCD writers
            PAUSED_UNTIL="false"
            oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc patch -n ${HC_CLUSTER_NS} nodepools/${NODEPOOLS} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
            oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=1 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
            ;;
        *)
            echo "Status not implemented"
            exit 1
            ;;
    esac

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
      SIGNATURE_HASH=$(echo -en ${SIGNATURE_STRING} | openssl sha1 -hmac "${SECRET_KEY}" -binary | base64)
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
    mkdir -p ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS} ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    chmod 700 ${BACKUP_DIR}/namespaces/ 

    # HostedCluster
    oc get hc ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    sed -i '' -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # NodePool
    oc get np ${NODEPOOLS} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml
    sed -i '' -e '/^status:$/,$ d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml 
    
    # Secrets in the HC Namespace
    for s in $(oc get secret -n ${HC_CLUSTER_NS} | grep "^${HC_CLUSTER_NAME}" | awk '{print $1}'); do
      oc get secret -n ${HC_CLUSTER_NS} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done

    # Secrets in the HC Control Plane Namespace
    for s in $(oc get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} | egrep -v "docker|service-account-token|oauth-openshift|NAME|token-${HC_CLUSTER_NAME}" | awk '{print $1}'); do
      oc get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/secret-${s}.yaml
    done
}


function restore_etcd {

    ETCD_PODS="etcd-0"
    if [ "${CONTROL_PLANE_AVAILABILITY_POLICY}" = "HighlyAvailable" ]; then
      ETCD_PODS="etcd-0 etcd-1 etcd-2"
    fi
    
    HC_RESTORE_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}-restore.yaml
    HC_BACKUP_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    HC_NEW_FILE=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}-new.yaml
    cat ${HC_BACKUP_FILE} > ${HC_NEW_FILE}
    cat > ${HC_RESTORE_FILE} <<EOF
        restoreSnapshotURL:
EOF
    
    for POD in ${ETCD_PODS}; do
      # Create a pre-signed URL for the etcd snapshot
      ETCD_SNAPSHOT="s3://${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
      ETCD_SNAPSHOT_URL=$(AWS_DEFAULT_REGION=${MGMT2_REGION} aws s3 presign ${ETCD_SNAPSHOT})
    
      # FIXME no CLI support for restoreSnapshotURL yet
      cat >> ${HC_RESTORE_FILE} <<EOF
        - "${ETCD_SNAPSHOT_URL}"
EOF
    done

    cat ${HC_RESTORE_FILE}
    
    if ! grep ${HC_CLUSTER_NAME}-snapshot.db ${HC_NEW_FILE}; then
      sed -i '' -e "/type: PersistentVolume/r ${HC_RESTORE_FILE}" ${HC_NEW_FILE}
      sed -i '' -e '/pausedUntil:/d' ${HC_NEW_FILE}
    fi
    
    HC=$(oc get hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME} -o name || true)
    if [[ ${HC} == "" ]];then
        echo "Deploying HC Cluster: ${HC_CLUSTER_NAME} in ${HC_CLUSTER_NS} namespace"
        oc apply -f ${HC_NEW_FILE}
    else
        echo "HC Cluster ${HC_CLUSTER_NAME} already exists, avoiding step"
    fi
 
}

function restore_object {
    if [[ -z ${1} || ${1} == " " ]]; then
        echo "I need an argument to deploy K8s objects"
        exit 1
    fi

    if [[ -z ${2} || ${2} == " " ]]; then
        echo "I need a Namespace to deploy the K8s objects"
        exit 1
    fi

    if [[ ! -d ${BACKUP_DIR}/namespaces/${2} ]];then
        echo "folder: ${BACKUP_DIR}/namespaces/${2} does not exists"
        exit 1
    fi

    case ${1} in
        "secret" | "hc")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid)' $f | oc apply -f -
            done
            ;;
        "np")
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid)' $f | oc apply -f -
            done
            ;;
        *)
            echo "K8s object not supported: ${1}"
            exit 1
            ;;
    esac

}

function render_migrated_kubeconfig {
    sleep 30
    #oc wait --for=condition=ready pod -l app=kube-apiserver -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --timeout=300s
    ${HYPERSHIFT_CLI} create kubeconfig > ${HC_CLUSTER_DIR}/kubeconfig_new

    echo "Hosted cluster ${HC_CLUSTER_NAME} migrated to ${MGMT2_CLUSTER_NAME} Cluster"
    echo "export KUBECONFIG=${HC_CLUSTER_DIR}/kubeconfig_new to access"
}

function backup_hc {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup
    # Create a ConfigMap on the guest so we can tell which management cluster it came from
    export KUBECONFIG=${HC_KUBECONFIG}
    oc create configmap ${USER}-dev-cluster -n default --from-literal=from=${MGMT_CLUSTER_NAME} || true
    
    # Change kubeconfig to management cluster
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    #oc annotate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} machines --all "machine.cluster.x-k8s.io/exclude-node-draining="
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')
    
    change_reconciliation "stop"
    backup_etcd
    # This allows us to remove the ownership in the AWS for the API route
    oc delete route -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all
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
    oc delete ns ${HC_CLUSTER_NS} || true
    oc new-project ${HC_CLUSTER_NS} || oc project ${HC_CLUSTER_NS}
    restore_object "secret" ${HC_CLUSTER_NS}
    oc new-project ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} || oc project ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "secret" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_etcd
    restore_object "np" ${HC_CLUSTER_NS}
    render_migrated_kubeconfig
}

function teardown_old_hc {
    export KUBECONFIG=${MGMT_KUBECONFIG}

    oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=1 kube-apiserver openshift-apiserver openshift-oauth-apiserver control-plane-operator
    oc delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}
}


REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

backup_hc
echo "Backup Done!"
echo "Press enter to continue the migration"
read
restore_hc
echo "Restoration Done!"
#teardown_old_hc
#echo "Teardown Done!"
