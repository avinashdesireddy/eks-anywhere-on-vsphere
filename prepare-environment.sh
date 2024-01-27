#!/bin/sh
set -eux

# redirect stdout/stderr to a file
exec >setup.log 2>&1

# Install Packages
install_packages() {
    echo "Installing packages..."
    sudo apt update -y
    sudo apt install -y \
        genisoimage \
        qemu-system-x86 \
        libvirt-dev \
        libvirt-clients \
        virt-manager \
        awscli

    # Install govc
    curl -L -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | sudo tar -C /usr/local/bin -xvzf - govc
}

# Download VMware vSphere 8 & vCenter Server Appliance
download_installer() {
    # Get S3 bucket name starts with workshop
    local bucket_name=$(aws s3 ls | grep workshop | awk '{print $3}')
    # Download ISO files from bucket locally

    aws s3 cp s3://$bucket_name/ . --recursive --exclude "*"  --include "*.iso"
}

# Function to generate a random password
generate_password() {
    local length=$1
    local password=$(openssl rand -base64 $length | tr -dc '[:alnum:]!@#$%^&*()-+=' | head -c $length)
    echo $password
    return 0
}

# Create Kickstart file
create_kickstart_file() {
    local KICKSTART_FILE=$(mktemp)
    local admin_password=$1
    cat > ${KICKSTART_FILE} <<EOF
# Accept the VMware End User License Agreement
vmaccepteula

# Set the root password for the DCUI and Tech Support Mode
rootpw ${admin_password}

# Install on the first local disk available on machine
install --firstdisk --overwritevmfs

# Set the network to DHCP on the first network adapter
network --bootproto=dhcp --device=vmnic0

reboot

###############################
## Scripted Install - Part 2 ##
###############################
# Use busybox interpreter
%firstboot --interpreter=busybox

# Disable IPv6
esxcli network ip set --ipv6-enabled=false

# Enable SSH
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh

# Enable and start ESXi Shell
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

# Enable NTP
echo "server 0.au.pool.ntp.org" >> /etc/ntp.conf;
echo "server 1.au.pool.ntp.org" >> /etc/ntp.conf;
/sbin/chkconfig ntpd on;

# Reboot to apply settings (disabling IPv6)
esxcli system shutdown reboot -d 15 -r "rebooting after disabling IPv6"
EOF
    echo ${KICKSTART_FILE}
}


# Create ESXI 
create_esxi() {
    local vmvisor_iso=$1
    local admin_password=$2
    #local vm_disk_size=$3

    local NIC_DRIVER=vmxnet3

    TMPDIR=$(mktemp -d)

    local SOURCE_ISO_MOUNT=${TMPDIR}/source_iso
    local TARGET_ISO_MOUNT=${TMPDIR}/target_iso
    local TARGET_ISO=${TMPDIR}/esxi_ks_iso.iso
    local TARGET_ISO_NAME=esxi_ks_iso
    
    # setup kickstart file for esxi vm install
    local kickstart_file=$(create_kickstart_file $admin_password)

    # use 80% of available disk space
    disk_mount_point="/"
    available_disk_space_gb=$(df -h --output=avail "$disk_mount_point" | awk 'NR==2 {print $1}' | sed 's/G//')
    eighty_percent_available_space_gb=$(echo "$available_disk_space_gb * 0.8" | bc)
    vm_disk_size=1024 #$eighty_percent_available_space_gb

    mkdir -p ${SOURCE_ISO_MOUNT}
    mkdir -p ${TARGET_ISO_MOUNT}

    if [ $(df --output=fstype ${SOURCE_ISO_MOUNT}| tail -n1) != "iso9660" ]; then
        sudo mount -o loop ${vmvisor_iso} ${SOURCE_ISO_MOUNT}
    fi

    rsync -av ${SOURCE_ISO_MOUNT}/ ${TARGET_ISO_MOUNT}
    sleep 1
    sudo umount ${SOURCE_ISO_MOUNT}

    # Copy Kickstart file to target ISO Mount Location
    sudo cp ${kickstart_file} ${TARGET_ISO_MOUNT}/ks_cust.cfg
    sudo sed -i s,timeout=5,timeout=1, ${TARGET_ISO_MOUNT}/boot.cfg
    sudo sed -i 's,\(kernelopt=.*\),\1 ks=cdrom:/KS_CUST.CFG,' ${TARGET_ISO_MOUNT}/boot.cfg
    sudo sed -i 's,\(kernelopt=.*\),\1 ks=cdrom:/KS_CUST.CFG,' ${TARGET_ISO_MOUNT}/efi/boot/boot.cfg
    sudo sed -i 's,TIMEOUT 80,TIMEOUT 1,' ${TARGET_ISO_MOUNT}/isolinux.cfg

    # Create ISO file from Target ISO Mount
    sudo genisoimage -relaxed-filenames -J -R -o ${TARGET_ISO} -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot ${TARGET_ISO_MOUNT}
    
    # setup libvirt
    # Install and configure KVM
    #sudo apt install qemu-system-x86 qemu-kvm qemu libvirt-dev libvirt-clients virt-manager virtinst bridge-utils cpu-checker virt-viewer -y
    #sudo kvm-ok
    sudo echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf
    sudo echo 'namespaces = []' | sudo tee -a /etc/libvirt/qemu.conf
    sudo echo 'unix_sock_group = "libvirt"' | sudo tee -a /etc/libvirt/libvirtd.conf
    sudo systemctl restart libvirtd
    sudo cat /etc/group | grep libvirt | awk -F':' {'print $1'} | xargs -n1 sudo adduser $USER
    sudo adduser $USER kvm
    export LIBVIRT_DEFAULT_URI=qemu:///system

    sudo mv ${TARGET_ISO} /var/lib/libvirt/images/
    
    # Check if domain exists
    if sudo virsh list --all | grep -q ${domain_name}; then
        echo "Domain ${domain_name} already exists."
        echo $domain_name
    else
        echo "Started Deployment, this may take few minutes..."
        sudo virt-install --connect qemu:///system \
            --name ${domain_name} \
            --ram 170000 \
            --vcpus=40 \
            --cpu host-passthrough \
            --disk path=/var/lib/libvirt/images/${TARGET_ISO_NAME}.qcow2,size=${vm_disk_size},sparse=true,bus=sata,format=qcow2 \
            --disk pool=default,size=4,sparse=true,bus=sata,format=qcow2 \
            --cdrom /var/lib/libvirt/images/${TARGET_ISO_NAME}.iso --osinfo detect=on,require=off \
            --accelerate --network=network:default,model=${NIC_DRIVER} \
            --hvm --graphics vnc,listen=0.0.0.0 \
            --boot uefi \
            --virt-type=kvm #--debug
        
        echo "ESXI Deployment Success..."
        echo $domain_name
    fi
    
}

