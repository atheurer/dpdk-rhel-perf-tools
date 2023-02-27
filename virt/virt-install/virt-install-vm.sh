#!/bin/bash

function exit_error() {
	echo "$1"
	exit 1
}

function usage() {
	echo ""
	echo "usage:"
	echo "virt-add-vhustuser <vm-name> [virtio-net driver options]"
	echo ""
	exit
}

if [ -z $1 ]; then
	error_exit "You must provide a VM name"
fi

#. /opt/virt.sh || exit_error "This script needs to source /opt/virt.sh for configuration"

vm_name=$1
shift
#defaults
bridge=br0
image_name=$vm_name
image_path=/dev/vg00/
dist=f36
declare -A install_src
install_src[rhel74]="http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.4/Server/x86_64/os/"
install_src[rhel75]="http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.5/Server/x86_64/os/"
install_src[rhel76]="http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.6/Server/x86_64/os/"
install_src[rhel77]="http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.7/Server/x86_64/os/"
install_src[rhel79]="http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.9/Server/x86_64/os/"
install_src[rhel8]="http://download.eng.bos.redhat.com/released/RHEL-8/8.0.0/BaseOS/x86_64/os/"
install_src[rhel81]="http://download.eng.bos.redhat.com/released/RHEL-8/8.1.0/BaseOS/x86_64/os/"
install_src[rhel82]="http://download.eng.bos.redhat.com/released/RHEL-8/8.2.0/BaseOS/x86_64/os/"
install_src[rhel83]="http://download.eng.bos.redhat.com/released/RHEL-8/8.3.0-Beta-1/BaseOS/x86_64/os/"
install_src[f22]="http://download.eng.bos.redhat.com/released/F-22/GOLD/Server/x86_64/os/"
install_src[f23]="http://download.eng.bos.redhat.com/released/F-23/GOLD/Server/x86_64/os/"
install_src[f24]="http://download.eng.bos.redhat.com/released/F-24/GOLD/Server/x86_64/os/"
install_src[f25]="http://download.eng.bos.redhat.com/released/F-25/GOLD/Server/x86_64/os/"
install_src[f26]="http://download.eng.bos.redhat.com/released/F-26/GOLD/Server/x86_64/os/"
install_src[f29]="http://download.eng.bos.redhat.com/released/fedora/F-29/GOLD/Server/x86_64/os/"
install_src[f30]="http://download.eng.bos.redhat.com/released/fedora/F-30/GOLD/Server/x86_64/os/"
install_src[f32]="http://download.eng.bos.redhat.com/released/fedora/F-32/GOLD/Server/x86_64/os/"
#install_src[f33]="http://download.eng.bos.redhat.com/released/fedora/F-33/GOLD/Server/x86_64/os/"
install_src[f33]="http://fedora.mirror.constant.com/fedora/linux/releases/34/Server/x86_64/os/"
install_src[f34]="http://download.eng.bos.redhat.com/released/fedora/F-34/GOLD/Server/x86_64/os/"
#install_src[f35]="http://download.eng.bos.redhat.com/released/fedora/F-35/GOLD/Server/x86_64/os/"
install_src[f35]="http://fedora.mirror.constant.com/fedora/linux/releases/35/Server/x86_64/os/"
install_src[f36]="http://fedora.mirror.constant.com/fedora/linux/releases/36/Server/x86_64/os/"
install_src[stream8]="http://mirror.centos.org/centos/8-stream/BaseOS/x86_64/os/"

# Process options and arguments
opts=$(getopt -q -o h: --longoptions "help,bridge:,dist:" -n "getopt.sh" -- "$@")
if [ $? -ne 0 ]; then
	printf -- "$*\n"
	printf "\n"
	printf "\t${benchmark}: you specified an invalid option\n\n"
	usage
	exit 1
fi
eval set -- "$opts"
while true; do
	case "$1" in
		--help|-h)
		usage
		exit
		;;
		--dist)
		shift
		if [ -n "$1" ]; then
			dist="$1"
			shift
		fi
		;;
		--bridge)
		shift
		if [ -n "$1" ]; then
			bridge="$1"
			shift
		fi
		;;
		--)
		shift
		break
		;;
		*)
		error_exit "[$script_name] bad option, \"$1 $2\""
		;;
	esac
done

echo "install_src: ${install_src[$dist]}"

extra="inst.repo=${install_src[$dist]} inst.neednet=1 inst.text inst.ks=file:/$dist-vm.ks console=ttyS0,115200"
#/root/shutdown-all-vms
echo creating new disk image
mkdir -p /opt/images
lvcreate -a y --size 200G --name $image_name vg00
#qemu-img create -f qcow2 $image_path/$image_name 200G
#qemu-img create -f qcow2 $image_path/$image_name 40G
#dd if=/dev/zero of=$image_path/$image_name bs=1M count=20480
if virsh list --all --name | grep -e \^$vm_name\?; then
	virsh undefine $vm_name
fi
rm -rf /var/log/libvirt/qemu/$vm_name.console
echo calling virt-install
virt-install --name=$vm_name\
	 --debug\
	 --cpu model=host-model\
	 --virt-type=kvm\
	 --disk path=$image_path/$image_name,format=raw\
	 --memory=16384\
	 --network bridge=$bridge\
	 --os-type=linux\
	 --os-variant=fedora35\
	 --graphics none\
	 --extra-args="$extra"\
	 --initrd-inject=/root/virt-install/$dist-vm.ks\
	 --serial pty\
	 --serial file,path=/var/log/libvirt/qemu/$vm_name.console\
	 --location=${install_src[$dist]}\
	 --vcpus=32,sockets=1,cores=32,threads=1\
	 --noreboot || exit_error "virt-install failed"

# ensure that VM memory is backed by 1GB pages
#EDITOR='sed -i "s/<memoryBacking>/<memoryBacking><access mode=\"shared\"\/>/"' virsh edit vm1
