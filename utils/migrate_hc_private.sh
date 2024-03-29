#!/bin/bash

set -eu

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
      echo "oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl --cacert /etc/etcd/tls/client/etcd-client-ca.crt --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key --endpoints=localhost:2379 snapshot save /var/lib/data/snapshot.db"
      oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl --cacert /etc/etcd/tls/etcd-ca/ca.crt --cert /etc/etcd/tls/client/etcd-client.crt --key /etc/etcd/tls/client/etcd-client.key --endpoints=localhost:2379 snapshot save /var/lib/data/snapshot.db

      oc exec -it ${POD} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -- env ETCDCTL_API=3 /usr/bin/etcdctl -w table snapshot status /var/lib/data/snapshot.db

      FILEPATH="/${BUCKET_NAME}/${HC_CLUSTER_NAME}-${POD}-snapshot.db"
      CONTENT_TYPE="application/x-compressed-tar"
      DATE_VALUE=`date -R`
      SIGNATURE_STRING="PUT\n\n${CONTENT_TYPE}\n${DATE_VALUE}\n${FILEPATH}"

      set +x
      ACCESS_KEY=$(grep aws_access_key_id ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
      SECRET_KEY=$(grep aws_secret_access_key ${AWS_CREDS} | head -n1 | cut -d= -f2 | sed "s/ //g")
      SIGNATURE_HASH=$(echo -en ${SIGNATURE_STRING} | openssl sha1 -hmac "${SECRET_KEY}" -binary | base64)

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
    echo "Backing Up HostedCluster Objects:"
    oc get hc ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml
    echo "--> HostedCluster"
    sed -i '' -e '/^status:$/,$d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/hc-${HC_CLUSTER_NAME}.yaml

    # NodePool
    oc get np ${NODEPOOLS} -n ${HC_CLUSTER_NS} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml
    echo "--> NodePool"
    sed -i '' -e '/^status:$/,$ d' ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/np-${NODEPOOLS}.yaml

    # Secrets in the HC Namespace
    echo "--> HostedCluster Secrets"
    for s in $(oc get secret -n ${HC_CLUSTER_NS} | grep "^${HC_CLUSTER_NAME}" | awk '{print $1}'); do
        oc get secret -n ${HC_CLUSTER_NS} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}/secret-${s}.yaml
    done

    # Secrets in the HC Control Plane Namespace
    echo "--> HostedCluster ControlPlane Secrets"
    for s in $(oc get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} | egrep -v "docker|service-account-token|oauth-openshift|NAME|token-${HC_CLUSTER_NAME}" | awk '{print $1}'); do
        oc get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/secret-${s}.yaml
    done

    # Hosted Control Plane
    echo "--> HostedControlPlane"
    oc get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/hcp-${HC_CLUSTER_NAME}.yaml

    # Cluster
    echo "--> Cluster"
    CL_NAME=$(oc get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.metadata.labels.\*} | grep ${HC_CLUSTER_NAME})
    oc get cluster ${CL_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/cl-${HC_CLUSTER_NAME}.yaml

    # AWS Cluster
    echo "--> AWS Cluster"
    oc get awscluster ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awscl-${HC_CLUSTER_NAME}.yaml

    # AWS MachineTemplate
    echo "--> AWS Machine Template"
    oc get awsmachinetemplate ${NODEPOOLS} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awsmt-${HC_CLUSTER_NAME}.yaml

    # AWS Machines
    echo "--> AWS Machine"
    CL_NAME=$(oc get hcp ${HC_CLUSTER_NAME} -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.metadata.labels.\*} | grep ${HC_CLUSTER_NAME})
    for s in $(oc get awsmachines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --no-headers | grep ${CL_NAME} | cut -f1 -d\ ); do
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} awsmachines $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/awsm-${s}.yaml
    done

    # MachineDeployments
    echo "--> HostedCluster MachineDeployments"
    for s in $(oc get machinedeployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        mdp_name=$(echo ${s} | cut -f 2 -d /)
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machinedeployment-${mdp_name}.yaml
    done

    # MachineSets
    echo "--> HostedCluster MachineSets"
    for s in $(oc get machineset -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        ms_name=$(echo ${s} | cut -f 2 -d /)
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machineset-${ms_name}.yaml
    done

    # Machines
    echo "--> HostedCluster Machines"
    for s in $(oc get machine -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        m_name=$(echo ${s} | cut -f 2 -d /)
        oc get -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} $s -o yaml > ${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/machine-${m_name}.yaml
    done
    echo "--> Done"
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
        "secret" | "machine" | "machineset" | "hcp" | "cl" | "awscl" | "awsmt" | "awsm" | "machinedeployment")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status)' $f | oc apply -f -
            done
            ;;
        "hc" | "np")
            # Cleaning the YAML files before apply them
            for f in $(ls -1 ${BACKUP_DIR}/namespaces/${2}/${1}-*); do
                yq 'del(.metadata.ownerReferences,.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.status,.spec.pausedUntil)' $f | oc apply -f -
            done
            ;;
        *)
            echo "K8s object not supported: ${1}"
            exit 1
            ;;
    esac

}


