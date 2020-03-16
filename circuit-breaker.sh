#!/bin/bash

set -e # stop script execution on failure
set -x

## -------
# Write stdout and stderr to createAzureInfrasture.log.txt file
exec > >(tee "circuit-breaker.log.txt")
exec 2>&1

## -------
# Shell script variables
AZURE_SUBSCRIPTION_ID=''
AZURE_REGION='westus2'
AZURE_RESOURCE_GROUP='aaros-cdc-rg'
AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT='aaroscdcstorage2'
AZURE_FRONTDOOR_NAME='aaros-fd-test'

## -------
# Install the front-door az cli extension if it isn't already installed
az extension add --name front-door

## -------
# Login to Azure and set the Azure subscription for this script to use
############az login
az account set --subscription $AZURE_SUBSCRIPTION_ID

## -------
# Ensure the resource group exists, if not error out as the RG and FrontDoor should already exist
RG_EXISTS=$(az group list --query "[?contains(name, '$AZURE_RESOURCE_GROUP')].name" -o tsv)
if [ -z "$RG_EXISTS" ]
then
    echo "Resource group $AZURE_RESOURCE_GROUP not found"
    exit 1
fi

## -------
# Create an Azure Storage account to use as a CDN to host the service-unavailable.html page
SA_EXISTS=$(az storage account list --query "[?contains(name, '$AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT')].name" -o tsv)
if [ -z "$SA_EXISTS" ]
then
    echo "Storage account $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT doesn't exist, creating it"
    az storage account create \
        --name $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT \
        --resource-group $AZURE_RESOURCE_GROUP \
        --sku "Standard_GRS" \
        --location $AZURE_REGION \
        --kind "StorageV2"

    echo "Setting static website property on storage account"
    az storage blob service-properties update \
        --account-name $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT \
        --static-website \
        --404-document service-unavailable.html \
        --index-document service-unavailable.html
fi

## -------
# Get the connection string for the storage account so we can upload a blob to it
SA_CONNECTION_STRING=$(az storage account show-connection-string --resource-group $AZURE_RESOURCE_GROUP --name $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT -o tsv)

## -------
# Upload the service-unavailable.html page to the blog storage account if it doesn't exist
HTML_EXISTS=$(az storage blob exists --connection-string $SA_CONNECTION_STRING --account-name $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT --container-name '$web' --name service-unavailable.html -o tsv)
if [ $HTML_EXISTS == "False" ]
then
    az storage blob upload -f ./service-unavailable.html -c '$web' -n service-unavailable.html --account-name $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT --connection-string $SA_CONNECTION_STRING --content-type 'text/html; charset=utf-8'
fi

## -------
# Get the URL for the static failover page
FAILOVER_URI=$(az storage account show -n $AZURE_SERVICE_UNAVAILABLE_STORAGE_ACCOUNT -g $AZURE_RESOURCE_GROUP --query "primaryEndpoints.web" --output tsv)

## -------
# Get the name of the primary backend pool (should be a single primary pool)
BACKEND_POOL=$(az network front-door backend-pool list --front-door-name $AZURE_FRONTDOOR_NAME --resource-group $AZURE_RESOURCE_GROUP --query '[].name' -o tsv)

## -------
# Add a low priority Azure Frontoor backend pool pointed at the service-univailable.html Azure Storage endpoint as a failover
az network front-door backend-pool backend add \
    --address $FAILOVER_URI \
    --front-door-name $AZURE_FRONTDOOR_NAME \
    --pool-name $BACKEND_POOL \
    --resource-group $AZURE_RESOURCE_GROUP \
    --priority 5