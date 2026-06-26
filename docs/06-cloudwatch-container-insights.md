# 06 — Amazon CloudWatch Container Insights (the recommended way)

## 1. Why it is needed

A cluster you can't observe is a cluster you can't operate. You want:
- **Metrics** — CPU/memory/network/disk per pod, node, namespace, cluster.
- **Logs** — every container's stdout/stderr, plus host and dataplane logs.

Doing this by hand (deploy an agent DaemonSet, a Fluent Bit DaemonSet, wire IAM,
manage upgrades) is fiddly. AWS now ships a single managed **EKS add-on** that
does all of it: **Amazon CloudWatch Observability**.

## 2. What it does — and why it's "recommended over the CLI agent"

The **Amazon CloudWatch Observability add-on** installs and manages:
- the **CloudWatch agent** (as a DaemonSet) → publishes **Container Insights**
  metrics, and
- **Fluent Bit** (as a DaemonSet) → ships container/host/dataplane **logs** to
  CloudWatch Logs.

It is the modern replacement for the old "quick start" YAML / manual CloudWatch
agent install. Being an add-on, AWS handles version upgrades, and it integrates
with **IRSA / EKS Pod Identity** for permissions — which is exactly why we set
up IRSA in [docs/04](04-irsa.md).

It creates these CloudWatch **log groups** automatically:

| Log group | Contents |
|-----------|----------|
| `/aws/containerinsights/eks-acg/application` | your pods' stdout/stderr (incl. nginx) |
| `/aws/containerinsights/eks-acg/host` | node/system logs |
| `/aws/containerinsights/eks-acg/dataplane` | kubelet, kube-proxy, container runtime |
| `/aws/containerinsights/eks-acg/performance` | structured performance metrics |

---

## 3. Install it from the Console

### 3A. Give the add-on permissions (IRSA role)

The CloudWatch agent pod needs IAM permission to call CloudWatch. The simplest,
AWS-blessed path is an IRSA role with the managed
`CloudWatchAgentServerPolicy`. eksctl one-liner:

```bash
eksctl create iamserviceaccount \
  --cluster eks-acg --region us-east-1 \
  --namespace amazon-cloudwatch --name cloudwatch-agent \
  --role-name eks-cloudwatch-agent-role \
  --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
  --role-only --approve
```

> If you prefer **zero IAM clicks**, you can instead attach
> `CloudWatchAgentServerPolicy` to the **node group's** IAM role (Console: EC2 →
> the node IAM role → Add permissions). That's less granular than IRSA but works
> for a demo. IRSA is the recommended, least-privilege choice.

### 3B. Add the add-on (Console)

1. Console → **EKS** → **eks-acg** → **Add-ons** tab → **Get more add-ons**.
2. Find and check **Amazon CloudWatch Observability** → **Next**.
3. **Version:** leave the default (latest).
4. **IAM role / permissions:**
   - If you made the IRSA role above, choose **Use an existing IAM role** and
     select `eks-cloudwatch-agent-role` (or its service-account mapping), **or**
   - choose the recommended **EKS Pod Identity** option if offered and let the
     wizard create the role.
5. **Conflict resolution:** `Override` (fine for a fresh install).
6. **Next** → **Create**.

### What each option means

| Option | Meaning | Choice |
|--------|---------|--------|
| **Add-on version** | The packaged agent/Fluent Bit version | Latest default. |
| **IAM role** | Identity the agent uses to write to CloudWatch | The IRSA role (recommended) or Pod Identity. |
| **Conflict resolution** | What to do if config already exists | `Override` on first install. |
| **Optional configuration** | JSON to tune what's collected (e.g. enable enhanced observability, accelerated compute metrics) | Leave empty for defaults; defaults already collect pod/node/cluster metrics + logs. |

## 4. Why these values

- The add-on (not the legacy manual YAML) because it's **managed, upgradable,
  and IRSA-integrated** — the approach AWS currently recommends.
- `CloudWatchAgentServerPolicy` is the **exact** managed policy AWS publishes for
  this agent; don't hand-roll it.
- Namespace `amazon-cloudwatch` is the convention the add-on expects.

## 5. How EKS now sends data to CloudWatch (the data path)

```
nginx pod stdout ─┐
node/system logs ─┼─► Fluent Bit (DaemonSet) ─► CloudWatch Logs (4 log groups)
dataplane logs  ─┘
kubelet metrics ───► CloudWatch agent (DaemonSet) ─► CloudWatch (Container Insights metrics)
```

## 6. View logs & metrics in the Console

**Metrics / dashboards:**
1. Console → **CloudWatch** → left nav **Insights → Container Insights**.
2. Pick **eks-acg**. You get auto-dashboards for **Clusters, Nodes, Namespaces,
   Pods, Services** with CPU/memory/network. Drill into the `nginx-app`
   namespace → the `nginx` pods.

**Logs:**
1. CloudWatch → **Logs → Log groups**.
2. Open `/aws/containerinsights/eks-acg/application`.
3. Open a log stream named after an `nginx-...` pod → you'll see nginx access
   logs. Use **Logs Insights** to query:
   ```
   fields @timestamp, log
   | filter kubernetes.pod_name like /nginx/
   | sort @timestamp desc
   | limit 50
   ```

## 7. How to verify the install

```bash
# DaemonSets running on every node:
kubectl get daemonset -n amazon-cloudwatch
# expect: cloudwatch-agent  and  fluent-bit  (DESIRED == 3, matching your 3 nodes)

kubectl get pods -n amazon-cloudwatch
# all Running

# Add-on health:
aws eks describe-addon --cluster-name eks-acg \
  --addon-name amazon-cloudwatch-observability --region us-east-1 \
  --query 'addon.status'    # -> "ACTIVE"

# Log groups exist:
aws logs describe-log-groups --log-group-name-prefix /aws/containerinsights/eks-acg \
  --region us-east-1 --query 'logGroups[].logGroupName'
```

## 8. Common mistakes & troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Add-on `DEGRADED`; agent pods `CrashLoopBackOff` with `AccessDenied` | Agent SA has no IAM permission | Attach `CloudWatchAgentServerPolicy` via IRSA, or to the node role; restart the DaemonSet. |
| No log groups appear | Fluent Bit can't reach CloudWatch endpoint | Private nodes need NAT (your `nat: HighlyAvailable` provides it) **or** a CloudWatch Logs VPC endpoint; check node egress. |
| Container Insights page empty | Metrics take 2–5 min after install; or wrong region | Wait a few minutes; confirm region selector = us-east-1. |
| Pods `Pending` after install | t3.medium nodes near capacity (agent + fluent-bit + nginx) | Fine for 3 nodes; if tight, scale the node group. |
| Logs cost rising | Default retention is "Never expire" | Set retention on each log group (Console → Log group → *Retention setting* → e.g. 7 days). |

Next: **[07 — Pipeline & deploy](07-pipeline-and-deploy.md)**.