function clean_private_zones() {

    # Constants
    if [[ -z "${1}" ]];then
        echo "Give me the Route53 domain"
        exit 1
    fi

    ZONE_DOMAIN=${1}
    ZONE_ID=$(aws route53 list-hosted-zones \
            --output text \
            --query 'HostedZones[?Name==`'${1}'.`].Id')
    
    echo 
    echo "Looking fot the zone..."
    echo "Zone Domain: ${ZONE_DOMAIN}"
    echo "Zone ID: ${ZONE_ID}"

    if [[ -z ${ZONE_ID} ]];then
        echo "The Zone does not exists"
    else
        echo "Zone found, deleting entries..."
        aws route53 list-resource-record-sets \
            --hosted-zone-id ${ZONE_ID} |
            jq -c '.ResourceRecordSets[]' |
            while read -r resourcerecordset; do
                read -r name type <<<$(echo $(jq -r '.Name,.Type' <<<"$resourcerecordset"))
                if [ $type != "NS" -a $type != "SOA" ]; then
                aws route53 change-resource-record-sets \
                    --hosted-zone-id ${ZONE_ID} \
                    --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":
                    '"$resourcerecordset"'
                    }]}' \
                    --output text# --query 'ChangeInfo.Id'
                fi
            done

        echo "Deleting zone..."
        echo "Zone Domain: ${ZONE_DOMAIN}"
        echo "Zone ID: ${ZONE_ID}"

        aws route53 delete-hosted-zone \
            --id ${ZONE_ID} \
            --output text 
    fi

}

function backup_hc {
    BACKUP_DIR=${HC_CLUSTER_DIR}/backup

    # Change kubeconfig to management cluster
    export KUBECONFIG="${MGMT_KUBECONFIG}"
    #oc annotate -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} machines --all "machine.cluster.x-k8s.io/exclude-node-draining="
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')

    change_reconciliation "stop"
    backup_etcd
    render_hc_objects
    #clean_private_zones "${HC_CLUSTER_NAME}.hypershift.local" 
    EXTERNAL_DNS_DOMAIN=$(oc get hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME} -o jsonpath={.spec.dns.baseDomain})
    #clean_private_zones "${HC_CLUSTER_NAME}.${EXTERNAL_DNS_DOMAIN}"
}

function restore_hc {
    # MGMT2 Context
    #MGMT2_REGION=us-east-1
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
    restore_object "hcp" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "cl" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "awscl" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "awsmt" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "awsm" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "machinedeployment" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "machine" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_object "machineset" ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}
    restore_etcd
    restore_object "np" ${HC_CLUSTER_NS}

    timeout=40
    count=0
    INFRA_ID=$(oc get hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME} -o jsonpath={.spec.infraID})
    NODE_STATUS=$(oc get machines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --kubeconfig=${MGMT2_KUBECONFIG} | grep "${INFRA_ID}") | grep -c Running || NODE_STATUS=0

    while [ ${NODE_POOL_REPLICAS} != ${NODE_STATUS} ]
    do
        echo "Waiting for Nodes to be Ready in the destination MGMT Cluster: ${MGMT2_CLUSTER_NAME}"
        echo "Try: (${count}/${timeout})"
        sleep 30
        if [[ $count -eq timeout ]];then
            echo "Timeout waiting for Nodes in the destination MGMT Cluster"
            exit 1
        fi
        count=$((count+1))
        NODE_STATUS=$(oc get machines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --kubeconfig=${MGMT2_KUBECONFIG} | grep "${INFRA_ID}") | grep -c Running || NODE_STATUS=0
    done


}

