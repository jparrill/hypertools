HYPERSHIFT_IMAGE ?= "quay.io/jparrill/hypershift:latest"
BUILD ?= false

.PHONY: mgmt hc install
.EXPORT_ALL_VARIABLES:

mgmt:
	./utils/provision_cluster.sh 'mgmt'

hc:
	./utils/provision_cluster.sh 'hc'

install:
	BUILD=$(BUILD) HYPERSHIFT_IMAGE=$(HYPERSHIFT_IMAGE) ./utils/hypershift_install.sh

destroy-hc:
	./utils/destroy_cluster.sh 'hc'

destroy-mgmt:
	./utils/destroy_cluster.sh 'mgmt'
