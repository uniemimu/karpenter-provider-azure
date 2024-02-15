#!/usr/bin/env bash
set -euo pipefail

# This script interrogates the AKS cluster and Azure resources to generate 
# the karpenter-values.yaml file using the karpenter-values-template.yaml file as a template.

# Check the cluster name and resource group are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <cluster-name> <resource-group>"
    exit 1
fi

echo "Configuring karpenter-values.yaml for cluster $1 in resource group $2 ..."

AZURE_CLUSTER_NAME=$1
AZURE_RESOURCE_GROUP=$2

AKS_JSON=$(az aks show --name "$AZURE_CLUSTER_NAME" --resource-group "$AZURE_RESOURCE_GROUP")
AZURE_LOCATION=$(jq -r ".location" <<< "$AKS_JSON")
AZURE_RESOURCE_GROUP_MC=$(jq -r ".nodeResourceGroup" <<< "$AKS_JSON")

KARPENTER_SERVICE_ACCOUNT_NAME=karpenter-sa
AZURE_KARPENTER_USER_ASSIGNED_IDENTITY_NAME=karpentermsi

CLUSTER_ENDPOINT=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

TOKEN_SECRET_NAME=$(kubectl get -n kube-system secrets --field-selector=type=bootstrap.kubernetes.io/token -o jsonpath='{.items[0].metadata.name}')
TOKEN_ID=$(kubectl get -n kube-system secret "$TOKEN_SECRET_NAME" -o jsonpath='{.data.token-id}' | base64 -d)
TOKEN_SECRET=$(kubectl get -n kube-system secret "$TOKEN_SECRET_NAME" -o jsonpath='{.data.token-secret}' | base64 -d)
BOOTSTRAP_TOKEN=$TOKEN_ID.$TOKEN_SECRET

SSH_PUBLIC_KEY="$(cat ~/.ssh/id_rsa.pub) azureuser"
VNET_JSON=$(az network vnet list --resource-group "$AZURE_RESOURCE_GROUP_MC" | jq -r ".[0]")
AZURE_VNET_NAME=$(jq -r ".name" <<< "$VNET_JSON")
AZURE_SUBNET_NAME=$(jq -r ".subnets[0].name" <<< "$VNET_JSON")
AZURE_SUBNET_ID=$(jq -r ".subnets[0].id" <<< "$VNET_JSON")

KARPENTER_USER_ASSIGNED_CLIENT_ID=$(az identity show --resource-group "${AZURE_RESOURCE_GROUP}" --name "${AZURE_KARPENTER_USER_ASSIGNED_IDENTITY_NAME}" --query 'clientId' -otsv)

export AZURE_CLUSTER_NAME AZURE_LOCATION AZURE_RESOURCE_GROUP_MC KARPENTER_SERVICE_ACCOUNT_NAME \
    CLUSTER_ENDPOINT BOOTSTRAP_TOKEN SSH_PUBLIC_KEY AZURE_VNET_NAME AZURE_SUBNET_NAME AZURE_SUBNET_ID \
    KARPENTER_USER_ASSIGNED_CLIENT_ID

# get karpenter-values-template.yaml, if not already present (e.g. outside of repo context)
if [ ! -f karpenter-values-template.yaml ]; then
    curl -sO https://raw.githubusercontent.com/Azure/karpenter/main/karpenter-values-template.yaml
fi
yq '(.. | select(tag == "!!str")) |= envsubst(nu)' karpenter-values-template.yaml > karpenter-values.yaml