# Function to get the IP address of a virsh domain
get_ip_address() {
	local domain_name="$1"
	# Get the network interface information for the domain
	interface_info=$(sudo virsh domifaddr "$domain_name" | grep -E 'ipv[4|6]' | awk '{print $4}')

	# Extract and print the IP address
	ip_address=$(echo "$interface_info" | cut -d'/' -f1)
	echo "$ip_address"
}

setup_vcsa() {
    #$domain_ip $domain_user $admin_password 
    local vmvisor_iso=$1
    local domain_ip=$2
    local domain_user=$3
    local admin_password=$4

    local appliance_name="vcsa-instance"
    local appliance_ip="192.168.122.22"

    vcsa_template_file=$(mktemp)
cat > $vcsa_template_file <<EOF
{
    "__version": "2.13.0",
    "__comments": "Sample template to deploy a vCenter Server Appliance with an embedded Platform Services Controller as a replication partner to another embedded vCenter Server Appliance, on an ESXi host.",
    "new_vcsa": {
        "esxi": {
            "hostname": "${domain_ip}",
            "username": "${domain_user}",
            "password": "${admin_password}",
            "deployment_network": "VM Network",
            "datastore": "datastore1"
        },
        "appliance": {
            "__comments": [
                "You must provide the 'deployment_option' key with a value, which will affect the VCSA's configuration parameters, such as the VCSA's number of vCPUs, the memory size, the storage size, and the maximum numbers of ESXi hosts and VMs which can be managed. For a list of acceptable values, run the supported deployment sizes help, i.e. vcsa-deploy --supported-deployment-sizes"
            ],
            "thin_disk_mode": true,
            "deployment_option": "small",
            "name": "${appliance_name}"
        },
        "network": {
            "ip_family": "ipv4",
            "mode": "static",
            "ip": "${appliance_ip}",
            "prefix": "24",
            "gateway": "192.168.122.1",
            "dns_servers": [
                "8.8.8.8"
            ]
        },
        "os": {
            "password": "${admin_password}",
            "ntp_servers": "0.au.pool.ntp.org",
            "ssh_enable": true
        },
        "sso": {
            "password": "${admin_password}",
            "sso_port": 443,
	        "domain_name": "vsphere.local"
        }
    },
    "ceip": {
        "description": {
            "__comments": [
                "++++VMware Customer Experience Improvement Program (CEIP)++++",
                "VMware's Customer Experience Improvement Program (CEIP) ",
                "provides VMware with information that enables VMware to ",
                "improve its products and services, to fix problems, ",
                "and to advise you on how best to deploy and use our ",
                "products. As part of CEIP, VMware collects technical ",
                "information about your organization's use of VMware ",
                "products and services on a regular basis in association ",
                "with your organization's VMware license key(s). This ",
                "information does not personally identify any individual. ",
                "",
                "Additional information regarding the data collected ",
                "through CEIP and the purposes for which it is used by ",
                "VMware is set forth in the Trust & Assurance Center at ",
                "http://www.vmware.com/trustvmware/ceip.html . If you ",
                "prefer not to participate in VMware's CEIP for this ",
                "product, you should disable CEIP by setting ",
                "'ceip_enabled': false. You may join or leave VMware's ",
                "CEIP for this product at any time. Please confirm your ",
                "acknowledgement by passing in the parameter ",
                "--acknowledge-ceip in the command line.",
                "++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++"
            ]
        },
        "settings": {
            "ceip_enabled": true
        }
    }
}
EOF

    mount_point="/mnt"

    # Check if the mount point is a mount point
    if mountpoint -q "$mount_point"; then
        echo "ISO file is already mounted at $mount_point."
    else
        # If not mounted, then mount it
        sudo mount -o loop "$vmvisor_iso" "$mount_point"
        echo "ISO file mounted at $mount_point."
    fi

    VCSA_DEPLOY_BIN=/mnt/vcsa-cli-installer/lin64/vcsa-deploy
    sudo $VCSA_DEPLOY_BIN install --accept-eula --acknowledge-ceip --no-ssl-certificate-verification ${vcsa_template_file}
    echo "Appliance ${appliance_name} is ready, you can now connect to it from your instance..."

    # Print exports
    echo "export GOVC_URL=https://${appliance_ip}"
    echo "export GOVC_HOST=${appliance_ip}"
    echo "export GOVC_USERNAME=Administrator@vsphere.local"
    echo "export GOVC_PASSWORD=${admin_password}"
    echo "export GOVC_INSECURE=1"
    echo "export ESXI_HOST=${domain_ip}"
    echo "export ESXI_USERNAME=root"
    echo "export ESXI_PASSWORD=${admin_password}"
    echo "export DATACENTER=eks_workshop"

cat << EOF > $EXPORTS_FILE
    # Export environment variables above without print
    export GOVC_HOST=${appliance_ip}
    export GOVC_URL=https://${appliance_ip}
    export GOVC_USERNAME=Administrator@vsphere.local
    export GOVC_PASSWORD=${admin_password}
    export GOVC_INSECURE=1
    export ESXI_HOST=${domain_ip}
    export ESXI_USERNAME=root
    export ESXI_PASSWORD=${admin_password}
    export DATACENTER=eksa_workshop
EOF
    sleep 5s
    . $EXPORTS_FILE
    # Check if the datacenter already exists
    existing_datacenter=$(govc ls / | grep -E "$DATACENTER$" || true)
    if [ -n "$existing_datacenter" ]; then
        echo "Datacenter '$DATACENTER' already exists."
    else
        # Create the datacenter
        govc datacenter.create $DATACENTER
        echo "Datacenter '$DATACENTER' created successfully."
    fi

    # Check if the ESXi host already exists in the datacenter
    existing_host=$(govc ls /$DATACENTER/host | grep -E "$ESXI_HOST$" || true)
    if [ -n "$existing_host" ]; then
        echo "ESXi host '$ESXI_HOST' already exists in datacenter '$DATACENTER'."
    else
        # Add the ESXi host to the datacenter
        govc host.add -dc=$DATACENTER -hostname $ESXI_HOST -username $ESXI_USERNAME -password $ESXI_PASSWORD -noverify
        echo "ESXi host '$ESXI_HOST' added to datacenter '$DATACENTER' successfully."
    fi
}

##################################################
###################### MAIN ######################
##################################################

# Read arguments from command line
EXPORTS_FILE=~/.vcenterconfig
echo "ESXi & VCenter Installation is still in progress..." > $EXPORTS_FILE

# Install packages
install_packages

# Download VMware vSphere 8 & vCenter Server Appliance
download_installer

# Use find and grep to obtain the filename matching the specified pattern
vmvisor_iso=$(find "." -type f -name "VMware-VMvisor-Installer*iso")
vcsa_iso=$(find "." -type f -name "VMware-VCSA-all-*iso")

# generate admin password
admin_password='Admin@123' #$(generate_password 10)
domain_name='esxi-vm'

# Create esxi vm
create_esxi $vmvisor_iso $admin_password
echo "ESXi VM created successfully."

sleep 600

echo "Starting VCSA setup"
#############################################

domain_ip=$(get_ip_address $domain_name)
setup_vcsa $vcsa_iso $domain_ip "root" $admin_password
