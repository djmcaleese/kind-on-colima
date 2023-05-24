#!/bin/bash

set -euo pipefail

REGION=eu-west-2

for VM_NAME in mgmt cluster1 cluster2; do
  printf "Creating VM for \"${VM_NAME}\"...\n"
  colima start -a x86_64 -c2 -m8 -d20 --network-address ${VM_NAME}

  LIMA_VM_IP=$(colima ssh -p ${VM_NAME} -- ifconfig col0 | grep "inet addr:" | awk -F' ' '{print $2}' | awk -F':' '{print $2}')
  INDEX=$(($(echo ${LIMA_VM_IP} | cut -d'.' -f4) - 2))

  ZONE=${REGION}$(echo $((${INDEX} % 3)) | tr 012 abc)

  if [[ "${INDEX}" == 0 ]]; then
    CLUSTER_NAME=${VM_NAME}-mgmt
  else
    CLUSTER_NAME=${VM_NAME}-kind${INDEX}
  fi

  printf "Creating cluster \"${CLUSTER_NAME}\"...\n"
  KIND_CONFIG_FILE=/tmp/kind-${CLUSTER_NAME}-config.yaml
  cat << EOF > $KIND_CONFIG_FILE
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
- role: control-plane
  labels:
    ingress-ready: true
    topology.kubernetes.io/region: ${REGION}
    topology.kubernetes.io/zone: ${ZONE}
networking:
  apiServerAddress: ${LIMA_VM_IP}
  apiServerPort: 6443
EOF

  docker context use colima-${VM_NAME}
  kind create cluster --name ${CLUSTER_NAME} --config ${KIND_CONFIG_FILE} --wait 120s
  rm ${KIND_CONFIG_FILE}
  CLUSTER_CONTEXT=kind-${CLUSTER_NAME}

  printf "Installing MetalLB...\n"
  kubectl --context ${CLUSTER_CONTEXT} apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
  printf "Waiting for MetalLB...\n"
  kubectl --context ${CLUSTER_CONTEXT} -n metallb-system wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s deploy/controller

  NETWORK_PREFIX=$(echo ${LIMA_VM_IP} | cut -d'.' -f1-3)
  LB_RANGE_START=${NETWORK_PREFIX}.$((${INDEX} * 20 + 50))
  LB_RANGE_END=${NETWORK_PREFIX}.$((${INDEX} * 20 + 69))

  printf "Configuring MetalLB with IP range ${LB_RANGE_START}-${LB_RANGE_END}...\n"
  kubectl --context ${CLUSTER_CONTEXT} apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: pool
  namespace: metallb-system
spec:
  addresses:
  - ${LB_RANGE_START}-${LB_RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
EOF

  printf "\nFinished creating cluster ${CLUSTER_NAME} on ${VM_NAME}. "
  printf "You can alias this with:\n  alias k${INDEX}=\"kubectl --context ${CLUSTER_CONTEXT}\"\n\n"

done
