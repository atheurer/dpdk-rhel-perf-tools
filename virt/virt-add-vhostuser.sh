#!/bin/bash

function error_exit() {
	echo "$1"
	exit 1
}

function usage() {
	echo ""
	echo "usage:"
	echo "virt-add-vhustuser <vm-name> [virtio-net driver options]"
	echo ""
	echo "--mode=[client|server] default is client"
	echo "--nrq=[1-N]            the number of queues"
	echo "--rxqsz=[256-1024]     the number of descriptors in the RX queue"
	echo "--txqsz=[256-1024]     the number of descriptors in the TX queue"
	echo "--nomrg                disable mergable buffers"
	exit
}

if [ -z $1 ]; then
	error_exit "You must provide a VM name"
fi
vm_name=$1
shift
source_opts=""
driver_opts=""
host_opts=""

# Process options and arguments
opts=$(getopt -q -o i:c:t:r:m:p:M:S:C: --longoptions "help,mode:,rxqsz:,txqsz:,nomrg,nrq:" -n "getopt.sh" -- "$@")
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
		--help)
		usage
		exit
		;;
		--mode)
		shift
		if [ -n "$1" ]; then
			source_opts="$source_opts mode='$1'"
			shift
		fi
		;;
		--nrq)
		shift
		if [ -n "$1" ]; then
			driver_opts="$driver_opts queues='$1'"
			shift
		fi
		;;
		--rxqsz)
		shift
		if [ -n "$1" ]; then
			driver_opts="$driver_opts rx_queue_size='$1'"
			shift
		fi
		;;
		--txqsz)
		shift
		if [ -n "$1" ]; then
			driver_opts="$driver_opts tx_queue_size='$1'"
			shift
		fi
		;;
		--nomrg)
		shift
		host_opts="$host_opts mrg_rxbuf='off'"
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


echo "vm_name is $vm_name"

virsh list --name --all | grep -q -E \^$vm_name\$ || error_exit "$vm_name could not be found"

vhu_count=`virsh domiflist $vm_name | grep -c vhostuser`
echo $source_opts | grep -q "mode=" || source_opts="$source_opts mode='client'"

echo  "<interface type='vhostuser'>\
         <source type='unix' path='/var/run/openvswitch/vhost-user-$vhu_count' $source_opts/>\
         <model type='virtio'/>\
         <driver name='vhost' $driver_opts>\
             <host $host_opts />\
         </driver>\
       </interface>" >/tmp/vhu.xml

virsh attach-device $vm_name /tmp/vhu.xml --config
