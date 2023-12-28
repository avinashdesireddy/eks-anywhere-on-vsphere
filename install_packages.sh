#!/bin/bash

sudo apt update -y
sudo apt install -y \
	genisoimage \
	qemu-system-x86 \
	libvirt-dev \
	libvirt-clients \


exit
sudo apt install -y \
    ubuntu-desktop \
    xrdp \
    unzip \
    curl \
    sshpass \
    jq \
    snap \
    snapd \
    cloud-image-utils \
    docker.io \
    gcc g++ linux-headers-$(uname -r) make \
    linux-headers-$(uname -r)

# Install AWS CLI
sudo curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
sudo unzip awscliv2.zip
sudo ./aws/install


