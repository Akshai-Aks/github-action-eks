# 00 — Prerequisites & Cluster Sanity Check

Before touching any AWS resource, make sure your machine and your existing
`eks-acg` cluster are in a known-good state.

## 0.1 Why this step

Every later step assumes you can (a) talk to AWS from your laptop and (b) reach
the Kubernetes API of the cluster you already built with `eksctl`. If either is
broken, you'll waste time blaming the wrong thing later. Five minutes here saves
an hour later.

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
