HYPERSHIFT_IMAGE ?= "quay.io/jparrill/hypershift:latest"

.PHONY: mgmt hc install

mgmt:
	./utils/provision_cluster.sh 'mgmt'

hc:
	./utils/provision_cluster.sh 'hc'

install:
	HYPERSHIFT_IMAGE=$(HYPERSHIFT_IMAGE) ./utils/hypershift_install.sh

destroy-hc:
	./utils/destroy_cluster.sh 'hc'

destroy-mgmt:
	./utils/destroy_cluster.sh 'mgmt'
