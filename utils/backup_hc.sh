#!/bin/bash

set -xeu

function stop_reconciliation {
    # Pause reconciliation of the HostedCluster
    PAUSED_UNTIL="true"
    oc patch -n ${HC_CLUSTER_NS} hostedclusters/${HC_CLUSTER_NAME} -p '{"spec":{"pausedUntil":"'${PAUSED_UNTIL}'"}}' --type=merge
    
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
    mkdir -p ${BACKUP_DIR}/namespaces
    chmod 700 ${BACKUP_DIR}/namespaces

    # HostedCluster
    oc get hc ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/hc-${HC_CLUSTER_NAME}.yaml
    
    # NodePool
    oc get np ${NODEPOOLS} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/np-${NODEPOOLS}.yaml
    
    # Secrets
    for s in $(oc get secret -n ${HC_CLUSTER_NS} | grep "^${HC_CLUSTER_NAME}" | awk '{print $1}'); do
      oc get secret -n ${HC_CLUSTER_NS} $s -o yaml > ${BACKUP_DIR}/namespaces/secret-${s}.yaml
    done
}


REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh
BACKUP_DIR=${HC_CLUSTER_DIR}/backup

# Create a ConfigMap on the guest so we can tell which management cluster it came from
export KUBECONFIG=${HC_KUBECONFIG}
oc create configmap ${USER}-dev-cluster -n default --from-literal=from=${MGMT_CLUSTER_NAME} || true

# Change kubeconfig to management cluster
export KUBECONFIG="${MGMT_KUBECONFIG}"
NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS}  -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')

stop_reconciliation
backup_etcd
render_hc_objects

