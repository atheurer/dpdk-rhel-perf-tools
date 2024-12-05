#!/bin/bash

#defaults
cpu_usage_file="/var/log/isolated_cpu_usage.conf"
node=-1
use_ht="n"
nrvcpus=3

function exit_error() {
	local error_message=$1
	local error_code=$2
	if [ -z "$error_code"] ; then
		error_code=1
	fi
	echo "ERROR: $error_message"
	exit $error_code
}

function log_cpu_usage() {
	# $1 = list of cpus, no spaces: 1,2,3
	local cpulist=$1
	local usage=$2
	if [ "$usage" == "" ]; then
		exit_error "a string describing the usage must accompany the cpu list"
	fi
	for cpu in `echo $cpulist | sed -e 's/,/ /g'`; do
		sed -i -e s/^$cpu:$/$cpu:$usage/ $cpu_usage_file || exit_error "cpu $cpu is already used or not an isolated cpu"
	done
}

function get_free_cpus {
	local line
	local cpu
	local usage
	local free_cpus
	while read line; do
		cpu=`echo $line | awk -F: '{print $1}'`
		usage=`echo $line | awk -F: '{print $2}'`
		if [ "$usage" == "" ]; then
			free_cpus="$free_cpus,$cpu"
		fi
	done < $cpu_usage_file
	free_cpus=`echo $free_cpus | sed -e s/^,//`
	echo $free_cpus
}

function usage() {
	echo ""
	echo "usage:"
	echo "virt-pin <vm-name> [pin options]"
	echo ""
	echo "--node=[0-9]*          the host node ID to use"
	echo "--nrvcpus=[0-9]*       number of vcpus to assign"
	echo "--use-ht               assigns pairs of vCPUs to host sibling CPU-threads"
	exit
}

function convert_number_range() {
	# converts a range of cpus, like "1-3,5" to a list, like "1,2,3,5"
	local cpu_range=$1
	local cpus_list=""
	local cpus=""
	for cpus in `echo "$cpu_range" | sed -e 's/,/ /g'`; do
		if echo "$cpus" | grep -q -- "-"; then
			cpus=`echo $cpus | sed -e 's/-/ /'`
			cpus=`seq $cpus | sed -e 's/ /,/g'`
		fi
		for cpu in $cpus; do
			cpus_list="$cpus_list,$cpu"
		done
	done
	cpus_list=`echo $cpus_list | sed -e 's/^,//'`
	echo "$cpus_list"
}

function intersect_cpus() {
	local cpus_a=$1
	local cpus_b=$2
	local cpu_set_a
	local cpu_set_b
	local intersect_cpu_list=""
	# for easier manipulation, convert the cpu list strings to a associative array
	for i in `echo $cpus_a | sed -e 's/,/ /g'`; do
		cpu_set_a["$i"]=1
	done
	for i in `echo $cpus_b | sed -e 's/,/ /g'`; do
		cpu_set_b["$i"]=1
	done
	for cpu in "${!cpu_set_a[@]}"; do
		if [ "${cpu_set_b[$cpu]}" != "" ]; then
			intersect_cpu_list="$intersect_cpu_list,$cpu"
		fi
	done
	intersect_cpu_list=`echo $intersect_cpu_list | sed -e s/^,//`
	echo "$intersect_cpu_list"
}

function subtract_cpus() {
	local current_cpus=$1
	local sub_cpus=$2
	local current_cpus_set
	local count
	local sub_cpu_list=""
	# for easier manipulation, convert the current_cpus string to a associative array
	for i in `echo $current_cpus | sed -e 's/,/ /g'`; do
		current_cpus_set["$i"]=1
	done
	for cpu in "${!current_cpus_set[@]}"; do
		for sub_cpu in `echo $sub_cpus | sed -e 's/,/ /g'`; do
			if [ "$sub_cpu" == "$cpu" ]; then
				unset current_cpus_set[$sub_cpu]
				break
			fi
		done
	done
	for cpu in "${!current_cpus_set[@]}"; do
		sub_cpu_list="$sub_cpu_list,$cpu"
	done
	sub_cpu_list=`echo $sub_cpu_list | sed -e 's/^,//'`
	echo "$sub_cpu_list"
}

