# Hypertools

Collection of scripts to provision a dev environment on Hypershift context

**NOTE**: All the executions will use the variables set in `common/common.sh`.

## Provision Management Environment

- Deploy Management Cluster Environment

```
make mgmt
```

## Build/Upload/Deploy Hypershift

- Build, Upload and Deploy Hypershift in Management cluster, you can customize the behaviour changing the image source to use in the deployment.

```
HYPERSHIFT_IMAGE=XXXXxxxXXXX make install
```

## Provision Hosted Cluster Environment

We usually use CI Environment to save resources

- Deploy HostedCluster environment

```
make hc
```

## Delete HostedCluster environment

- Destroy HC Cluster deployed on top of the Management one

```
make destroy-hc
```

## Delete Management Cluster Environment

- Destroy Management Cluster environment

```
make destroy-mgmt
```
