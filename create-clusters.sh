#!/bin/bash

set -euo pipefail

VM_NAME=gloodemo
REGION=eu-west-2

printf "Creating VM for \"${VM_NAME}\"...\n"
colima start -t vz --vz-rosetta -c4 -m16 -d20 --network-address ${VM_NAME}

LIMA_VM_IP=$(colima ssh -p ${VM_NAME} -- ifconfig col0 | grep "inet addr:" | awk -F' ' '{print $2}' | awk -F':' '{print $2}')
for INDEX in {0..2}; do

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
  extraPortMappings:
  - containerPort: 6443
    hostPort: 70$(printf "%02d\n" ${INDEX})
  labels:
    ingress-ready: true
    topology.kubernetes.io/region: ${REGION}
    topology.kubernetes.io/zone: ${ZONE}
EOF

  docker context use colima-${VM_NAME}
  kind create cluster --name ${CLUSTER_NAME} --config ${KIND_CONFIG_FILE} --wait 120s
  rm ${KIND_CONFIG_FILE}
  CLUSTER_CONTEXT=kind-${CLUSTER_NAME}

  printf "Installing MetalLB...\n"
  kubectl --context ${CLUSTER_CONTEXT} apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.9/config/manifests/metallb-native.yaml
  printf "Waiting for MetalLB...\n"
  kubectl --context ${CLUSTER_CONTEXT} -n metallb-system wait --for=jsonpath='{.status.readyReplicas}'=1 --timeout=120s deploy/controller

  NETWORK_PREFIX=$(docker -c colima-${VM_NAME} network inspect kind | jq -r '.[0].IPAM.Config[0].Subnet' | cut -d'.' -f1-2)
  LB_RANGE_START=${NETWORK_PREFIX}.$((${INDEX} + 10)).1
  LB_RANGE_END=${NETWORK_PREFIX}.$((${INDEX} + 10)).254

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

done;

printf "Setting up IP forwarding from the guest VM to KinD...\n"
INTERFACE_PREFIX=$(docker -c colima-${VM_NAME} network inspect kind --format '{{.Id}}'  | cut -c -5)
KIND_IF=$(colima ssh -p ${VM_NAME} -- ip link show | grep ${INTERFACE_PREFIX} | head -n1 | cut -d ':' -f2 | tr -d " ")
HOST_IF=col0
SRC_IP_GW=$(echo ${LIMA_VM_IP} | cut -d'.' -f1-3).1
DST_NET=${NETWORK_PREFIX}.0.0/16

colima ssh -p ${VM_NAME} -- sudo iptables -t filter -D FORWARD -4 -p tcp -s ${LIMA_VM_IP} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${KIND_IF} > /dev/null 2>&1 || true
colima ssh -p ${VM_NAME} -- sudo iptables -t filter -D FORWARD -4 -p tcp -s ${SRC_IP_GW} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${KIND_IF} > /dev/null 2>&1 || true
colima ssh -p ${VM_NAME} -- sudo iptables -t filter -A FORWARD -4 -p tcp -s ${LIMA_VM_IP} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${KIND_IF}
colima ssh -p ${VM_NAME} -- sudo iptables -t filter -A FORWARD -4 -p tcp -s ${SRC_IP_GW} -d ${DST_NET} -j ACCEPT -i ${HOST_IF} -o ${KIND_IF}

printf "\nFinished setting up ${VM_NAME}. "
printf "To access services from your machine, add a route to this host by running:\n  sudo route -nv delete -net ${NETWORK_PREFIX}\n  sudo route -nv add -net ${NETWORK_PREFIX} ${LIMA_VM_IP}\n"
