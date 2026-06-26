# 05 — AWS Secrets Manager

## 1. Why it is needed

Application configuration and credentials should not live in Git or in the
image. **AWS Secrets Manager** is a managed vault: encrypted at rest (KMS),
access-controlled by IAM, audited in CloudTrail, and rotatable.

In this project it is the **single source of truth**. At deploy time GitHub
Actions reads it and projects the values into the cluster as a Kubernetes
**Secret** (sensitive) and a Kubernetes **ConfigMap** (non-sensitive). Change a
value in Secrets Manager, re-run the pipeline, and the cluster updates — no code
change.

## 2. What it does

You store a **secret** whose value is a string. We use **JSON key/value**
secrets so each key maps cleanly to one environment variable. We create **two**
secrets to mirror the two Kubernetes objects:

| Secrets Manager secret | Becomes | Holds |
|------------------------|---------|-------|
| `eks/nginx-app/secret` | K8s **Secret** `nginx-secret` | sensitive: API keys, passwords |
| `eks/nginx-app/config` | K8s **ConfigMap** `nginx-config` | non-sensitive: tunables, feature flags |

> Splitting them is a teaching choice: it makes the Secret-vs-ConfigMap
> distinction concrete. You *could* keep one secret and decide per-key.

---

## 3. Create the secrets in the Console

### Secret #1 — the sensitive one

1. Console → **Secrets Manager** → **Store a new secret**.
2. **Secret type:** `Other type of secret`.
3. **Key/value** tab — add these pairs (Plaintext tab shows the JSON):
   - `APP_API_KEY` = `demo-super-secret-key-123`
   - `DB_PASSWORD` = `p@ssw0rd-demo`
4. **Encryption key:** `aws/secretsmanager` (default AWS-managed KMS key).
5. **Next**.
6. **Secret name:** `eks/nginx-app/secret`
   **Description:** `Sensitive values for nginx-app on EKS`.
7. **Next** → **Next** (skip rotation) → **Store**.

### Secret #2 — the non-sensitive config

Repeat the flow with:

- **Key/value:**
  - `APP_ENV` = `production`
  - `WELCOME_MESSAGE` = `Hello from EKS via GitHub Actions`
  - `LOG_LEVEL` = `info`
- **Secret name:** `eks/nginx-app/config`

The resulting JSON (Plaintext view) looks like:

```json
{ "APP_ENV": "production", "WELCOME_MESSAGE": "Hello from EKS via GitHub Actions", "LOG_LEVEL": "info" }
```

## 4. What each option means

| Option | Meaning | Choice |
|--------|---------|--------|
| **Secret type** | RDS/other DB integrations vs free-form | `Other type of secret` — generic key/value. |
| **Key/value vs Plaintext** | Structured JSON vs raw string | **Key/value** — each key → one env var via `jq` in CI. |
| **Encryption key** | Which KMS key encrypts at rest | `aws/secretsmanager` (free, managed). Use a customer KMS key if you need separate key policies/audit. |
| **Secret name** | The `--secret-id` you reference | Must equal `SM_SECRET_NAME` / `SM_CONFIG_NAME` in the workflow. |
| **Rotation** | Auto-rotate via Lambda | Off for this demo; on for real DB creds. |

## 5. Why these values

- **Naming with a `/` prefix** (`eks/nginx-app/...`) groups related secrets and
  lets you scope IAM to `secret:eks/nginx-app/*` (see the policies in
  [docs/02](02-iam-oidc-github.md) and [docs/04](04-irsa.md)).
- The values are obviously fake — never commit real credentials to a learning
  repo, and remember the *Kubernetes* Secret created from these is only
  base64-encoded (encoding, not encryption) inside etcd.

## 6. How the pipeline consumes them (recap)

In `.github/workflows/deploy.yml`, the *Fetch values* + *Create namespace,
ConfigMap and Secret* steps do:

```bash
aws secretsmanager get-secret-value --secret-id eks/nginx-app/secret --query SecretString --output text > secret.json
# jq turns {"K":"V",...} into --from-literal=K=V ... and kubectl applies it idempotently
kubectl create secret generic nginx-secret -n nginx-app <from-literals> --dry-run=client -o yaml | kubectl apply -f -
```

The Deployment then mounts them via `envFrom` (env vars) and a volume (files).

## 7. How to verify

**Console:** Secrets Manager → both secrets listed → open one → **Retrieve
secret value** shows the JSON.

**CLI:**

```bash
aws secretsmanager get-secret-value --secret-id eks/nginx-app/config \
  --query SecretString --output text --region us-east-1
```

**In-cluster (after a deploy):**

```bash
kubectl get configmap nginx-config -n nginx-app -o yaml
kubectl get secret nginx-secret -n nginx-app -o jsonpath='{.data.APP_API_KEY}' | base64 -d; echo
```

## 8. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| CI: `AccessDeniedException ... secretsmanager:GetSecretValue` | Deploy role policy doesn't cover the secret ARN | Confirm the `ReadAppSecrets` resource prefix matches the secret names. |
| `ResourceNotFoundException` | `--secret-id` typo or wrong region | Names must equal `SM_SECRET_NAME`/`SM_CONFIG_NAME`; secret must be in `us-east-1`. |
| `jq: error ... Cannot iterate over string` | Secret stored as Plaintext string, not JSON object | Store as **Key/value** so `SecretString` is a JSON object. |
| ConfigMap/Secret values look truncated | The pipeline uses `--from-env-file`, which treats each line as `KEY=VALUE` — so a value containing a **newline** gets cut | Keep values single-line; for multi-line blobs use `--from-file` with the value written to a file instead. |
| Want the *pod* to read Secrets Manager directly | That's the IRSA + Secrets Store CSI driver pattern | Out of scope here (we sync via CI), but IRSA from [docs/04](04-irsa.md) is the prerequisite. |

Next: **[06 — CloudWatch Container Insights](06-cloudwatch-container-insights.md)**.
