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
KICKSTART_FILE=$2

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
sudo chmod 644 /var/lib/libvirt/images/new.iso

# Install VM using Target ISO
NIC_DRIVER=vmxnet3
DISK_SIZE=1024

echo "Started Deployment, this may take few minutes..."
virt-install --connect qemu:///system \
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

