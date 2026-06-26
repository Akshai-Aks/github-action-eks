# 07 — Pipeline & Deploy (Phase B: CLI / kubectl / GitHub Actions)

By now (Phase A) you have, **in the console**: an ECR repo, the GitHub OIDC
provider + deploy role, an EKS access entry, the IRSA OIDC provider + role, two
Secrets Manager secrets, and the CloudWatch Observability add-on. Now wire the
automation.

## 1. Configure the GitHub repository

### 1.1 Add the one required secret

GitHub repo → **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**:

| Name | Value |
|------|-------|
| `AWS_ROLE_ARN` | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/github-actions-eks-deploy` |

That's the only secret needed — everything else is non-sensitive config in the
workflow's `env:` block. (No AWS access keys, thanks to OIDC.)

### 1.2 Confirm the non-secret config in `deploy.yml`

Open `.github/workflows/deploy.yml` and sanity-check the `env:` values match
what you created:

```yaml
AWS_REGION: us-east-1
CLUSTER_NAME: eks-acg
ECR_REPOSITORY: nginx-app
K8S_NAMESPACE: nginx-app
SM_SECRET_NAME: eks/nginx-app/secret
SM_CONFIG_NAME: eks/nginx-app/config
```

## 2. What the pipeline does (step by step)

| Step | Action | Depends on |
|------|--------|-----------|
| Checkout | Pull repo source | — |
| Configure AWS credentials (OIDC) | Assume `github-actions-eks-deploy` via the OIDC token | [docs/02](02-iam-oidc-github.md) |
| Resolve AWS account id | `sts get-caller-identity` → used to build image URI | — |
| Login to Amazon ECR | `docker login` to your registry | [docs/01](01-ecr.md) |
| Build and push image | `docker build` → push `:<sha>` and `:latest` | ECR repo exists |
| Update kubeconfig | Point `kubectl` at `eks-acg` | EksDescribe perm |
| Fetch values from Secrets Manager | Download both JSON secrets, **mask** values in logs | [docs/05](05-secrets-manager.md) |
| Create namespace, ConfigMap and Secret | `jq` → `--from-literal` → idempotent apply | access entry |
| Deploy to EKS | Substitute account id + image, `kubectl apply` SA/Deployment/Service | [docs/03](03-eks-access-entry.md), [docs/04](04-irsa.md) |
| Wait for rollout & show status | `kubectl rollout status` + `get` | — |

## 3. Trigger the pipeline

```bash
# from the repo root
git add .
git commit -m "Add EKS CI/CD pipeline, manifests, and docs"
git push origin main
```

The workflow runs on every push to `main` and is also runnable manually:
GitHub → **Actions** → **Build and Deploy NGINX to EKS** → **Run workflow**.

## 4. Watch it

GitHub → **Actions** → open the latest run. Expand each step. The two moments
people get stuck on:

- **Configure AWS credentials** failing → an OIDC/trust-policy problem
  ([docs/02 troubleshooting](02-iam-oidc-github.md#7-common-mistakes--troubleshooting)).
- **Wait for rollout** failing with `Unauthorized` → missing access entry
  ([docs/03](03-eks-access-entry.md)).

A green run ends with output like:

```
deployment "nginx" successfully rolled out
NAME                     READY   UP-TO-DATE   AVAILABLE
deployment.apps/nginx    2/2     2            2
NAME                         READY   STATUS    RESTARTS
pod/nginx-xxxx                1/1     Running   0
pod/nginx-yyyy                1/1     Running   0
NAME            TYPE        CLUSTER-IP      PORT(S)
service/nginx   ClusterIP   172.20.x.x      80/TCP
configmap/nginx-config   3      ...
secret/nginx-secret      Opaque   2   ...
```

## 5. Manual fallback (run the same flow from your laptop)

Useful for debugging before trusting CI. Requires you to be mapped into the
cluster (you created it, so you are admin).

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-1
REGISTRY=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# 1. Build + push
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY
docker build -t $REGISTRY/nginx-app:manual .
docker push $REGISTRY/nginx-app:manual

# 2. kubeconfig
aws eks update-kubeconfig --name eks-acg --region $REGION

# 3. Secrets -> K8s objects
kubectl apply -f k8s/namespace.yaml
aws secretsmanager get-secret-value --secret-id eks/nginx-app/config --query SecretString --output text > /tmp/config.json
aws secretsmanager get-secret-value --secret-id eks/nginx-app/secret --query SecretString --output text > /tmp/secret.json
jq -r 'to_entries[]|"\(.key)=\(.value)"' /tmp/config.json > /tmp/config.env
jq -r 'to_entries[]|"\(.key)=\(.value)"' /tmp/secret.json > /tmp/secret.env
kubectl create configmap nginx-config -n nginx-app --from-env-file=/tmp/config.env \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic nginx-secret -n nginx-app --from-env-file=/tmp/secret.env \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/config.json /tmp/secret.json /tmp/config.env /tmp/secret.env

# 4. Deploy
sed "s|<AWS_ACCOUNT_ID>|$ACCOUNT_ID|g" k8s/serviceaccount.yaml | kubectl apply -f -
sed "s|image: .*nginx-app:.*|image: $REGISTRY/nginx-app:manual|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml
kubectl rollout status deployment/nginx -n nginx-app
```

## 6. Verify

- [ ] GitHub Actions run is green.
- [ ] `aws ecr list-images --repository-name nginx-app` shows your tags.
- [ ] `kubectl get deploy nginx -n nginx-app` → `2/2`.

Then do the full functional verification: **[08 — Verify & troubleshoot](08-verify-and-troubleshoot.md)**.

## 7. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Workflow doesn't start | Pushed to a non-`main` branch | Push to `main` or use *Run workflow*. |
| `docker build` fails: no Dockerfile | Ran from wrong dir | Workflow uses repo root; ensure `Dockerfile` is at root. |
| `ImagePullBackOff` on pods | Image URI/account wrong, or node role can't pull ECR | Check the deployed image URI; confirm node role has `AmazonEC2ContainerRegistryReadOnly`. |
| Values appear in logs | Forgot masking | Workflow masks via `::add-mask::`; never `echo` secret values yourself. |
| `kubectl apply` of secret recreates every run | Expected — idempotent `apply` is intentional | No action; it converges to Secrets Manager state. |

Next: **[08 — Verify & troubleshoot](08-verify-and-troubleshoot.md)**.