function get_vcpus() {
	local avail_cpus=$1
	local nr_vcpus=$2
	local avail_cpus_set
	local count
	local vcpu_list=""
	# for easier manipulation, convert the avail_cpus string to a associative array
	for i in `echo $avail_cpus | sed -e 's/,/ /g'`; do
		avail_cpus_set["$i"]=1
	done
	set -x
	if [ "$use_ht" == "n" ]; then
		# when using 1 thread per core (higher per-PMD-thread throughput)
		count=0
		for cpu in "${!avail_cpus_set[@]}"; do
			vcpu_list="$vcpu_list,$cpu"
			unset avail_cpus_set[$cpu]
			((count++))
			[ $count -ge $nr_vcpus ] && break
		done
	else
		# when using 2 threads per core (higher throuhgput/core)
		count=0
		for cpu in "${!avail_cpus_set[@]}"; do
			vcpu_hyperthreads=`cat /sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list`
			vcpu_hyperthreads=`convert_number_range $vcpu_hyperthreads`
			for cpu_thread in `echo $vcpu_hyperthreads | sed -e 's/,/ /g'`; do
				vcpu_list="$vcpu_list,$cpu_thread"
				unset avail_cpus_set[$cpu_thread]
				((count++))
			done
			[ $count -ge $nr_vcpus ] && break
		done
	fi
	vcpu_list=`echo $vcpu_list | sed -e 's/^,//'`
	echo "$vcpu_list"
	set +x
}

function get_cpumask() {
	local cpu_list=$1
	local pmd_cpu_mask=0
	for cpu in `echo $cpu_list | sed -e 's/,/ /'g`; do
		bc_math="$bc_math + 2^$cpu"
	done
	bc_math=`echo $bc_math | sed -e 's/\+//'`
	pmd_cpu_mask=`echo "obase=16; $bc_math" | bc`
	echo "$pmd_cpu_mask"
}
if [ -z $1 ]; then
	exit_error "You must provide a VM name"
fi
vm_name=$1
shift
if [ ! -e $cpu_usage_file ]; then
	exit_error "The file, $cpu_usage_file, is missing.  This must be created with start-vswitch.sh"
fi

# Process options and arguments
opts=$(getopt -q -o i:c:t:r:m:p:M:S:C: --longoptions "help,use-ht,node:,nrvcpus:" -n "getopt.sh" -- "$@")
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
		--node)
		shift
		if [ -n "$1" ]; then
			node=$1
			shift
		fi
		;;
		--nrvcpus)
		shift
		if [ -n "$1" ]; then
			nrvcpus=$1
			shift
		fi
		;;
		--use-ht)
		shift
		use_ht="y"
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

if [ $node -lt 0 ]; then
	exit_error "you must specify a host node ID to use"
fi

virsh list --name --all | grep -q -E \^$vm_name\$ || exit_error "The VM $vm_name could not be found.  You must create with virt-install-vm.sh first"
virsh numatune $vm_name --mode=strict --nodeset=$node
all_cpus_range=`cat /sys/devices/system/cpu/online`
all_cpus_list=`convert_number_range $all_cpus_range`
node_cpus_range=`cat /sys/devices/system/node/node$node/cpulist`
# convert to a list with 1 entry per cpu and no "-" for ranges
node_cpus_list=`convert_number_range "$node_cpus_range"`
# remove the first cpu (and its sibling if present) because we want at least 1 cpu in the NUMA node
# for non-isolated work
node_first_cpu=`echo $node_cpus_list | awk -F, '{print $1}'`
node_first_cpu_threads_range=`cat /sys/devices/system/cpu/cpu$node_first_cpu/topology/thread_siblings_list`
node_first_cpu_threads_list=`convert_number_range $node_first_cpu_threads_range`
node_cpus_list=`subtract_cpus $node_cpus_list $node_first_cpu_threads_list`
free_cpus_list=`get_free_cpus`
avail_vcpus_list=`intersect_cpus $node_cpus_list $free_cpus_list`
vcpus_list=`get_vcpus "$avail_vcpus_list" "$nrvcpus"`
vcpu=0
for cpu in `echo $vcpus_list | sed -e 's/,/ /g'`; do
	virsh vcpupin $vm_name --vcpu $vcpu --cpulist $cpu --config
	let vcpu=$vcpu+1
done
