#!/bin/bash
set -eux
if [ -z $1 ]; then
    echo "Usage: $0 ESXi.iso"
    exit 1
fi
if [ ! -f $1 ]; then
    echo "$1 is not a file"
    exit 1
fi

# Function to get the IP address of a virsh domain
get_ip_address() {
	local domain_name="$1"
	# Get the network interface information for the domain
	interface_info=$(virsh domifaddr "$domain_name" | grep -E 'ipv[4|6]' | awk '{print $4}')

	# Extract and print the IP address
	ip_address=$(echo "$interface_info" | cut -d'/' -f1)
	echo "$ip_address"
}

## Parse arguments
VCSA_ISO=$1
VCSA_TEMPLATE_FILE=$2
DOMAIN_NAME=esxi-host

# Check if the domain exists
if ! virsh list --all | grep -q "\<$DOMAIN_NAME\>"; then
	echo "Error: Domain '$DOMAIN_NAME' not found."
	exit 1
fi

DOM_IP_ADDRESS=$(get_ip_address "$DOMAIN_NAME")
VCSA_IP_ADDRESS=''

echo $DOM_IP_ADDRESS

if [[ $(df --output=fstype /mnt | tail -n1) != "udf" ]]; then
	mount -o loop $VCSA_ISO /mnt
fi

VCSA_DEPLOY_BIN=/mnt/vcsa-cli-installer/lin64/vcsa-deploy

$VCSA_DEPLOY_BIN install --accept-eula --acknowledge-ceip --no-ssl-certificate-verification $VCSA_TEMPLATE_FILE

echo "Appliance Name is ready, you can now connect to it from your instance..."
#socat TCP-LISTEN:443,fork TCP:192.168.122.3:443

VCENTER_SERVER="192.168.122.22"
VCENTER_USER="administrator@vsphere.local"
VCENTER_PASSWORD="Admin@123"
NEW_DATACENTER="eks_workshop"
ESXI_HOST="$DOM_IP_ADDRESS"
ESXI_USERNAME="root"
ESXI_PASSWORD="myp@ssw0rd"


# Connect to vCenter Server using connection params
export GOVC_INSECURE=1
export GOVC_URL="https://$VCENTER_SERVER"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD="Admin@123"

# Check if the datacenter already exists
existing_datacenter=$(govc ls / | grep -E "$NEW_DATACENTER$" || true)
if [ -n "$existing_datacenter" ]; then
	echo "Datacenter '$NEW_DATACENTER' already exists."
else
	# Create the datacenter
	govc datacenter.create $NEW_DATACENTER
	echo "Datacenter '$NEW_DATACENTER' created successfully."
fi

# Check if the ESXi host already exists in the datacenter
existing_host=$(govc ls /$NEW_DATACENTER/host | grep -E "$ESXI_HOST$" || true)
if [ -n "$existing_host" ]; then
	echo "ESXi host '$ESXI_HOST' already exists in datacenter '$NEW_DATACENTER'."
else
	# Add the ESXi host to the datacenter
	govc host.add -dc=$NEW_DATACENTER -hostname $ESXI_HOST -username $ESXI_USERNAME -password $ESXI_PASSWORD -noverify
	echo "ESXi host '$ESXI_HOST' added to datacenter '$NEW_DATACENTER' successfully."
fi


# Loop through each folder
for folder in "${FOLDERS[@]}"; do
    # Check if the folder already exists
    existing_folder=$(govc ls /$NEW_DATACENTER/vm | grep -E "$folder$" || true)
    if [ -n "$existing_folder" ]; then
	echo "Folder '$folder' already exists in datacenter '$NEW_DATACENTER'."
    else    
	# Create the folder
	govc folder.create /$NEW_DATACENTER/vm/$folder
	echo "Folder '$folder' created in datacenter '$NEW_DATACENTER' successfully."
    fi
done


# Create resource pools
resource_pools=("rpool_1" "rpool_2" "rpool_3" "rpool_4")
for pool in "${resource_pools[@]}"; do
	existing_pool=$(govc ls /$NEW_DATACENTER/host/$ESXI_HOST/Resources/$pool | grep -E "$pool$" || true)
    if [ -n "$existing_pool" ]; then
	echo "Pool '$pool' already exists in datacenter '$NEW_DATACENTER'."
    else
	    echo "elsa"
	govc pool.create -dc=$NEW_DATACENTER -cpu.expandable=true -cpu.reservation=0 -cpu.shares=high -mem.expandable=true -mem.reservation=0 -mem.shares=high /$NEW_DATACENTER/host/$ESXI_HOST/Resources/$pool
	echo "Pool '$pool' created in datacenter '$NEW_DATACENTER' successfully."
    fi
done

echo "COMPLETE"
