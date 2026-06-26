# ---------------------------------------------------------------------------
# NGINX application image.
#
# Requirement: "When I access the NGINX application, the default NGINX page
# should be displayed."  => We deliberately DO NOT replace the contents of
# /usr/share/nginx/html. We start from the official image so the stock
# "Welcome to nginx!" page is served untouched.
#
# The whole point of this repo is the *pipeline* (build -> ECR -> EKS) and the
# *integrations* (Secrets Manager -> K8s Secret/ConfigMap, IRSA, CloudWatch),
# not a custom web app. So the image stays intentionally minimal.
# ---------------------------------------------------------------------------
FROM nginx:1.27-alpine

# OCI labels make the image self-describing in ECR (good hygiene, not required).
LABEL org.opencontainers.image.title="nginx-app" \
      org.opencontainers.image.description="Default NGINX served from EKS via GitHub Actions" \
      org.opencontainers.image.source="https://github.com/Akshai-Aks/github-action-eks"

# nginx:alpine already EXPOSEs 80, runs nginx in the foreground, and ships a
# working default.conf that serves the welcome page. Nothing else to do.
EXPOSE 80
