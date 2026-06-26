# 02 — GitHub OIDC Provider + IAM Deploy Role (keyless CI auth)

This is the single most important security step. Do it carefully.

## 1. Why it is needed

GitHub Actions must call AWS APIs (push to ECR, read Secrets Manager, talk to
EKS). The naive way is to paste an AWS **access key + secret** into GitHub
secrets. Those are long-lived; if leaked, an attacker has standing access.

The modern way is **OpenID Connect (OIDC) federation**: GitHub signs a
short-lived JSON Web Token describing *which repo/branch* is running, AWS
**trusts** GitHub as an identity provider, and exchanges that token for
**temporary** STS credentials. No secrets to leak, scoped to your exact repo.

You create two things:
- **(A)** an IAM **OIDC identity provider** that says "I trust tokens from
  `token.actions.githubusercontent.com`".
- **(B)** an IAM **role** that those tokens are allowed to assume, carrying the
  permissions the pipeline needs.

## 2. What it does

- The **identity provider** registers GitHub's OIDC issuer + its audience and
  thumbprint, so STS will accept GitHub-signed tokens.
- The **role's trust policy** narrows *who* can assume it down to one repo (and
  optionally one branch), using the token's `sub` claim.
- The **role's permission policy** grants ECR + EKS-describe + Secrets Manager
  read.

---

## 3A. Create the OIDC identity provider (Console)

1. Console → **IAM** → left nav **Identity providers** → **Add provider**.
2. **Provider type:** `OpenID Connect`.
3. **Provider URL:** `https://token.actions.githubusercontent.com`
   → click **Get thumbprint**.
4. **Audience:** `sts.amazonaws.com`
5. **Add provider**.

### What each option means

| Option | Meaning | Value |
|--------|---------|-------|
| Provider type | OIDC vs SAML | **OIDC** — GitHub speaks OIDC. |
| Provider URL | The OIDC *issuer* GitHub stamps into every token | `https://token.actions.githubusercontent.com` (exact). |
| Get thumbprint | Pins the TLS cert chain of the issuer | Click it; AWS now manages this automatically for GitHub. |
| Audience (`aud`) | Who the token is intended for | `sts.amazonaws.com` — required by `configure-aws-credentials`. |

> If an identity provider for `token.actions.githubusercontent.com` **already
> exists** in your account, do not create a second one — reuse it.

---

## 3B. Create the deploy role (Console)

1. IAM → **Roles** → **Create role**.
2. **Trusted entity type:** `Web identity`.
3. **Identity provider:** select `token.actions.githubusercontent.com`.
4. **Audience:** `sts.amazonaws.com`.
5. (Optional in wizard) **GitHub organization:** `Akshai-Aks`,
   **Repository:** `github-action-eks`, **Branch:** `main`.
6. **Next** → on the permissions page, skip for now (we attach a custom policy
   after) → **Next**.
7. **Role name:** `github-actions-eks-deploy` → **Create role**.

### Tighten the trust policy

Open the new role → **Trust relationships** → **Edit trust policy**, and make it
exactly this (replace the account id and, if different, the repo):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:Akshai-Aks/github-action-eks:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

**Why the `sub` condition matters:** without it, *any* GitHub repo in the world
could assume your role. The `StringLike` pins it to your repo's `main` branch.
Use `repo:Akshai-Aks/github-action-eks:*` if you want all branches/PRs.

### Attach permissions

Open the role → **Add permissions** → **Create inline policy** → JSON tab →
paste, then name it `github-actions-eks-deploy-policy`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EcrAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "EcrPushPull",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:CompleteLayerUpload",
        "ecr:InitiateLayerUpload",
        "ecr:PutImage",
        "ecr:UploadLayerPart",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "arn:aws:ecr:us-east-1:<AWS_ACCOUNT_ID>:repository/nginx-app"
    },
    {
      "Sid": "EksDescribe",
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "arn:aws:eks:us-east-1:<AWS_ACCOUNT_ID>:cluster/eks-acg"
    },
    {
      "Sid": "ReadAppSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:<AWS_ACCOUNT_ID>:secret:eks/nginx-app/*"
    }
  ]
}
```

### What each permission is for

| Sid | Why |
|-----|-----|
| `EcrAuth` | `docker login` to ECR needs a token; this action only works with `Resource: "*"`. |
| `EcrPushPull` | Push image layers + manifest to the `nginx-app` repo. |
| `EksDescribe` | `aws eks update-kubeconfig` calls `DescribeCluster` to learn the API endpoint + CA. **This does not grant `kubectl` access** — that comes from the access entry in [docs/03](03-eks-access-entry.md). |
| `ReadAppSecrets` | Pull the two Secrets Manager entries at deploy time. Scoped to the `eks/nginx-app/*` prefix only. |

## 4./5. Why these values

- **Least privilege:** every statement is scoped to a specific ARN, not `*`,
  except `GetAuthorizationToken` (which AWS requires to be `*`).
- We deliberately did **not** grant broad `eks:*` or admin — kubectl authz is
  handled by the EKS access entry, which is the correct, auditable place.

## 6. How to verify

Copy the **Role ARN** from the top of the role page — you'll paste it into
GitHub as `AWS_ROLE_ARN`:

```
arn:aws:iam::<AWS_ACCOUNT_ID>:role/github-actions-eks-deploy
```

CLI checks:

```bash
aws iam get-role --role-name github-actions-eks-deploy \
  --query 'Role.AssumeRolePolicyDocument'
aws iam list-open-id-connect-providers   # should list the github provider
```

The real proof comes in [docs/07](07-pipeline-and-deploy.md): the
*Configure AWS credentials* step in the workflow succeeds and the *Resolve AWS
account id* step prints your account.

## 7. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| CI: `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub`/`aud` doesn't match, or org/repo typo | Compare the `sub` string to your real `owner/repo` and branch. |
| CI: `Could not assume role ... no OpenIDConnect provider found` | The IAM OIDC provider doesn't exist (or wrong URL) | Re-create provider with the exact URL `token.actions.githubusercontent.com`. |
| CI: forgot `permissions: id-token: write` | GitHub won't mint the OIDC token | Already set in `deploy.yml`; don't remove it. |
| Push works but `update-kubeconfig` then `kubectl` is `Unauthorized` | That's expected — describe ≠ kubectl authz | Do [docs/03 access entry](03-eks-access-entry.md). |

Next: **[03 — EKS access entry](03-eks-access-entry.md)**.
