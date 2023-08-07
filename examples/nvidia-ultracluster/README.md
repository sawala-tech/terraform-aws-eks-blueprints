# EKS NVIDIA GPU Ultracluster

This example demonstrates an architecture that is similar to that of an [UltraCluster](https://pages.awscloud.com/amazon-ec2-p4d.html) on Amazon EKS. Some of the core components of this example are:
- p4d.24xlarge and p5.48xlarge instances which are powered by NVIDIA A100 and H100 GPUs (respectively)
- EFA-enabled instances with all available EFA interfaces enabled for high throughput, low latency networking
- NVIDIA FabricManager and NCCL installed alongside MPI hwloc for GPU-aware, CPU bypass networking

The `p4d.24xlarge` instance has eight NVIDIA A100 GPUs, and 400 Gbps GPUDirectRDMA over EFA networking

The `p5.48xlarge` instance has eight NVIDIA H100 GPUs, and 3,200 Gbps GPUDirectRDMA over EFAv2 networking

## Prerequisites:

Ensure that you have the following tools installed locally:

1. [aws cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html)
2. [kubectl](https://Kubernetes.io/docs/tasks/tools/)
3. [terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli)

Before you begin, you will need to locate an availability zone that meets your instance selection requirements. This example utilizes placement groups to cluster instances in a single availability zone to reduce network latency. To find an availability zone that supports the instance types you wish to use, run the following command, replacing the region with your region of choice:

```sh
aws ec2 describe-instance-type-offerings --location-type availability-zone  \
      --filters Name=instance-type,Values=p4d.24xlarge,p5.48xlarge \
      --region <REGION> --output table
```

## Deploy

To provision this example:

```sh
terraform init
terraform apply
```

Enter `yes` at command prompt to apply

## Validate

1. Run `update-kubeconfig` command, using the Terraform provided Output, replace with your `$AWS_REGION` and your `$CLUSTER_NAME` variables.

```sh
aws eks --region <$AWS_REGION> update-kubeconfig --name <$CLUSTER_NAME>
```

2. Test by listing Nodes in in the Cluster, you should see Fargate instances as your Cluster Nodes.

```sh
kubectl get nodes
```

Your nodes and node types will be listed:

```text
# kubectl get nodes
NAME                           STATUS   ROLES    AGE    VERSION
ip-10-11-10-103.ec2.internal   Ready    <none>   4m1s   v1.25.7-eks-a59e1f0
ip-10-11-19-28.ec2.internal    Ready    <none>   11m    v1.25.7-eks-a59e1f0
ip-10-11-2-151.ec2.internal    Ready    <none>   11m    v1.25.7-eks-a59e1f0
ip-10-11-2-18.ec2.internal     Ready    <none>   5m1s   v1.25.7-eks-a59e1f0
```

3. Deploy Kubeflow MPI Operator

Kubeflow MPI Operator is required for running MPIJobs on EKS. We will use an MPIJob to test EFA.
To deploy the MPI operator execute the following:

```sh
kubectl apply -f https://raw.githubusercontent.com/kubeflow/mpi-operator/v0.4.0/deploy/v2beta1/mpi-operator.yaml
```

Output:

```text
namespace/mpi-operator created
customresourcedefinition.apiextensions.k8s.io/mpijobs.kubeflow.org created
serviceaccount/mpi-operator created
clusterrole.rbac.authorization.k8s.io/kubeflow-mpijobs-admin created
clusterrole.rbac.authorization.k8s.io/kubeflow-mpijobs-edit created
clusterrole.rbac.authorization.k8s.io/kubeflow-mpijobs-view created
clusterrole.rbac.authorization.k8s.io/mpi-operator created
clusterrolebinding.rbac.authorization.k8s.io/mpi-operator created
deployment.apps/mpi-operator created
```

In addition to deploying the operator, please apply a patch to the mpi-operator clusterrole
to allow the mpi-operator service account access to `leases` resources in the `coordination.k8s.io` apiGroup.

```sh
kubectl apply -f clusterrole-mpi-operator.yaml
```

Output:

```text
clusterrole.rbac.authorization.k8s.io/mpi-operator configured
```

4. Test EFA

We will run two tests. The first one will show the presence of EFA adapters on our EFA-enabled nodes. The second will test EFA performance.

5. EFA Info Test

To run the EFA info test, execute the following commands:

```sh
kubectl apply -f efa-test.yaml
```

Output:

```text
mpijob.kubeflow.org/efa-info-test created
```

```sh
kubectl get pods
```

Output:

```text
NAME                           READY   STATUS      RESTARTS   AGE
efa-info-test-launcher-hckkj   0/1     Completed   2          37s
efa-info-test-worker-0         1/1     Running     0          38s
efa-info-test-worker-1         1/1     Running     0          38s
```

Once the test launcher pod enters status `Running` or `Completed`, see the test logs using the command below:

```sh
kubectl logs -f $(kubectl get pods | grep launcher | cut -d ' ' -f 1)
```

Output:

```text
Warning: Permanently added 'efa-info-test-worker-1.efa-info-test-worker.default.svc,10.11.13.224' (ECDSA) to the list of known hosts.
Warning: Permanently added 'efa-info-test-worker-0.efa-info-test-worker.default.svc,10.11.4.63' (ECDSA) to the list of known hosts.
[1,1]<stdout>:provider: efa
[1,1]<stdout>:    fabric: efa
[1,1]<stdout>:    domain: rdmap197s0-rdm
[1,1]<stdout>:    version: 116.10
[1,1]<stdout>:    type: FI_EP_RDM
[1,1]<stdout>:    protocol: FI_PROTO_EFA
[1,0]<stdout>:provider: efa
[1,0]<stdout>:    fabric: efa
[1,0]<stdout>:    domain: rdmap197s0-rdm
[1,0]<stdout>:    version: 116.10
[1,0]<stdout>:    type: FI_EP_RDM
[1,0]<stdout>:    protocol: FI_PROTO_EFA
```

This result shows that two EFA adapters are available (one for each worker pod).

Lastly, delete the test job:

```sh
kubectl delete mpijob efa-info-test
```

Output:

```text
mpijob.kubeflow.org "efa-info-test" deleted
```

6. EFA NCCL Test

To run the EFA NCCL test please execute the following kubectl command:

```sh
kubectl apply -f https://raw.githubusercontent.com/aws-samples/aws-do-eks/main/Container-Root/eks/deployment/efa-device-plugin/test-nccl-efa.yaml
```

Output:

```text
mpijob.kubeflow.org/test-nccl-efa created
```

Then display the pods in the current namespace:

```sh
kubectl get pods
```

Output:

```text
NAME                           READY   STATUS    RESTARTS      AGE
test-nccl-efa-launcher-tx47t   1/1     Running   2 (31s ago)   33s
test-nccl-efa-worker-0         1/1     Running   0             33s
test-nccl-efa-worker-1         1/1     Running   0             33s
```

Once the launcher pod enters `Running` or `Completed` state, execute the following to see the test logs:

```sh
kubectl logs -f $(kubectl get pods | grep launcher | cut -d ' ' -f 1)
```

The following section from the beginning of the log, indicates that the test is being performed using EFA:

```text
[1,0]<stdout>:test-nccl-efa-worker-0:21:21 [0] NCCL INFO NET/OFI Selected Provider is efa (found 1 nics)
[1,0]<stdout>:test-nccl-efa-worker-0:21:21 [0] NCCL INFO Using network AWS Libfabric
[1,0]<stdout>:NCCL version 2.12.7+cuda11.4
```

Columns 8 and 12 in the output table show the in-place and out-of-place bus bandwidth calculated for the data size listed in column 1. In this case it is 3.13 and 3.12 GB/s respectively.
Your actual results may be slightly different. The calculated average bus bandwidth is displayed at the bottom of the log when the test finishes after it reaches the max data size,
specified in the mpijob manifest. In this result the average bus bandwidth is 1.15 GB/s.

```
[1,0]<stdout>:#       size         count      type   redop    root     time   algbw   busbw #wrong     time   algbw   busbw #wrong
[1,0]<stdout>:#        (B)    (elements)                               (us)  (GB/s)  (GB/s)            (us)  (GB/s)  (GB/s)
...
[1,0]<stdout>:      262144         65536     float     sum      -1    195.0    1.34    1.34      0    194.0    1.35    1.35      0
[1,0]<stdout>:      524288        131072     float     sum      -1    296.9    1.77    1.77      0    291.1    1.80    1.80      0
[1,0]<stdout>:     1048576        262144     float     sum      -1    583.4    1.80    1.80      0    579.6    1.81    1.81      0
[1,0]<stdout>:     2097152        524288     float     sum      -1    983.3    2.13    2.13      0    973.9    2.15    2.15      0
[1,0]<stdout>:     4194304       1048576     float     sum      -1   1745.4    2.40    2.40      0   1673.2    2.51    2.51      0
...
[1,0]<stdout>:# Avg bus bandwidth    : 1.15327
```

Finally, delete the test mpi job:

```sh
kubectl delete mpijob test-nccl-efa
```

Output:

```text
mpijob.kubeflow.org "test-nccl-efa" deleted
```

## Destroy

To teardown and remove the resources created in this example:

```sh
terraform destroy -target module.eks_blueprints_addons -auto-approve
terraform destroy -target module.eks -auto-approve
terraform destroy -auto-approve
```