function teardown_old_hc {

    export KUBECONFIG=${MGMT_KUBECONFIG}

    # Scale down deployments
    oc scale deployment -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 --all
    oc scale statefulset.apps -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --replicas=0 --all
    sleep 15

    # Delete Finalizers
    NODEPOOLS=$(oc get nodepools -n ${HC_CLUSTER_NS} -o=jsonpath='{.items[?(@.spec.clusterName=="'${HC_CLUSTER_NAME}'")].metadata.name}')
    if [[ ! -z "${NODEPOOLS}" ]];then
        oc patch -n "${HC_CLUSTER_NS}" nodepool ${NODEPOOLS} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
        oc delete np -n ${HC_CLUSTER_NS} ${NODEPOOLS}
    fi

    # Machines
    for m in $(oc get machines -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name); do
        oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
        oc delete -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} || true
    done

    oc delete machineset -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all || true

    # Cluster
    C_NAME=$(oc get cluster -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name)
    oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${C_NAME} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
    oc delete cluster.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all

    # AWS Machines
    for m in $(oc get awsmachine.infrastructure.cluster.x-k8s.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o name)
    do
        oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]' || true
        oc delete -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} ${m} || true
    done

    # HCP
    oc patch -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} hostedcontrolplane.hypershift.openshift.io ${HC_CLUSTER_NAME} --type=json --patch='[ { "op":"remove", "path": "/metadata/finalizers" }]'
    oc delete hostedcontrolplane.hypershift.openshift.io -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} --all

    oc delete ns ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} || true

    oc -n ${HC_CLUSTER_NS} patch hostedclusters ${HC_CLUSTER_NAME} -p '{"metadata":{"finalizers":null}}' --type merge || true
    oc delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}  --wait=false || true
    oc -n ${HC_CLUSTER_NS} patch hostedclusters ${HC_CLUSTER_NAME} -p '{"metadata":{"finalizers":null}}' --type merge || true
    oc delete hc -n ${HC_CLUSTER_NS} ${HC_CLUSTER_NAME}  || true

    oc delete ns ${HC_CLUSTER_NS} || true
}

function restore_ovn_pods() {
    LOCALHOST_KUBECONFIG=${BACKUP_DIR}/namespaces/${HC_CLUSTER_NS}-${HC_CLUSTER_NAME}/localhost-kubeconfig
    echo "Grabbing Localhost Kubeconfig"
    oc get secret -n ${HC_CLUSTER_NS}-${HC_CLUSTER_NAME} -o jsonpath={.data.kubeconfig} | base64 -d > ${LOCALHOST_KUBECONFIG}

    echo "Raising Up Port-Forwarding"
    oc port-forward svc/kube-apiserver 6443:6443 &

    echo "Deleting OVN Pods in Guest Cluster to reconnect with new OVN Master"
    oc --kubeconfig=${LOCALHOST_KUBECONFIG} delete pod -n openshift-ovn-kubernetes --all
}


REPODIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/.."
source $REPODIR/common/common.sh

## Backup
echo "Creating HC Backup"
SECONDS=0
#backup_hc
echo "Backup Done!"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED
echo "Press enter to continue the migration"
read

## Migration
SECONDS=0
echo "Executing the HC Migration"
#restore_hc
echo "Restoration Done!"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED

## Teardown
SECONDS=0
echo "Tearing down the HC in Source Management Cluster"
teardown_old_hc
#restore_ovn_pods
echo "Teardown Done"
ELAPSED="Elapsed: $(($SECONDS / 3600))hrs $((($SECONDS / 60) % 60))min $(($SECONDS % 60))sec"
echo $ELAPSED
