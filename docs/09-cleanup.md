# 09 — Cleanup (stop the meter)

Delete in roughly the reverse order you created things. The big ongoing costs
are the **EKS control plane**, the **3 t3.medium nodes**, and the **NAT
gateways** — those bill whether or not anything is deployed.

## 9.1 Remove the Kubernetes workload (optional if deleting the cluster)

```bash
kubectl delete -f k8s/service.yaml --ignore-not-found
kubectl delete -f k8s/deployment.yaml --ignore-not-found
kubectl delete secret nginx-secret configmap nginx-config -n nginx-app --ignore-not-found
kubectl delete -f k8s/serviceaccount.yaml --ignore-not-found
kubectl delete namespace nginx-app --ignore-not-found
```

## 9.2 Remove the CloudWatch add-on

Console: EKS → eks-acg → **Add-ons** → *Amazon CloudWatch Observability* →
**Remove**. Then delete leftover log groups (CloudWatch → Logs → Log groups →
select `/aws/containerinsights/eks-acg/*` → Delete) so stored logs stop billing.

```bash
aws eks delete-addon --cluster-name eks-acg \
  --addon-name amazon-cloudwatch-observability --region us-east-1
```

## 9.3 Delete ECR images / repository

```bash
aws ecr delete-repository --repository-name nginx-app --force --region us-east-1
```

## 9.4 Delete the Secrets Manager secrets

```bash
aws secretsmanager delete-secret --secret-id eks/nginx-app/secret \
  --force-delete-without-recovery --region us-east-1
aws secretsmanager delete-secret --secret-id eks/nginx-app/config \
  --force-delete-without-recovery --region us-east-1
```

(Without `--force-delete-without-recovery` they linger for a 7–30 day recovery
window — still free, but they show up as "scheduled for deletion".)

## 9.5 Delete IAM roles & providers (only if you're done entirely)

- Roles: `github-actions-eks-deploy`, `eks-nginx-app-irsa-role`,
  `eks-cloudwatch-agent-role` (detach inline/managed policies first).
- Identity providers: the GitHub one, and the cluster's `oidc.eks...` one (the
  latter disappears with the cluster anyway).

IAM roles and OIDC providers are **free**, so you can keep them between sessions
if you'll redeploy.

## 9.6 Delete the cluster (the expensive part)

If this was the whole point of the session, tear the cluster down — eksctl also
removes the VPC, NAT gateways, and node group it created:

```bash
eksctl delete cluster --name eks-acg --region us-east-1
```

## 9.7 Verify nothing costly remains

```bash
aws eks list-clusters --region us-east-1
aws ec2 describe-nat-gateways --region us-east-1 \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId'
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName'
```

All should be empty (or not list `eks-acg` / `nginx-app`). Also glance at the
**Billing → Cost Explorer** the next day to confirm charges stopped.
