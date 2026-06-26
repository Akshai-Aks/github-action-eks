# 08 — Verify Everything & Troubleshoot

This is your acceptance checklist. Each subsection proves one requirement.

## 8.1 The default NGINX page is served (no LB/Ingress)

Because the Service is `ClusterIP`, reach it with a local port-forward (a tunnel
from your laptop into the cluster — *not* an AWS exposure mechanism):

```bash
kubectl port-forward -n nginx-app svc/nginx 8080:80
# in another terminal:
curl -s http://localhost:8080 | head -n 5
```

Expected — the stock welcome page:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

Or test entirely in-cluster (no port-forward) with a throwaway pod:

```bash
kubectl run curl-test --rm -it --image=curlimages/curl -n nginx-app --restart=Never -- \
  curl -s http://nginx.nginx-app.svc.cluster.local | grep -i "Welcome to nginx"
```

✅ Requirement met: default page shows, exposure is in-cluster only.

## 8.2 The app consumes the ConfigMap (env vars)

```bash
POD=$(kubectl get pod -n nginx-app -l app=nginx -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n nginx-app "$POD" -- printenv APP_ENV WELCOME_MESSAGE LOG_LEVEL
```

Expected:

```
production
Hello from EKS via GitHub Actions
info
```

These came from Secrets Manager `eks/nginx-app/config` → K8s ConfigMap
`nginx-config` → `envFrom.configMapRef`.

## 8.3 The app consumes the Secret (env vars + mounted files)

```bash
# as environment variables
kubectl exec -n nginx-app "$POD" -- printenv APP_API_KEY DB_PASSWORD

# as files (volume mount)
kubectl exec -n nginx-app "$POD" -- ls -1 /etc/nginx-app/secret
kubectl exec -n nginx-app "$POD" -- cat /etc/nginx-app/secret/APP_API_KEY; echo
```

Expected: `demo-super-secret-key-123`, `p@ssw0rd-demo`, and files
`APP_API_KEY` / `DB_PASSWORD` under the mount path.

These came from Secrets Manager `eks/nginx-app/secret` → K8s Secret
`nginx-secret` → `envFrom.secretRef` + the `secret-files` volume.

## 8.4 IRSA actually grants the pod an AWS identity

```bash
kubectl exec -n nginx-app "$POD" -- env | grep AWS_
# AWS_ROLE_ARN=arn:aws:iam::<acct>:role/eks-nginx-app-irsa-role
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

Prove the pod can assume the role (the alpine nginx image has no AWS CLI, so use
a debug pod that shares the same ServiceAccount):

```bash
kubectl run irsa-test --rm -it -n nginx-app --restart=Never \
  --image=amazon/aws-cli \
  --overrides='{"spec":{"serviceAccountName":"nginx-sa"}}' \
  --command -- aws sts get-caller-identity
```

Expected — the **assumed-role** ARN, proving keyless identity:

```json
{
  "Account": "111122223333",
  "Arn": "arn:aws:sts::111122223333:assumed-role/eks-nginx-app-irsa-role/botocore-session-..."
}
```

## 8.5 CloudWatch is receiving logs & metrics

```bash
kubectl get pods -n amazon-cloudwatch        # cloudwatch-agent + fluent-bit Running
aws logs describe-log-groups \
  --log-group-name-prefix /aws/containerinsights/eks-acg \
  --region us-east-1 --query 'logGroups[].logGroupName'
```

Console: **CloudWatch → Container Insights → eks-acg** shows node/pod metrics;
**Logs → `/aws/containerinsights/eks-acg/application`** has streams for the
`nginx-...` pods. Generate some access logs first (run the curl from 8.1 a few
times), then query in Logs Insights (see [docs/06 §6](06-cloudwatch-container-insights.md#6-view-logs--metrics-in-the-console)).

## 8.6 Full acceptance checklist

- [ ] Pipeline run green; image in ECR.
- [ ] `kubectl get deploy nginx -n nginx-app` → `2/2 Available`.
- [ ] Default nginx page returned via port-forward / in-cluster curl.
- [ ] ConfigMap env vars present in the pod.
- [ ] Secret env vars **and** mounted files present in the pod.
- [ ] Pod has `AWS_ROLE_ARN`; debug pod assumes `eks-nginx-app-irsa-role`.
- [ ] `amazon-cloudwatch` DaemonSets Running; Container Insights + log groups populated.
- [ ] No LoadBalancer/Ingress exists: `kubectl get svc,ingress -A | grep -iE 'load|ingress'` returns nothing for `nginx-app`.

## 8.7 Troubleshooting quick index

| Area | Symptom | Where to look |
|------|---------|---------------|
| OIDC auth | `sts:AssumeRoleWithWebIdentity` denied | [docs/02](02-iam-oidc-github.md#7-common-mistakes--troubleshooting) |
| kubectl authz | `Unauthorized` in CI | [docs/03](03-eks-access-entry.md#7-common-mistakes--troubleshooting) |
| Image pull | `ImagePullBackOff` | [docs/01](01-ecr.md#8-common-mistakes--troubleshooting) / [docs/07](07-pipeline-and-deploy.md#7-common-mistakes--troubleshooting) |
| Secrets | `GetSecretValue` denied / `jq` error | [docs/05](05-secrets-manager.md#8-common-mistakes--troubleshooting) |
| IRSA | no `AWS_ROLE_ARN` / assume denied | [docs/04](04-irsa.md#7-common-mistakes--troubleshooting) |
| CloudWatch | no log groups / agent crash | [docs/06](06-cloudwatch-container-insights.md#8-common-mistakes--troubleshooting) |

### Universal debugging commands

```bash
kubectl describe pod -n nginx-app -l app=nginx     # events at the bottom explain most failures
kubectl logs -n nginx-app -l app=nginx --tail=50
kubectl get events -n nginx-app --sort-by=.lastTimestamp
```

Next: **[09 — Cleanup](09-cleanup.md)**.
