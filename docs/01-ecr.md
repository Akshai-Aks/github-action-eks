# 01 — Amazon ECR (Elastic Container Registry)

## 1. Why it is needed

EKS runs **container images**, it does not build them. Something must store the
image so the cluster can pull it. You *could* use Docker Hub, but:

- Docker Hub has anonymous pull **rate limits** that randomly break deploys.
- ECR is **private by default** and lives in the same account/region as EKS, so
  pulls are fast, free of egress charges, and authorized with the same IAM you
  already use.

ECR is the registry GitHub Actions pushes to and EKS pulls from.

## 2. What it does

ECR is a managed Docker/OCI registry. A **repository** holds all the tags of one
image (here: `nginx-app:latest`, `nginx-app:<gitsha>`). It handles storage,
encryption, optional vulnerability scanning, and lifecycle expiry of old images.

## 3. Create it in the AWS Management Console

1. Sign in to the console; set the region (top-right) to **N. Virginia
   (us-east-1)** — it **must** match your cluster's region.
2. Search for **ECR** → open **Elastic Container Registry**.
3. Left nav → **Repositories** → **Create repository**.
4. Fill the form (see option meanings below):
   - **Visibility settings:** `Private`
   - **Repository name:** `nginx-app`
   - **Tag immutability:** `Disabled` (we push a moving `latest` tag)
   - **Image scan settings → Scan on push:** `Enabled`
   - **Encryption settings:** `AES-256` (default)
5. Click **Create repository**.

## 4. What each option means

| Option | Meaning | Choice & why |
|--------|---------|--------------|
| **Visibility** | Private (IAM-gated) vs Public (anyone can pull) | **Private** — only your account/EKS should pull. |
| **Repository name** | The path segment in the image URI | `nginx-app` — must match `ECR_REPOSITORY` in the workflow. |
| **Tag immutability** | If *Enabled*, you can't overwrite an existing tag | **Disabled** for this demo (we reuse `latest`). In production, *Enable* it and deploy by git-SHA tag for reproducibility. |
| **Scan on push** | Runs a CVE scan on every pushed image | **Enabled** — free basic scanning, teaches you to read findings. |
| **Encryption** | At-rest encryption (AES-256 or AWS KMS) | **AES-256** — zero config. Use KMS if you need a customer-managed key + audit. |

The resulting **image URI** will be:

```
<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/nginx-app
```

## 5. Why these specific values

- **us-east-1** — same region as `eks-acg`; cross-region pulls add latency and
  data-transfer cost.
- **`nginx-app`** — referenced literally by `env.ECR_REPOSITORY` in
  `.github/workflows/deploy.yml` and by the image in `k8s/deployment.yaml`.
- **Scan on push** — surfaces base-image CVEs so you learn to read the
  *Image* → *Vulnerabilities* tab.

## 6. How to verify

**Console:** ECR → Repositories → you should see `nginx-app` with URI
`...dkr.ecr.us-east-1.amazonaws.com/nginx-app`. It will be **empty** until the
first pipeline run pushes an image.

**CLI:**

```bash
aws ecr describe-repositories --repository-names nginx-app --region us-east-1 \
  --query 'repositories[0].repositoryUri' --output text
# -> 111122223333.dkr.ecr.us-east-1.amazonaws.com/nginx-app
```

After your first pipeline run, list the pushed tags:

```bash
aws ecr list-images --repository-name nginx-app --region us-east-1
```

## 7. Optional but recommended: a lifecycle policy

Untagged image layers pile up and cost money. Add a rule to expire them:

Console: open the repo → **Lifecycle Policy** → **Create rule**:
- **Rule priority:** `1`
- **Image status:** `Untagged`
- **Match criteria:** `Since image pushed`, **Count:** `7 days`
- **Action:** `Expire`

## 8. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| CI push fails: `denied: requested access to the resource is denied` | The deploy IAM role lacks ECR permissions, or you targeted the wrong account/region | Confirm region; confirm role policy includes `ecr:*` actions (see [docs/02](02-iam-oidc-github.md)). |
| `repository does not exist` | Repo name mismatch | Repo name must exactly equal `ECR_REPOSITORY` in the workflow. |
| Image pull fails on the pod: `ImagePullBackOff` / `no basic auth credentials` | Node role can't pull from ECR | Managed node groups attach `AmazonEC2ContainerRegistryReadOnly` automatically; verify the node IAM role still has it. |
| Scan shows CVEs | Base image is outdated | Bump `FROM nginx:1.27-alpine` to a newer patch and re-push. |

Next: **[02 — GitHub OIDC + IAM deploy role](02-iam-oidc-github.md)**.
