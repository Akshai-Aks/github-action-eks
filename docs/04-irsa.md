# 04 — IRSA (IAM Roles for Service Accounts)

## 1. Why it is needed

Pods sometimes need to call AWS (read a secret, write to S3, push metrics). The
bad old options were: (a) bake AWS keys into the image, or (b) give the whole
**node** a fat IAM role that *every* pod on it inherits. Both over-share.

**IRSA** gives each *pod* its own least-privilege IAM role using the same OIDC
trick as GitHub: the cluster has an **OIDC provider**, a Kubernetes
**ServiceAccount** is annotated with a role ARN, and the pod receives a
short-lived token it exchanges for that role's temporary credentials.

In this project the app's secrets are delivered by GitHub Actions, so the nginx
pod doesn't strictly need AWS access — but we wire IRSA so you can **see it
work**, and because the CloudWatch add-on ([docs/06](06-cloudwatch-container-insights.md))
uses the exact same mechanism.

## 2. What it does

- The **EKS OIDC provider** publishes a public JWKS endpoint; IAM trusts it.
- An **IAM role** with a trust policy scoped to one `namespace:serviceaccount`.
- The **ServiceAccount annotation** `eks.amazonaws.com/role-arn` tells the EKS
  pod-identity webhook to inject the token + env vars into pods using that SA.

---

## 3A. Ensure the cluster has an IAM OIDC provider

`eksctl` does **not** always create the IRSA OIDC provider unless asked. Check
first.

**Console:** EKS → **eks-acg** → **Overview** tab → copy the **OpenID Connect
provider URL** (looks like `https://oidc.eks.us-east-1.amazonaws.com/id/ABCD...`).
Then IAM → **Identity providers** — is there an entry whose URL matches that
`oidc.eks...` host? If **yes**, skip to 3B. If **no**, create it.

**Easiest creation (CLI/eksctl), one command:**

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster eks-acg --region us-east-1 --approve
```

**Or via Console (manual):** IAM → Identity providers → Add provider → OpenID
Connect → Provider URL = the cluster's `oidc.eks...` URL → **Get thumbprint** →
Audience = `sts.amazonaws.com` → Add.

## 3B. Create the IRSA role

The cleanest path uses eksctl (it writes the fiddly trust policy for you):

```bash
eksctl create iamserviceaccount \
  --cluster eks-acg --region us-east-1 \
  --namespace nginx-app --name nginx-sa \
  --role-name eks-nginx-app-irsa-role \
  --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
  --role-only \
  --approve
```

`--role-only` creates *just the IAM role* (we create the ServiceAccount from
`k8s/serviceaccount.yaml` so it's version-controlled). For a tighter policy than
the AWS-managed `SecretsManagerReadWrite`, attach a custom policy scoped to
`secret:eks/nginx-app/*` instead (same JSON as the `ReadAppSecrets` statement in
[docs/02](02-iam-oidc-github.md)).

### Pure-Console alternative for the role

1. IAM → **Roles** → **Create role** → **Web identity**.
2. **Identity provider:** the cluster's `oidc.eks.us-east-1...` provider.
3. **Audience:** `sts.amazonaws.com` → **Next**.
4. Attach a policy (e.g. a custom Secrets Manager read policy) → name it
   `eks-nginx-app-irsa-role` → **Create**.
5. Edit its **Trust policy** to pin the exact ServiceAccount:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com",
        "oidc.eks.us-east-1.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:nginx-app:nginx-sa"
      }
    }
  }]
}
```

Replace `<OIDC_ID>` with the trailing id from the cluster's OIDC URL.

## 4. What each option / claim means

| Item | Meaning |
|------|---------|
| **OIDC provider URL** (`oidc.eks...`) | The cluster's token issuer; unique per cluster. |
| `:aud = sts.amazonaws.com` | The token audience IRSA always uses. |
| `:sub = system:serviceaccount:<ns>:<sa>` | **The key line** — only pods running as `nginx-app/nginx-sa` may assume the role. |
| `eks.amazonaws.com/role-arn` annotation | On the ServiceAccount; tells EKS which role to hand the pod. |

## 5. Why these values

- `--role-only` keeps the ServiceAccount in Git (`k8s/serviceaccount.yaml`),
  not eksctl-managed, so the pipeline owns it.
- The `sub` condition is the entire security boundary — without it, *any* SA in
  the cluster could grab the role.

## 6. How to verify

After the pipeline deploys the SA + a pod:

```bash
# The SA carries the annotation:
kubectl get sa nginx-sa -n nginx-app -o jsonpath='{.metadata.annotations}'; echo

# A running pod has the IRSA env vars injected by the webhook:
POD=$(kubectl get pod -n nginx-app -l app=nginx -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nginx-app "$POD" -- env | grep AWS_
# expect: AWS_ROLE_ARN=...eks-nginx-app-irsa-role  and AWS_WEB_IDENTITY_TOKEN_FILE=...

# Prove the pod actually assumes the role (install awscli in a debug pod, or):
kubectl exec -n nginx-app "$POD" -- sh -c \
  'wget -qO- https://sts.amazonaws.com 2>/dev/null; echo irsa-env-present'
```

The decisive test is in [docs/08](08-verify-and-troubleshoot.md), where a debug
pod runs `aws sts get-caller-identity` and returns the **assumed-role** ARN.

## 7. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod env has no `AWS_ROLE_ARN` | SA missing/incorrect annotation, or pod created before annotation existed | Fix annotation, then `kubectl rollout restart deploy/nginx -n nginx-app`. |
| `An error occurred (AccessDenied) ... not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy `sub` doesn't match `system:serviceaccount:nginx-app:nginx-sa` | Fix the namespace/SA names in the trust policy. |
| `no OIDC provider` | Cluster OIDC provider not associated in IAM | Run `eksctl utils associate-iam-oidc-provider ...`. |
| Annotation present, still denied calling a service | The role's *permission* policy lacks the action | Attach/scope the right permission policy. |

Next: **[05 — AWS Secrets Manager](05-secrets-manager.md)**.
