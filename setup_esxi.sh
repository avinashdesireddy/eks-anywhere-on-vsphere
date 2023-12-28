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

set -eux

## Parse arguments
SOURCE_ISO=$1
KICKSTART_FILE=$(mktemp)
ADMIN_PASSWORD=myp@ssw0rd

validate_password() {
    local password=$1

    # Check minimum length
    if [ ${#password} -lt 8 ]; then
        echo "Password must be at least 8 characters long."
        return 1
    fi

    # Check for at least one uppercase letter
    if ! [[ "$password" =~ [[:upper:]] ]]; then
        echo "Password must contain at least one uppercase letter."
        return 1
    fi

    # Check for at least one lowercase letter
    if ! [[ "$password" =~ [[:lower:]] ]]; then
        echo "Password must contain at least one lowercase letter."
        return 1
    fi

    # Check for at least one digit
    if ! [[ "$password" =~ [0-9] ]]; then
        echo "Password must contain at least one digit."
        return 1
    fi

    # Check for at least one special character
    if ! [[ "$password" =~ [!@#\$%^&*()-+=] ]]; then
        echo "Password must contain at least one special character (!@#\$%^&*()-+=)."
        return 1
    fi

    # If all checks pass, the password is valid
    echo "Password is valid."
    return 0
}


cat > ${KICKSTART_FILE} <<EOF
# Accept the VMware End User License Agreement
vmaccepteula

# Set the root password for the DCUI and Tech Support Mode
rootpw ${ADMIN_PASSWORD}

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

# Set environment variables
## We use the label of the ISO image
VERSION=$(file -b ${ESXI_ISO}| cut -d"'" -f2|sed 's,ESXI-\(.*\),\1,')
BASE_DIR=$(pwd)
TMPDIR=$(mktemp -d)

SOURCE_ISO_MOUNT=${TMPDIR}/source_iso
TARGET_ISO_MOUNT=${TMPDIR}/target_iso
TARGET_ISO=${TMPDIR}/esxi_ks_iso.iso
TARGET_ISO_NAME=esxi_ks_iso

mkdir -p ${SOURCE_ISO_MOUNT}
mkdir -p ${TARGET_ISO_MOUNT}

# Mount Source ISO Image
if [[ $(df --output=fstype ${SOURCE_ISO_MOUNT}| tail -n1) != "iso9660" ]]; then
    sudo mount -o loop ${SOURCE_ISO} ${SOURCE_ISO_MOUNT}
fi

rsync -av ${SOURCE_ISO_MOUNT}/ ${TARGET_ISO_MOUNT}
sleep 1
sudo umount ${SOURCE_ISO_MOUNT}

# Copy Kickstart file to target ISO Mount Location
sudo cp ${KICKSTART_FILE} ${TARGET_ISO_MOUNT}/ks_cust.cfg
sudo sed -i s,timeout=5,timeout=1, ${TARGET_ISO_MOUNT}/boot.cfg
sudo sed -i 's,\(kernelopt=.*\),\1 ks=cdrom:/KS_CUST.CFG,' ${TARGET_ISO_MOUNT}/boot.cfg
sudo sed -i 's,\(kernelopt=.*\),\1 ks=cdrom:/KS_CUST.CFG,' ${TARGET_ISO_MOUNT}/efi/boot/boot.cfg
sudo sed -i 's,TIMEOUT 80,TIMEOUT 1,' ${TARGET_ISO_MOUNT}/isolinux.cfg

# Create ISO file from Target ISO Mount
sudo genisoimage -relaxed-filenames -J -R -o ${TARGET_ISO} -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot ${TARGET_ISO_MOUNT}


sudo mv ${TARGET_ISO} /var/lib/libvirt/images/
#sudo chmod 644 /var/lib/libvirt/images/new.iso

# Install VM using Target ISO
NIC_DRIVER=vmxnet3
DISK_SIZE=800

echo "Started Deployment, this may take few minutes..."
sudo virt-install --connect qemu:///system \
        --name esxi-host \
        --ram 170000 \
        --vcpus=40 \
        --cpu host-passthrough \
        --disk path=/var/lib/libvirt/images/${TARGET_ISO_NAME}.qcow2,size=${DISK_SIZE},sparse=true,bus=sata,format=qcow2 \
        --disk pool=default,size=4,sparse=true,bus=sata,format=qcow2 \
        --cdrom /var/lib/libvirt/images/${TARGET_ISO_NAME}.iso --osinfo detect=on,require=off \
        --accelerate --network=network:default,model=${NIC_DRIVER} \
        --hvm --graphics vnc,listen=0.0.0.0 \
        --boot uefi \
        --virt-type=kvm \
        --debug

sleep 180

echo "ESXi Host is ready, you can now connect to it from your instance..."
#socat TCP-LISTEN:443,fork TCP:192.168.122.3:443

