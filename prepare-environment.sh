#!/bin/sh
set -eux

# Function to display usage information
usage() {
    echo "Usage: $0 -i ESXi.iso [-k kickstart_file]"
    exit 1
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
    cat > ${KICKSTART_FILE} <<EOF
# Accept the VMware End User License Agreement
vmaccepteula

# Set the root password for the DCUI and Tech Support Mode
rootpw $(generate_password 10)

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

# Install Packages
install_packages() {
    echo "Installing packages..."
    sudo apt update -y
    sudo apt install -y \
        genisoimage \
        qemu-system-x86 \
        libvirt-dev \
        libvirt-clients

    # Install govc
    curl -L -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | sudo tar -C /usr/local/bin -xvzf - govc
}

# Create ESXI 
create_esxi() {
    local installer_iso=$1
    local kickstart_file=$2
    local vm_disk_size=$3

    local NIC_DRIVER=vmxnet3

    TMPDIR=$(mktemp -d)

    local SOURCE_ISO_MOUNT=${TMPDIR}/source_iso
    local TARGET_ISO_MOUNT=${TMPDIR}/target_iso
    local TARGET_ISO=${TMPDIR}/esxi_ks_iso.iso
    local TARGET_ISO_NAME=esxi_ks_iso

    mkdir -p ${SOURCE_ISO_MOUNT}
    mkdir -p ${TARGET_ISO_MOUNT}

    if [ $(df --output=fstype ${SOURCE_ISO_MOUNT}| tail -n1) != "iso9660" ]; then
        sudo mount -o loop ${installer_iso} ${SOURCE_ISO_MOUNT}
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
    sudo mv ${TARGET_ISO} /var/lib/libvirt/images/
    
    echo "Started Deployment, this may take few minutes..."
    sudo virt-install --connect qemu:///system \
            --name esxi-host \
            --ram 170000 \
            --vcpus=40 \
            --cpu host-passthrough \
            --disk path=/var/lib/libvirt/images/${TARGET_ISO_NAME}.qcow2,size=${vm_disk_size},sparse=true,bus=sata,format=qcow2 \
            --disk pool=default,size=4,sparse=true,bus=sata,format=qcow2 \
            --cdrom /var/lib/libvirt/images/${TARGET_ISO_NAME}.iso --osinfo detect=on,require=off \
            --accelerate --network=network:default,model=${NIC_DRIVER} \
            --hvm --graphics vnc,listen=0.0.0.0 \
            --boot uefi \
            --virt-type=kvm
    #--debug
    
    echo "Deployment Completed"
}


# Parse command-line options
while getopts ":i:" opt; do
    case $opt in
        i)
            INSTALLER_ISO=$OPTARG
            ;;        
        \?)
            echo "Invalid option: -$OPTARG"
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument."
            usage
            ;;
    esac
done

# Check if the required option is provided
if [ -z "${INSTALLER_ISO}" ]; then
    echo "Error: ESXi ISO file not specified."
    usage
fi

# Check if the provided ISO file exists
if [ ! -f "${INSTALLER_ISO}" ]; then
    echo "${INSTALLER_ISO} is not a file."
    exit 1
fi

##################################################
###################### MAIN ######################
##################################################
install_packages
KICKSTART_FILE=$(create_kickstart_file)

disk_mount_point="/"
available_disk_space_gb=$(df -h --output=avail "$disk_mount_point" | awk 'NR==2 {print $1}' | sed 's/G//')
eighty_percent_available_space_gb=$(echo "$available_disk_space_gb * 0.8" | bc)
VM_DISK_SIZE=$eighty_percent_available_space_gb

create_esxi $INSTALLER_ISO $KICKSTART_FILE $VM_DISK_SIZE

