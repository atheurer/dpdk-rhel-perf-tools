#!/bin/bash

function error_exit() {
	echo "$1"
	exit 1
}

if [ -z $1 ]; then
	error_exit "You must provide a VM name"
fi
vm_name=$1

virsh list --name --all | grep -q -E \^$vm_name\$ || error_exit "$vm_name could not be found"
virsh domiflist $vm_name | grep -q vhostuser || error_exit "$vm_name did not have any vhostuser devices"
for vhu_mac in `virsh domiflist $vm_name | grep vhostuser | awk '{print $5}'`; do
	echo "detaching $vhu_mac"
	virsh detach-interface $vm_name vhostuser --mac $vhu_mac --config
done
