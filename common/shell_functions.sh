function test-hp() {
    #set -euo pipefail
    set -o monitor
    set +x

    export OCP_IMAGE_PREVIOUS=${OCP_IMAGE_PREVIOUS:-"quay.io/openshift-release-dev/ocp-release:4.12.0-ec.3-x86_64"}
    export OCP_IMAGE_LATEST=${OCP_IMAGE_LATEST:-"quay.io/openshift-release-dev/ocp-release:4.12.0-ec.3-x86_64"}

    if [[ ! -f "$(pwd)/Makefile" ]];then
        echo "Please place yourself in the right folder (E.G: /Users/jparrill/RedHat/RedHat_Engineering/hypershift/repos/jparrill-hypershift)"
        return 1
    fi

    make e2e
    CI_TESTS_RUN=${1:-TestMigration}

    bin/test-e2e \
      -test.v \
      -test.timeout=2h10m \
      -test.run=${CI_TESTS_RUN} \
      -test.parallel=20 \
      --e2e.aws-credentials-file=~/.aws/credentials \
      --e2e.aws-zones=us-west-1a,us-west-1b,us-west-1c \
      --e2e.node-pool-replicas=1 \
      --e2e.pull-secret-file=/Users/jparrill/RedHat/RedHat_Engineering/pull_secret.json \
      --e2e.base-domain=ci.hypershift.devcluster.openshift.com \
      --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
      --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
      --e2e.additional-tags="expirationDate=$(date "+%Y-%m-%dT%H:%M+%S:00")" \
      --e2e.aws-endpoint-access=PublicAndPrivate \
      --e2e.external-dns-domain= jparrill-hosted-public.aws.kerbeross.com | tee /tmp/test_out

    set +o monitor
    set +x
}
