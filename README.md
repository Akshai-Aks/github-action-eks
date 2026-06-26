# Deploy NGINX to Amazon EKS with GitHub Actions

A hands-on, **console-first** learning project. You will stand up a complete
CI/CD pipeline that builds a Docker image, pushes it to **Amazon ECR**, pulls
configuration from **AWS Secrets Manager**, deploys to **Amazon EKS** as
Kubernetes **Secrets + ConfigMaps**, uses **IRSA** for keyless pod identity,
and streams logs/metrics to **Amazon CloudWatch Container Insights**.

When you're done, the **default NGINX welcome page** runs inside the cluster.
There is **no Load Balancer, Ingress, or any external exposure** — access is
in-cluster only (you test via `kubectl port-forward`).

---

## What you are building

```
                        GitHub repo (main branch)
                                 │  push
                                 ▼
                       ┌───────────────────┐
                       │  GitHub Actions   │  keyless auth via OIDC
                       └─────────┬─────────┘
            assume IAM role      │
        (github-actions-eks-deploy)
                                 │
        ┌────────────────────────┼─────────────────────────────┐
        ▼                        ▼                              ▼
  1. docker build         2. get-secret-value           3. kubectl apply
     docker push  ──►  Amazon      from  AWS Secrets   ──►   Amazon EKS
                       ECR         Manager                   (eks-acg)
                                       │                          │
                                       └── becomes K8s ───────────┤
                                           Secret + ConfigMap     │
                                                                  ▼
                                                      ┌──────────────────────┐
                                                      │ namespace: nginx-app │
                                                      │  Deployment (2 pods) │
                                                      │  ServiceAccount IRSA │
                                                      │  Service (ClusterIP) │
                                                      └──────────┬───────────┘
                                                                 │ logs+metrics
                                                                 ▼
                                                  Amazon CloudWatch Container Insights
```

### AWS resources you will create (and why)

| # | Resource | Why it exists | Created in |
|---|----------|---------------|------------|
| 1 | **ECR repository** (`nginx-app`) | Private registry to store the image EKS pulls | [docs/01-ecr.md](docs/01-ecr.md) |
| 2 | **IAM OIDC identity provider** for GitHub | Lets GitHub Actions log in without static keys | [docs/02-iam-oidc-github.md](docs/02-iam-oidc-github.md) |
| 3 | **IAM role** `github-actions-eks-deploy` | The role GitHub assumes; grants ECR + EKS rights | [docs/02-iam-oidc-github.md](docs/02-iam-oidc-github.md) |
| 4 | **EKS access entry** for that role | Authorizes the role to run `kubectl` against the cluster | [docs/03-eks-access-entry.md](docs/03-eks-access-entry.md) |
| 5 | **EKS OIDC provider** + **IRSA role** `eks-nginx-app-irsa-role` | Gives the nginx pod its own AWS identity, key-free | [docs/04-irsa.md](docs/04-irsa.md) |
| 6 | **Secrets Manager** secrets (`eks/nginx-app/secret`, `.../config`) | Single source of truth for app config/credentials | [docs/05-secrets-manager.md](docs/05-secrets-manager.md) |
| 7 | **CloudWatch Observability** EKS add-on (+ its IRSA role) | Ships pod/node/cluster logs & metrics to CloudWatch | [docs/06-cloudwatch-container-insights.md](docs/06-cloudwatch-container-insights.md) |

---

## The order you should do things in

Each step links to a deep-dive doc that follows the same 7-part format you asked
for: **Why → What → Console steps → Option meanings → Why these values →
Verify → Troubleshooting.**

> **Phase A — AWS Console (point-and-click).** Build the cloud foundation.

1. **[Create the EKS cluster & prerequisites](docs/00-architecture.md)** — create
   `eks-acg` from the provided `eksctl` config (`cluster/cluster.yaml`) if you
   haven't already, install local tools, and run a sanity check.
2. **[Amazon ECR](docs/01-ecr.md)** — create the private image repository.
3. **[GitHub OIDC + IAM deploy role](docs/02-iam-oidc-github.md)** — keyless CI auth.
4. **[EKS access entry](docs/03-eks-access-entry.md)** — let the deploy role use `kubectl`.
5. **[IRSA](docs/04-irsa.md)** — pod-level AWS identity for the nginx ServiceAccount.
6. **[AWS Secrets Manager](docs/05-secrets-manager.md)** — store app config & secrets.
7. **[CloudWatch Container Insights](docs/06-cloudwatch-container-insights.md)** — observability add-on.

> **Phase B — Code & automation (CLI / kubectl / GitHub Actions).** Wire it together.

8. **[Pipeline & deploy](docs/07-pipeline-and-deploy.md)** — set GitHub secrets, push, watch it deploy.
9. **[Verify everything](docs/08-verify-and-troubleshoot.md)** — default page, Secret/ConfigMap, IRSA, CloudWatch.
10. **[Clean up](docs/09-cleanup.md)** — delete what costs money when you're done.

---

## Repository layout

```
github-action-eks/
├── Dockerfile                     # FROM nginx:1.27-alpine (default page preserved)
├── .dockerignore
├── cluster/
│   └── cluster.yaml               # eksctl ClusterConfig (creates eks-acg)
├── .github/workflows/deploy.yml   # build -> ECR -> secrets sync -> EKS deploy
├── k8s/
│   ├── namespace.yaml             # namespace: nginx-app
│   ├── serviceaccount.yaml        # IRSA-annotated ServiceAccount
│   ├── deployment.yaml            # consumes ConfigMap + Secret, keeps default page
│   └── service.yaml               # ClusterIP only (no external exposure)
├── README.md                      # you are here
└── docs/                          # the step-by-step learning guides
    ├── 00-architecture.md
    ├── 01-ecr.md
    ├── 02-iam-oidc-github.md
    ├── 03-eks-access-entry.md
    ├── 04-irsa.md
    ├── 05-secrets-manager.md
    ├── 06-cloudwatch-container-insights.md
    ├── 07-pipeline-and-deploy.md
    ├── 08-verify-and-troubleshoot.md
    └── 09-cleanup.md
```

## Naming conventions used throughout (change to taste)

| Thing | Value |
|-------|-------|
| Region | `us-east-1` |
| EKS cluster | `eks-acg` |
| Namespace | `nginx-app` |
| ECR repository | `nginx-app` |
| K8s ServiceAccount | `nginx-sa` |
| IRSA role | `eks-nginx-app-irsa-role` |
| GitHub deploy role | `github-actions-eks-deploy` |
| Secrets Manager (secret) | `eks/nginx-app/secret` |
| Secrets Manager (config) | `eks/nginx-app/config` |

Wherever you see `<AWS_ACCOUNT_ID>`, substitute your own 12-digit account ID
(top-right of the AWS console, or `aws sts get-caller-identity`).

> **Cost note:** EKS (~$0.10/hr control plane) + 3× t3.medium nodes + NAT
> gateways are the main charges and run whether or not you deploy anything.
> Follow [docs/09-cleanup.md](docs/09-cleanup.md) when finished.
