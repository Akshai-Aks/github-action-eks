# 03 — EKS Access Entry (let the deploy role run kubectl)

## 1. Why it is needed

There are **two independent permission systems** in front of an EKS cluster:

1. **AWS IAM** — can you call the EKS *AWS* API (`DescribeCluster`, etc.)? The
   deploy role already can ([docs/02](02-iam-oidc-github.md)).
2. **Kubernetes authorization (RBAC)** — once you're *inside* the API server,
   can you `get pods` / `apply deployment`? IAM alone does **not** grant this.

A brand-new IAM principal that runs `kubectl` gets `Unauthorized` until you map
it into Kubernetes. On EKS 1.34 the modern, console-friendly way to do that is
an **Access Entry** (the old way was hand-editing the `aws-auth` ConfigMap —
error-prone; avoid it).

## 2. What it does

An access entry maps an IAM principal ARN to Kubernetes permissions. You either:
- attach an **access policy** (AWS-managed bundles like
  `AmazonEKSClusterAdminPolicy` or `AmazonEKSEditPolicy`), and/or
- map the principal into Kubernetes **groups** for your own RBAC.

For a learning project, `AmazonEKSEditPolicy` (read/write to most namespaced
objects, no cluster-admin) is a good least-privilege fit; `ClusterAdmin` is
simplest if you get stuck.

> **Prerequisite — authentication mode.** The cluster's authentication mode must
> include access entries. eksctl 0.190+ defaults new clusters to
> `API_AND_CONFIG_MAP`, which supports them. Verify in step 3; if it still says
> `CONFIG_MAP`, switch it (one click) before adding the entry.

## 3. Create it in the Console

1. Console → **EKS** → **Clusters** → **eks-acg**.
2. **Access** tab. Check **Cluster authentication mode**. If it is
   `EKS API and ConfigMap` or `EKS API`, you're good. If it is `ConfigMap`,
   click **Manage access** → set to **EKS API and ConfigMap** → **Save**.
3. Still on the **Access** tab → **Create access entry**.
4. **IAM principal ARN:** select/paste
   `arn:aws:iam::<AWS_ACCOUNT_ID>:role/github-actions-eks-deploy`.
5. **Type:** `Standard`.
6. (Leave Kubernetes groups empty — we'll use an access policy instead.)
   **Next**.
7. **Add policy** → choose **`AmazonEKSEditPolicy`** (or
   `AmazonEKSClusterAdminPolicy` to be safe) → **Access scope:** `Cluster` →
   **Add policy** → **Next** → **Create**.

### What each option means

| Option | Meaning | Choice |
|--------|---------|--------|
| **IAM principal ARN** | Which AWS identity this entry maps | the GitHub deploy role ARN. |
| **Type** | `Standard` (IAM user/role) vs `EC2`/`FARGATE` (node bootstrap) | **Standard**. |
| **Kubernetes groups** | Maps principal into RBAC groups you define | leave empty when using a managed access policy. |
| **Access policy** | AWS-managed permission bundle | `AmazonEKSEditPolicy` = create/update workloads, not cluster-admin. |
| **Access scope** | `Cluster`-wide or limited to chosen namespaces | `Cluster` (the workflow creates the `nginx-app` namespace itself). |

## 4./5. Why these values

- **Standard** type because the principal is an IAM role, not a node.
- **`AmazonEKSEditPolicy`** because the pipeline needs to create namespaces,
  deployments, services, configmaps, and secrets — all namespaced, write-level
  operations — but never needs to modify cluster-scoped RBAC. Least privilege.
- **Cluster** scope so the workflow can create the `nginx-app` namespace on
  first run (a namespace is cluster-scoped).

## 6. How to verify

Console: **Access** tab → the entry for `github-actions-eks-deploy` appears
with the attached policy.

CLI (simulating what CI does):

```bash
aws eks list-access-entries --cluster-name eks-acg --region us-east-1
aws eks list-associated-access-policies \
  --cluster-name eks-acg \
  --principal-arn arn:aws:iam::<AWS_ACCOUNT_ID>:role/github-actions-eks-deploy \
  --region us-east-1
```

End-to-end proof: the *Wait for rollout* step in the pipeline runs `kubectl get`
without `Unauthorized`.

## 7. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `error: You must be logged in to the server (Unauthorized)` in CI | No access entry, or wrong principal ARN (e.g. you mapped the *session* ARN instead of the role ARN) | Map the **role** ARN exactly: `.../role/github-actions-eks-deploy`. STS sessions inherit the role's entry automatically. |
| "Create access entry" button greyed out | Auth mode is `ConfigMap`-only | Switch to `EKS API and ConfigMap` first. |
| Can `get` but not `apply` | Used a read-only policy (`AmazonEKSViewPolicy`) | Use `AmazonEKSEditPolicy` or `AmazonEKSClusterAdminPolicy`. |
| Works for you locally but not CI | Your laptop identity is the cluster creator (implicit admin); CI uses the role | The creator is auto-admin; the role still needs its own entry. |

Next: **[04 — IRSA](04-irsa.md)**.
