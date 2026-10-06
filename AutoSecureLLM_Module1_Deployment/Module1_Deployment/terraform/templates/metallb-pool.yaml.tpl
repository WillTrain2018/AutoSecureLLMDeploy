# Rendered by local_file.metallb_address_pool_manifest in main.tf.
# MetalLB's own CRDs (IPAddressPool, L2Advertisement) - applied via kubectl
# rather than a native Terraform kubernetes_manifest resource, since those
# CRDs are installed by the metallb helm_release in the same apply, and
# kubernetes_manifest validates CRD schemas at PLAN time, before the CRD
# that defines them exists yet. Applying via kubectl sidesteps that
# ordering problem entirely.
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tc-llm-pool
  namespace: metallb-system
spec:
  addresses:
    - ${cidr}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: tc-llm-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - tc-llm-pool
