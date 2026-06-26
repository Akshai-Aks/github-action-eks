# 00 — Create the EKS Cluster & Prerequisites

This doc has two halves:

- **Part A — Create the cluster** with the provided `eksctl` config
  (`cluster/cluster.yaml`). Skip this if you already created `eks-acg`.
- **Part B — Local tools + sanity check** so every later step works.

---

# Part A — Create the EKS cluster with eksctl

> Already have `eks-acg`? Jump to [Part B](#part-b--local-tools--prerequisites)
> and just run the sanity check.

## A.1 Why an EKS cluster (and why eksctl)

**Amazon EKS** is the managed Kubernetes control plane: AWS runs the API server
and etcd across multiple AZs, patches them, and gives you an endpoint. You bring
the worker nodes. You need it because every other piece of this project (pods,
Services, the CloudWatch agent, IRSA) lives *inside* a Kubernetes cluster.

You *could* click through the EKS console to create a cluster, but it's a long
multi-screen flow (VPC, subnets, IAM roles, node groups) that's easy to get
subtly wrong. **eksctl** is the official CLI that reads one declarative YAML and
creates *everything* — VPC, subnets across 3 AZs, NAT gateways, IAM roles, the
control plane, and the managed node group — via a CloudFormation stack. That's
why this is the one piece we do with a CLI instead of the console: it's the
AWS-recommended, reproducible way, and it wires up parts the console leaves to
you.

## A.2 What it does — the config, field by field

The file `cluster/cluster.yaml` (identical to the config you were given):

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: eks-acg              # cluster name -> used everywhere (CLUSTER_NAME in CI)
  region: us-east-1          # all resources land here; must match ECR/Secrets/etc.
  version: "1.34"            # Kubernetes minor version of the control plane

vpc:
  cidr: 10.0.0.0/16          # private IP range for the new VPC (65,536 addresses)
  nat:
    gateway: HighlyAvailable # one NAT gateway PER AZ (3 total) for resilient egress

managedNodeGroups:
  - name: eks-node-group-managed-nodes
    instanceType: t3.medium  # 2 vCPU / 4 GiB per worker node
    desiredCapacity: 3       # start with 3 nodes
    privateNetworking: true  # nodes get NO public IP; live in private subnets

availabilityZones:
  - us-east-1a               # spread subnets/nodes across 3 AZs for HA
  - us-east-1b
  - us-east-1c
```

### What each field means and why this value

| Field | Meaning | Why this value |
|-------|---------|----------------|
| `metadata.name` | Cluster name | `eks-acg` — referenced by `CLUSTER_NAME` in the workflow, access entry, add-on, IRSA. Keep it consistent. |
| `metadata.region` | AWS region for everything | `us-east-1` — must match ECR, Secrets Manager, CloudWatch. Cross-region adds latency/cost. |
| `metadata.version` | Control-plane K8s version | `1.34` — recent; supports **access entries** (modern auth, see [docs/03](03-eks-access-entry.md)). |
| `vpc.cidr` | The new VPC's address space | `10.0.0.0/16` — large enough for many pods/nodes; avoid overlap if you ever peer VPCs. |
| `vpc.nat.gateway` | Egress for private subnets | `HighlyAvailable` = one NAT/AZ so a single-AZ outage doesn't cut node egress. Cheaper alt: `Single` (one NAT, one point of failure). **NAT gateways are a real hourly + per-GB cost.** |
| `managedNodeGroups[].name` | Node group name | descriptive; shows up in the EKS *Compute* tab. |
| `instanceType` | EC2 size per node | `t3.medium` (2 vCPU/4 GiB) — enough to run nginx + the CloudWatch agent + Fluent Bit DaemonSets. |
| `desiredCapacity` | Node count | `3` — one per AZ; gives HA and room for the DaemonSets. |
| `privateNetworking: true` | Node placement | Nodes in **private** subnets, no public IP → matches "no external exposure". Egress (to ECR/CloudWatch) goes via NAT. |
| `availabilityZones` | Which AZs to use | 3 AZs → subnets + nodes spread for resilience; Container Insights will show all 3. |

**Managed** node group (vs self-managed): AWS handles the node AMI, the IAM
instance role (auto-attaching `AmazonEKSWorkerNodePolicy`,
`AmazonEKS_CNI_Policy`, and crucially `AmazonEC2ContainerRegistryReadOnly` so
nodes can pull from ECR), and graceful draining on updates.

## A.3 Create it (one command)

From the repo root:

```bash
eksctl create cluster -f cluster/cluster.yaml
```

What happens (takes **~15–20 minutes** — it's building real infrastructure):

1. eksctl creates a CloudFormation stack for the **VPC** (3 public + 3 private
   subnets, internet gateway, 3 NAT gateways, route tables).
2. A second stack creates the **EKS control plane** (multi-AZ API server +
   etcd). This is the slow part (~10 min).
3. A third stack creates the **managed node group**: an Auto Scaling Group that
   launches 3 `t3.medium` nodes in the private subnets, which auto-register with
   the control plane.
4. eksctl writes/updates your local **kubeconfig** so `kubectl` immediately
   targets the new cluster.

You'll see progress lines ending in roughly:

```
[✔]  EKS cluster "eks-acg" in "us-east-1" region is ready
```

> The identity that runs this command becomes the cluster's implicit
> **admin** — remember which IAM user/role that is. The GitHub deploy role is a
> *different* identity and needs its own access entry ([docs/03](03-eks-access-entry.md)).

## A.4 What each option means in the EKS console (after creation)

Even though you used eksctl, it's worth seeing where these land in the console
(EKS → **eks-acg**):

| Console tab | Shows |
|-------------|-------|
| **Overview** | Status `Active`, Kubernetes version, the **OpenID Connect provider URL** (used by IRSA, [docs/04](04-irsa.md)). |
| **Compute** | The managed node group, its ASG, 3 nodes, instance type. |
| **Networking** | The VPC, subnets, and the API server endpoint access (public/private). |
| **Access** | Authentication mode + access entries (you'll add one in [docs/03](03-eks-access-entry.md)). |
| **Add-ons** | vpc-cni, coredns, kube-proxy (installed by eksctl) — you'll add CloudWatch here ([docs/06](06-cloudwatch-container-insights.md)). |

## A.5 Verify the cluster was created

```bash
eksctl get cluster --name eks-acg --region us-east-1
aws eks describe-cluster --name eks-acg --region us-east-1 --query 'cluster.status'
# -> "ACTIVE"
eksctl get nodegroup --cluster eks-acg --region us-east-1
```

(Then the `kubectl get nodes` check in Part B confirms the data plane.)

## A.6 Common mistakes & troubleshooting (creation)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Error: ... is not authorized to perform: cloudformation:CreateStack` (or `eks:`, `ec2:`) | Your IAM identity lacks rights to create the infra | Use an admin identity (or one with EKS/EC2/CFN/IAM create perms) to bootstrap. |
| Stuck ~20 min then `ResourceNotReady` | Transient AZ capacity / subnet issue | Re-run; eksctl is idempotent and resumes the CloudFormation stacks. |
| `InsufficientInstanceCapacity` for t3.medium | That AZ is out of that instance type | Remove one AZ, or change `instanceType`, and retry. |
| `AlreadyExistsException` | A prior failed run left stacks | `eksctl delete cluster --name eks-acg --region us-east-1`, then recreate. |
| Cluster created but `kubectl` can't connect | kubeconfig not updated / wrong identity | `aws eks update-kubeconfig --name eks-acg --region us-east-1` (see Part B). |

> **Cost reminder:** the moment the cluster is `ACTIVE` you're paying for the
> control plane (~$0.10/hr), 3× t3.medium, and 3 NAT gateways — even idle.
> Tear it down with [docs/09](09-cleanup.md) when you're done.

---

# Part B — Local tools & prerequisites

Before touching any AWS resource, make sure your machine and your `eks-acg`
cluster are in a known-good state.

## 0.1 Why this step

Every later step assumes you can (a) talk to AWS from your laptop and (b) reach
the Kubernetes API of the cluster. If either is broken, you'll waste time
blaming the wrong thing later. Five minutes here saves an hour later.

## 0.2 Local tools to install

| Tool | Why you need it | Install check |
|------|-----------------|---------------|
| **AWS CLI v2** | Talk to AWS APIs; `update-kubeconfig` | `aws --version` |
| **kubectl** | Talk to the Kubernetes API | `kubectl version --client` |
| **eksctl** | Manage cluster/IRSA/add-ons (optional but handy) | `eksctl version` |
| **helm** | Only if you install observability via Helm instead of the add-on | `helm version` |
| **Docker** | Local image builds/tests (CI builds for real) | `docker --version` |
| **git** | Push to GitHub to trigger CI | `git --version` |

Install pointers (macOS/Linux):

```bash
# AWS CLI v2 (Linux x86_64)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# kubectl (matches cluster 1.34 closely enough; client skew of ±1 is fine)
curl -LO "https://dl.k8s.io/release/v1.34.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# eksctl
curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
tar -xzf eksctl_Linux_amd64.tar.gz && sudo mv eksctl /usr/local/bin/
```

## 0.3 Configure AWS CLI

```bash
aws configure          # enter your access key, secret, region us-east-1, output json
aws sts get-caller-identity
```

Expected output (your numbers will differ):

```json
{
  "UserId": "AIDA...",
  "Account": "111122223333",
  "Arn": "arn:aws:iam::111122223333:user/you"
}
```

> Note the **Account** number — that is your `<AWS_ACCOUNT_ID>` everywhere in
> this guide.

## 0.4 Connect kubectl to the existing cluster

```bash
aws eks update-kubeconfig --name eks-acg --region us-east-1
kubectl get nodes -o wide
```

Expected: **3 nodes** in `Ready` state (your config set `desiredCapacity: 3`,
`t3.medium`, private networking).

```
NAME                          STATUS   ROLES    AGE   VERSION
ip-10-0-x-x.ec2.internal      Ready    <none>   1h    v1.34.x
ip-10-0-y-y.ec2.internal      Ready    <none>   1h    v1.34.x
ip-10-0-z-z.ec2.internal      Ready    <none>   1h    v1.34.x
```

## 0.5 What your eksctl config already gave you (and what it did NOT)

Your cluster config is worth understanding because it shapes later steps:

| Setting | What it created | Consequence for this project |
|---------|-----------------|------------------------------|
| `vpc.cidr 10.0.0.0/16` + `nat: HighlyAvailable` | A VPC with public + private subnets and **one NAT gateway per AZ** | Private nodes reach ECR/Secrets Manager/CloudWatch *through NAT* (works, but NAT costs money). |
| `managedNodeGroups ... privateNetworking: true` | Worker nodes in **private** subnets only | No node has a public IP. Good for security; means no external exposure by default — exactly what you want. |
| `version: "1.34"` | Control plane 1.34 | Use **EKS access entries** (modern) instead of editing `aws-auth`. |
| `availabilityZones a/b/c` | Subnets spread across 3 AZs | Container Insights will show 3 AZs of nodes. |

**Not created by your config** (you'll add these next):
- An **ECR** repo.
- The cluster's **IRSA OIDC provider** (eksctl only creates it if you ask; we
  verify/create it in [docs/04-irsa.md](04-irsa.md)).
- Any **CloudWatch** integration.
- Any IAM role for GitHub.

## 0.6 Verify

- [ ] `aws sts get-caller-identity` returns your account.
- [ ] `kubectl get nodes` shows 3 `Ready` nodes.
- [ ] `kubectl version` shows server `v1.34.x`.

## 0.7 Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `kubectl get nodes` → `Unauthorized` / `error: You must be logged in` | The IAM identity you ran `eksctl create cluster` with is the cluster admin; a *different* identity is now in your CLI | Use the same identity, or add an access entry for the new one (see [docs/03](03-eks-access-entry.md)). |
| `kubectl` hangs / `i/o timeout` | Cluster API endpoint is private-only and you're off-VPC | By default eksctl makes the endpoint public+private; confirm in EKS console → *Networking* → "API server endpoint access" = Public or Public and private. |
| `nodes NotReady` | Nodes can't reach the control plane or pull the CNI | Check the managed node group health in the EKS console → *Compute*. |
| `aws` says `Unable to locate credentials` | CLI not configured | `aws configure`. |

Next: **[01 — Amazon ECR](01-ecr.md)**.
