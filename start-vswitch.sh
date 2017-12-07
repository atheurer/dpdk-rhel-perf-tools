#!/bin/bash

# This script will start a vswitch of your choice, doing the following:
# -use multi-queue (for DPDK)
# -bind DPDK PMDs to optimal CPUs
# -for pvp topologies, provide a list of optimal cpus available for the VM
# configure a network overlay, like VxLAN

# The following features are not implemented but would be nice to add:
# -for ovs, configure x flows
# -for a router, configure x routes
# -configure VLAN
# -configure a firewall

# defaults
topology="pp" # two physical devices on one switch
	      # topology is desctibed by a list of 1 or more switches separated by commas
	      # the supported interfaces on a switch are:
	      # p: a physical port
	      # v: a virtio-net "backend" port, like dpdkvhostuser or vhost-net (dependig on dataplane)
	      # V: a virtio-net "frontend" port, like virtio-pci in a VM (not yet implemented)
	      # P: a patch-port for OVS (not yet implemented)
queues=1 # queues: Number of queue-pairs (rx/tx) to use per device
switch="ovs" # switch: Currently supported is: testpmd, ovs, linuxbridge, linuxrouter, vpp
switch_mode="default" # switch_mode: Currently supported list depends on $switch
numa_mode="strict" # numa_mode: (for DPDK vswitches only)
			# strict:    All PMD threads for all phys and virt devices use memory and cpu only
			#            from the numa node where the physical adapters are located.
			#	     This implies the VMs must be on the same node.
			# preferred: Just like 'strict', but the vswitch also has memory and in some cases
			#            uses cpu from the non-local NUMA nodes.
			# cross:     The PMD threads for all phys devices use memory and cpu from
			#            the local NUMA node, but VMs are present on another NUMA node,
			#            and so the PMD threads for those virt devices are also on
			#            another NUMA node.
overlay="none" # overlay: Currently supported is: none (for all switch types) and vxlan (for linuxbridge and ovs)
prefix="" # prefix: the path prepended to the calls to operate ovs.  use "" for ovs RPM and "/usr/local" for src built OVS
dpdk_nic_kmod="vfio-pci" # dpdk-devbind: the kernel module to use when assigning a network device to a userspace program (DPDK application)
dataplane="dpdk"
use_ht="y"
testpmd_ver="v17.05"
testpmd_path="/opt/dpdk/build/${testpmd_ver}/bin/testpmd"
supported_switches="linuxbridge ovs linuxrouter vpp testpmd"
pci_descriptors=2048 # use this as our default descriptor size
pci_desc_override="" # use to override the desriptor size of any of the vswitches here.  
vhu_desc_override="" # use to override the desriptor size of any of the vswitches here.  
vpp_version="17.04"
cpu_usage_file="/var/log/isolated_cpu_usage.conf"
vhost_affinity="local" ## this is not working yet # local: the vhost interface will reside in the same node as the physical interface on the same bridge
		       # remote: The vhost interface will reside in remote node as the physicak interface on the same bridge
		       # this locality is an assumption and must match what was configured when VMs are created

function init_cpu_usage_file() {
	local opt
	local var
	local val
	local cpu
	local non_iso_cpu_bitmask
	local non_iso_cpu_hexmask
	local non_iso_cpu_list
	local online_cpu_range
	local online_cpu_list
	local iso_cpu_list
	local iso_cpus
	/bin/rm -f $cpu_usage_file
	touch $cpu_usage_file
	iso_cpus=$(cat /sys/devices/system/cpu/isolated)
	if [ -n "${iso_cpus}" ]; then
		iso_cpu_list=$(convert_number_range "${iso_cpus}")
	else
		for opt in `cat /proc/cmdline`; do
			var=`echo $opt | awk -F= '{print $1}'`
			if [ $var == "tuned.non_isolcpus" ]; then
				val=`echo $opt | awk -F= '{print $2}'`
				non_iso_cpu_hexmask=`echo "$val" | sed -e s/,//g | tr a-f A-F`
				non_iso_cpu_bitmask=`echo "ibase=16; obase=2; $non_iso_cpu_hexmask" | bc`
				non_iso_cpu_list=`convert_bitmask_to_list $non_iso_cpu_bitmask`
				online_cpu_range=`cat /sys/devices/system/cpu/online`
				online_cpu_list=`convert_number_range $online_cpu_range`
				iso_cpu_list=`sub_from_list $online_cpu_list $non_iso_cpu_list`
				break
			fi
		done
	fi
	for cpu in `echo $iso_cpu_list | sed -e 's/,/ /g'`; do
		echo "$cpu:" >>$cpu_usage_file
	done
	echo "$iso_cpu_list"
}

function get_iso_cpus() {
	local cpu
	local list
	for cpu in `grep -E "[0-9]+:$" $cpu_usage_file | awk -F: '{print $1}'`; do
		list="$list,$cpu"
	done
	list=`echo $list | sed -e 's/^,//'`
	echo "$list"
}

function log_cpu_usage() {
	# $1 = list of cpus, no spaces: 1,2,3
	local cpulist=$1
	local usage=$2
	local cpu
	if [ "$usage" == "" ]; then
		exit_error "a string describing the usage must accompany the cpu list"
	fi
	for cpu in `echo $cpulist | sed -e 's/,/ /g'`; do
		if grep -q -E "^$cpu:" $cpu_usage_file; then
			if grep -q -E "^$cpu:.+" $cpu_usage_file; then
				# $cpu is already used
				return 1
			else
				sed -i -e s/^$cpu:$/$cpu:$usage/ $cpu_usage_file
			fi
		else
			# $cpu is not in $cpu_usage_file
			return 1
		fi
	done
	return 0
}

function exit_error() {
	local error_message=$1
	local error_code=$2
	if [ -z "$error_code"] ; then
		error_code=1
	fi
	echo "ERROR: $error_message"
	exit $error_code
}

function convert_bitmask_to_list() {
	# converts a range of cpus, like "10111" to 1,2,3,5"
	local bitmask=$1
	local cpu=0
	local bit=""
	while [ "$bitmask" != "" ]; do
		bit=${bitmask: -1}
		if [ "$bit" == "1" ]; then
			cpu_list="$cpu_list,$cpu"
		fi
		bitmask=`echo $bitmask | sed -e 's/[0-1]$//'`
		((cpu++))
	done
	cpu_list=`echo $cpu_list | sed -e 's/,//'`
	echo "$cpu_list"
}

function convert_list_to_bitmask() {
	# converts a range of cpus, like "1-3,5" to a bitmask, like "10111"
	local cpu_list=$1
	local cpu=""
	local bitmask=0
	for cpu in `echo "$cpu_list" | sed -e 's/,/ /g'`; do
		bitmask=`echo "$bitmask + (2^$cpu)" | bc`
	done
	bitmask=`echo "obase=2; $bitmask | bc"`
	echo "$bitmask"
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

function node_cpus_list() {
	local node_id=$1
	local cpu_range=`cat /sys/devices/system/node/node$node_id/cpulist`
	local cpu_list=`convert_number_range $cpu_range`
	echo "$cpu_list"
}

function add_to_list() {
	local list=$1
	local add_list=$2
	local list_set
	local i
	# for easier manipulation, convert the current_elements string to a associative array
	for i in `echo $list | sed -e 's/,/ /g'`; do
		list_set["$i"]=1
	done
	list=""
	for i in `echo $add_list | sed -e 's/,/ /g'`; do
		list_set["$i"]=1
	done
	for i in "${!list_set[@]}"; do
		list="$list,$i"
	done
	list=`echo $list | sed -e 's/^,//'`
	echo "$list"
}

function sub_from_list () {
	local list=$1
	local sub_list=$2
	local list_set
	local i
	# for easier manipulation, convert the current_elements string to a associative array
	for i in `echo $list | sed -e 's/,/ /g'`; do
		list_set["$i"]=1
	done
	list=""
	for i in `echo $sub_list | sed -e 's/,/ /g'`; do
		unset list_set[$i]
	done
	for i in "${!list_set[@]}"; do
		list="$list,$i"
	done
	list=`echo $list | sed -e 's/^,//'`
	echo "$list"
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

function get_pmd_cpus() {
	local pci_devs=$1
	local nr_queues=$2
	local cpu_usage=$3
	local pmd_cpu_list=""
	local pci_dev=""
	local node_id=""
	local cpus_list=""
	local iso_cpus_list=""
	local pmd_cpus_list=""
	local queue_num=
	local count=
	local prev_cpu=""
	# for each device, get N cpus, where N = number of queues
	for pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
		if echo $pci_dev | grep -q vhost; then
			# the file name for vhostuser ends with a number matching the NUMA node
			node_id="${pci_dev: -1}"
		else
			node_id=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`
			# -1 means there is no topology, so we use node0
			if [ "$node_id" == "-1" ]; then
				node_id=0
			fi
		fi
		cpus_list=`node_cpus_list "$node_id"`
		iso_cpus_list=`get_iso_cpus`
		node_iso_cpus_list=`intersect_cpus "$cpus_list" "$iso_cpus_list"`
		if [ "$node_iso_cpus_list" == "" ]; then
			echo ""
			exit
		fi
		queue_num=0
		while [ $queue_num -lt $nr_queues ]; do
			new_cpu=""
			if [ "$use_ht" == "y" -a "$prev_cpu" != "" ]; then
				# search for sibling cpu-threads before picking next avail cpu
				cpu_siblings_range=`cat /sys/devices/system/cpu/cpu$prev_cpu/topology/thread_siblings_list`
				cpu_siblings_list=`convert_number_range $cpu_siblings_range`
				cpu_siblings_avail_list=`sub_from_list  $cpu_siblings_list $pmd_cpus_list`
				if [ "$cpu_siblings_avail_list" != "" ]; then
					# if all of the siblings are depleted, then fall back to getting a new (non-sibling) cpu
					new_cpu="`echo $cpu_siblings_avail_list | awk -F, '{print $1}'`"
				fi
			fi
			if [ "$new_cpu" == "" ]; then
				# allocate a new cpu
				new_cpu="`echo $node_iso_cpus_list | awk -F, '{print $1}'`"
			fi
			log_cpu_usage "$new_cpu" "$cpu_usage"
			if [ $? != 0 ]; then
				return 1 # something went wrong, abort
			fi
			node_iso_cpus_list=`sub_from_list "$node_iso_cpus_list" "$new_cpu"`
			set +x
			pmd_cpus_list="$pmd_cpus_list,$new_cpu"
			((queue_num++))
			((count++))
			prev_cpu=$new_cpu
		done
	done
	pmd_cpus_list=`echo $pmd_cpus_list | sed -e 's/^,//'`
	echo "$pmd_cpus_list"
	return 0
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

function set_ovs_bridge_mode() {
	local bridge=$1
	local switch_mode=$2

	case "${switch_mode}" in
		"l2-bridge")
			$prefix/bin/ovs-ofctl add-flow ${bridge} action=NORMAL
			;;
		"default"|"direct-flow-rule")
			$prefix/bin/ovs-ofctl add-flow ${bridge} "in_port=1,idle_timeout=0 actions=output:2"
			$prefix/bin/ovs-ofctl add-flow ${bridge} "in_port=2,idle_timeout=0 actions=output:1"
			;;
	esac
}

function set_vpp_bridge_mode() {
	local interface_1=$1
	local interface_2=$2
	local switch_mode=$3
	local bridge=$4

	case "${switch_mode}" in
		"l2-bridge")
			vppctl set interface l2 bridge ${interface_1} ${bridge}
			vppctl set interface l2 bridge ${interface_2} ${bridge}
			;;
		"default"|"xconnect")
			vppctl set interface l2 xconnect ${interface_1} ${interface_2}
			vppctl set interface l2 xconnect ${interface_2} ${interface_1}
			;;
	esac
}

function vpp_create_vhost_user() {
	local socket_name=/var/run/vpp/${1}
	local device_name=""

	case "${vpp_version}" in
		"17.07"|"17.10")
		device_name=$(vppctl create vhost-user socket ${socket_name} server)
		;;
		"17.04"|*)
		device_name=$(vppctl create vhost socket ${socket_name} server)
		;;
	esac

	chmod 777 ${socket_name}

	echo "${device_name}"
}

# Process options and arguments
opts=$(getopt -q -o i:c:t:r:m:p:M:S:C:o --longoptions "vhost-affinity:,numa-mode:,desc-override:,vhost_devices:,pci-devices:,devices:,nr-queues:,use-ht:,overlay:,topology:,dataplane:,switch:,switch-mode:,testpmd-path:,vpp-version:" -n "getopt.sh" -- "$@")
if [ $? -ne 0 ]; then
	printf -- "$*\n"
	printf "\n"
	printf "\t${benchmark_name}: you specified an invalid option\n\n"
	printf "\tThe following options are available:\n\n"
	#              1   2         3         4         5         6         7         8         9         0         1         2         3
	#              678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012
	printf -- "\t\t             --[pci-]devices=str,str    two PCI locations of Ethenret adapters to use, like --devices=0000:83:00.0,0000:86:00.0\n"
	printf -- "\t\t             --vhost-affinity=str       local [default]: use same numa node as PCI device\n"
	printf -- "\t\t                                        remote: use opposite numa node as PCI device\n"
	printf -- "\t\t             --nr-queues=int            the number of queues per device\n"
	printf -- "\t\t             --use-ht=[y|n]             y=use both cpu-threads on HT core, n=only use 1 cpu-thread per core\n"
	printf -- "\t\t                                        Using HT has better per/core throuhgput, but not using HT has better per-queue throughput\n"
	printf -- "\t\t             --overlay=[none|vxlan]     network overlay used, if any (not supported on all bridge types)\n"
	printf -- "\t\t             --topology=str             pp (which is just 2 physical devices on same bridge) or pvp (which is 2 bridges, each with a phys port and a virtio port)\n"
	printf -- "\t\t             --dataplane=str            dpdk or kernel\n"
	printf -- "\t\t             --desc-override            override default size for descriptor size\n"
	printf -- "\t\t             --switch=str               testpmd, ovs, vpp, linuxrouter, or linuxbridge\n"
	printf -- "\t\t             --switch-mode=str          Mode that the selected switch operates in.  Modes differ between switches\n"
	printf -- "\t\t                                        \tlinuxbridge: default\n"
	printf -- "\t\t                                        \tlinuxrouter: default\n"
	printf -- "\t\t                                        \ttestpmd:     default\n"
	printf -- "\t\t                                        \tovs:         default/direct-flow-rule, l2-bridge\n"
	printf -- "\t\t                                        \tvpp:         default/xconnect, l2-bridge\n"
	printf -- "\t\t             --testpmd-path=str         override the default location for the testpmd binary (${testpmd_path})\n"
	printf -- "\t\t             --vpp-version=str          control which VPP command set to use: 17.04, 17.07, or 17.10 (default is ${vpp_version})\n"
	exit_error ""
fi
echo opts: [$opts]
eval set -- "$opts"
echo "processing options"
while true; do
	echo \$1: [$1]
	case "$1" in
		--devices)
		shift
		if [ -n "$1" ]; then
			pci_devs="$1"
			echo pci_devs: [$pci_devs]
			shift
		fi
		;;
		--vhost-affinity)
		shift
		if [ -n "$1" ]; then
			vhost_affinity="$1"
			echo vhost_affinity: [$vhost_affinity]
			shift
		fi
		;;
		--nr-queues)
		shift
		if [ -n "$1" ]; then
			queues="$1"
			echo nr_queues: [$queues]
			shift
		fi
		;;
		--use-ht)
		shift
		if [ -n "$1" ]; then
			use_ht="$1"
			echo use_ht: [$use_ht]
			shift
		fi
		;;
		--overlay)
		shift
		if [ -n "$1" ]; then
			overlay="$1"
			echo overlay: [$overlay]
			shift
		fi
		;;
		--topology)
		shift
		if [ -n "$1" ]; then
			topology="$1"
			echo topology: [$topology]
			shift
		fi
		;;
		--dataplane)
		shift
		if [ -n "$1" ]; then
			dataplane="$1"
			echo dataplane: [$dataplane]
			shift
		fi
		;;
		--pci-desc-override)
		shift
		if [ -n "$1" ]; then
			pci_desc_override="$1"
			echo pci-desc-override: [$pci_desc_override]
			shift
		fi
		;;
		--vhu-desc-override)
		shift
		if [ -n "$1" ]; then
			vhu_desc_override="$1"
			echo vhu-desc-override: [$vhu_desc_override]
			shift
		fi
		;;
		--switch)
		shift
		if [ -n "$1" ]; then
			switch="$1"
			shift
			ok=0
			for i in $supported_switches; do
				if [ "$switch" == "$i" ]; then
					ok=1
				fi
			done
			if [ $ok -eq 1 ]; then
				echo switch: [$switch]
			else
				exit_error "switch: [$switch] is not supported by this script"
			fi
		fi
		;;
		--switch-mode)
		shift
		if [ -n "$1" ]; then
			switch_mode="$1"
			shift
			echo switch_mode: [$switch_mode]
		fi
		;;
		--testpmd-path)
		shift
		if [ -n "$1" ]; then
			testpmd_path="$1"
			shift
			if [ ! -e ${testpmd_path} -o ! -x "${testpmd_path}" ]; then
				exit_error "testpmd_path: [${testpmd_path}] does not exist or is not exexecutable"
			fi
			echo "testpmd_path: [${testpmd_path}]"
		fi
		;;
		"--vpp-version")
		shift
		if [ -n "${1}" ]; then
			vpp_version="${1}"
			shift
			echo "vpp_version: [${vpp_version}]"
		fi
		;;
		--numa-mode)
		shift
		if [ -n "$1" ]; then
			numa_mode="$1"
			shift
			echo numa_mode: [$numa_mode]
		fi
		;;
		--)
		shift
		break
		;;
		*)
		echo "[$script_name] bad option, \"$1 $2\""
		break
		;;
	esac
done

# validate switch modes
case "${switch}" in
	"linuxbridge"|"linuxrouter"|"testpmd")
		case "${switch_mode}" in
			"default")
				;;
			*)
				exit_error "switch=${switch} does not support switch_mode=${switch_mode}"
				;;
		esac
		;;
	"ovs")
		case "${switch_mode}" in
			"default"|"direct-flow-rule"|"l2-bridge")
				;;
			*)
				exit_error "switch=${switch} does not support switch_mode=${switch_mode}"
				;;
		esac
		;;
	"vpp")
		case "${switch_mode}" in
			"default"|"xconnect"|"l2-bridge")
				;;
			*)
				exit_error "switch=${switch} does not support switch_mode=${switch_mode}"
				;;
		esac
		;;
esac

# check for software dependencies
common_deps="lsof lspci bc dpdk-devbind driverctl udevadm ip screen"
linuxbridge_deps="brctl"
all_deps=""
all_deps="$common_deps"
if [ "$switch" == "linuxbridge" ]; then
	all_deps="$all_deps $linuxbridge_deps"
fi
for i in $all_deps; do
	if which $i >/dev/null 2>&1; then
		continue
	else
		exit_error "You must have the following installed to run this script: $i.  Please install first"
	fi
done

# only run if selinux is disabled
selinuxenabled && exit_error "disable selinux before using this script"

# make sure all of the pci devices used are exactly the same
pci_dev_count=0
prev_pci_desc=""
for this_pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
	pci_desc=`lspci -s $this_pci_dev | cut -d" " -f 2- | sed -s 's/ (.*$//'`
	if [ "$prev_pci_desc" != "" -a "$prev_pci_desc" != "$pci_desc" ]; then
		exit_error "PCI devices are not the exact same type: $prev_pci_desc, $pci_desc"
	fi
	prev_pci_desc="$pci_desc"
	((pci_dev_count++))
done
if [ $pci_dev_count -ne 2 ]; then
	exit_error "you must use 2 PCI devices, you used: $pci_dev_count"
fi
kernel_nic_kmod=`lspci -k -s $this_pci_dev | grep "Kernel modules:" | awk -F": " '{print $2}'`


# kill any process using the 2 PCI devices
echo Checking for an existing process using $pci_devs
for pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
	iommu_group=`readlink /sys/bus/pci/devices/$pci_dev/iommu_group | awk -Fiommu_groups/ '{print $2}'`
	pids=`lsof -n -T -X | grep -- "/dev/vfio/$iommu_group" | awk '{print $2}' | sort | uniq`
	if [ ! -z "$pids" ]; then
		echo killing PID $pids, which is using device $pci_dev
		kill $pids
	fi
done
# completely kill and remove old ovs/vpp configuration
echo "stopping ovs"
killall ovs-vswitchd
killall ovsdb-server
killall ovsdb-server ovs-vswitchd
echo "stopping vpp"
killall vpp
echo "stopping testpmd"
killall testpmd
sleep 3
rm -rf $prefix/var/run/openvswitch/ovs-vswitchd.pid
rm -rf $prefix/var/run/openvswitch/ovsdb-server.pid
rm -rf $prefix/var/run/openvswitch/*
rm -rf $prefix/etc/openvswitch/*db*
rm -rf $prefix/var/log/openvswitch/*
rm -rf $prefix/var/log/vpp/*

# initialize the devices
case $dataplane in
	dpdk)
	# keep track of cpus we can use for DPDK
	iso_cpus_list=`init_cpu_usage_file`
	# create the option for --socket-mem that DPDK apoplications use
	socket_mem=
	node_range=`cat /sys/devices/system/node/has_memory`
	node_list=`convert_number_range $node_range`
	for node in `echo $node_list | sed -e 's/,/ /g'`; do
		local_socket_mem[$node]=0
		all_socket_mem[$node]=1024
	done
	for pci_dev in `echo $pci_devs | echo $pci_devs | sed -e 's/,/ /g'`; do
		pci_dev_numa_node=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`
		if [ $pci_dev_numa_node -eq -1 ]; then
			pci_dev_numa_node=0
		fi
		echo pci device $pci_dev node is $pci_dev_numa_node
		local_socket_mem[$pci_dev_numa_node]=1024
	done
	echo local_socket_mem: ${local_socket_mem[@]}
	local_socket_mem_opt=""
	for mem in "${local_socket_mem[@]}"; do
		echo mem: $mem
		local_socket_mem_opt="$local_socket_mem_opt,$mem"
		all_socket_mem_opt="$all_socket_mem_opt,1024"
	done
	for node in "${!local_socket_mem[@]}"; do
		if [ "${local_socket_mem[$node]}" == "1024" ]; then
			local_numa_nodes="$local_numa_nodes,$node"
			local_node_cpus_list=`node_cpus_list $node`
			local_nodes_cpus_list=`add_to_list "$local_nodes_cpus_list" "$local_node_cpus_list"`
		fi
	done
	local_nodes_non_iso_cpus_list=`sub_from_list "$local_nodes_cpus_list" "$iso_cpus_list"`
	local_numa_nodes=`echo $local_numa_nodes | sed -e 's/^,//'`
	echo local_numa_nodes: $local_numa_nodes
	local_socket_mem_opt=`echo $local_socket_mem_opt | sed -e 's/^,//'`
	echo local_socket_mem_opt: $local_socket_mem_opt
	all_socket_mem_opt=`echo $all_socket_mem_opt | sed -e 's/^,//'`
	echo all_socket_mem_opt: $all_socket_mem_opt
	
	all_cpus_range=`cat /sys/devices/system/cpu/online`
	all_cpus_list=`convert_number_range $all_cpus_range`
	all_nodes_non_iso_cpus_list=`sub_from_list $all_cpus_list $iso_cpus_list`
	echo "isol cpus_list is $iso_cpus_list"
	echo "all-nodes-non-isolated cpus list is $all_nodes_non_iso_cpus_list"
	
	rmmod vfio-pci
	# load modules and bind Ethernet cards to dpdk modules
	for kmod in vfio vfio-pci; do
		if lsmod | grep -q $kmod; then
		echo "not loading $kmod (already loaded)"
	else
		if modprobe -v $kmod; then
			echo "loaded $kmod module"
		else
			exit_error "Failed to load $kmmod module, exiting"
		fi
	fi
	done

	echo DPDK adapters: $pci_devs
	# bind the devices to dpdk module
	for pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
        echo pci_dev: $pci_dev
		driverctl unset-override $pci_dev
		dpdk-devbind --unbind $pci_dev
		dpdk-devbind --bind $kernel_nic_kmod $pci_dev
		if [ -e /sys/bus/pci/devices/"$pci_dev"/net/ ]; then
			eth_dev=`/bin/ls /sys/bus/pci/devices/"$pci_dev"/net/`
			mac=`ip l show dev $eth_dev | grep link/ether | awk '{print $2}'`
			macs="$macs $mac"
			ip link set dev $eth_dev down
		fi
		dpdk-devbind --unbind $pci_dev
		dpdk-devbind --bind $dpdk_nic_kmod $pci_dev
	done
	;;
	kernel)
	# bind the devices to kernel  module
	eth_devs=""
	for pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
		driverctl unset-override $pci_dev
		dpdk-devbind --unbind $pci_dev
		dpdk-devbind --bind $kernel_nic_kmod $pci_dev
		udevadm settle
		if [ -e /sys/bus/pci/devices/"$pci_dev"/net/ ]; then
			eth_dev=`/bin/ls /sys/bus/pci/devices/"$pci_dev"/net/`
			eth_devs="$eth_devs $eth_dev"
			mac=`ip l show dev $eth_dev | grep link/ether | awk '{print $2}'`
			macs="$macs $mac"
		else
			exit_error "Could not get kernel driver to init on device $pci_dev"
		fi
	done
	echo ethernet devices: $eth_devs
	;;
esac
echo device macs: $macs

	
# configure the vSwitch
echo configuring the vswitch: $switch
case $switch in
	linuxrouter)
	case $topology in
		"pp")   # 10GbP1<-->10GbP2
		for i in `seq 0 1`; do
			subnet=`echo "$i + 100" | bc`
			router_ip="10.0.$subnet.1"
			eth_dev=`echo $eth_devs | awk '{print $1}'`
			eth_devs=`echo $eth_devs | sed -e s/$eth_dev//`
			ip l set dev $eth_dev up
			ip addr add $router_ip/24 dev $eth_dev
			echo "1" >/proc/sys/net/ipv4/ip_forward
		done
		;;
	esac
	;;
	linuxbridge)
	case $topology in
		"pp")   # 10GbP1<-->10GbP2
		phy_br="phy-br-0"
		brctl addbr $phy_br
		ip l set dev $phy_br up
		for i in `seq 0 1`; do
			eth_dev=`echo $eth_devs | awk '{print $1}'`
			eth_devs=`echo $eth_devs | sed -e s/$eth_dev//`
			ip l set dev $eth_dev up
			brctl addif $phy_br $eth_dev
		done
		;;
		pvp|pv,vp)   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
		# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
		for i in `seq 0 1`; do
			eth_dev=`echo $eth_devs | awk '{print $1}'`
			eth_devs=`echo $eth_devs | sed -e s/$eth_dev//`
			if [ "$overlay" == "vxlan" ]; then
				vxlan_br="vxlan-br-$i"
				vxlan_port="vxlan-$i"
				vni=`echo "100 + $i" | bc`
				local_ip="10.0.$vni.1"
				remote_ip="10.0.$vni.2"
				group=239.1.1.$vni
				ip addr add $local_ip/24 dev $eth_dev
				ip l set dev $eth_dev up
				ip link add $vxlan_port type vxlan id $vni group $group dstport 4789 dev $eth_dev
				ip l set dev $vxlan_port up
				brctl delbr $vxlan_br
				brctl addbr $vxlan_br
				ip l set dev $vxlan_br up
				brctl addif $vxlan_br $vxlan_port
			else # no overlay
				phy_br="phy-br-$i"
				brctl show | grep -q $phy_br &&brctl delbr $phy_br
				brctl addbr $phy_br
				ip l set dev $phy_br up
				ip l set dev $eth_dev up
				brctl addif $phy_br $eth_dev
			fi
		done
		;;
		esac
	;;
	vpp)
	vhost_devs=""
	case ${topology} in
		"pp")
		vpp_ports=2
		;;
		"pvp"|"pv,vp")
		vpp_ports=4
		for i in `seq 0 1`; do
			pci_dev_index=$(( i + 1 ))
			pci_dev=`echo ${pci_devs} | awk -F, "{ print \\$${pci_dev_index}}"`
			pci_node=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`
			if [ "$vhost_affinity" == "local" ]; then
				vhost_port="vhost-user-$i-n$pci_node"
			else # use a non-local node
				remote_pci_nodes=`sub_from_list $node_list $pci_node`
				remote_pci_node=`echo $remote_pci_nodes | awk -F, '{print $1}'`
				vhost_port="vhost-user-$i-n$remote_pci_node"
			fi
			echo vhost_port: $vhost_port
			vhost_devs="$vhost_devs,$vhost_port"
		done
		;;
	esac
	vpp_startup_file=/etc/vpp/startup.conf
	pmd_threads=`echo "$vpp_ports * $queues" | bc`
	echo "devices: ${pci_devs}$vhost_devs"
	pmd_cpus=`get_pmd_cpus "${pci_devs}$vhost_devs" "$queues" "vpp-pmd"`
	if [ -z "$pmd_cpus" ]; then
		exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUAM nodes?"
	fi
	#log_cpu_usage "$pmd_cpus" "vpp-pmd"
	echo "#generated by start-vswitch" >$vpp_startup_file
	echo "unix {" >>$vpp_startup_file
	echo "    nodaemon" >>$vpp_startup_file
	echo "    log /var/log/vpp.log" >>$vpp_startup_file
	echo "    full-coredump" >>$vpp_startup_file
	case "${vpp_version}" in
		"17.10")
		echo "    cli-listen /run/vpp/cli.sock" >>$vpp_startup_file
		;;
	esac
	echo "}" >>$vpp_startup_file
	echo "cpu {" >>$vpp_startup_file
	echo "    workers $pmd_threads" >>$vpp_startup_file
	echo "    main-core 0" >>$vpp_startup_file
	echo "    corelist-workers $pmd_cpus" >>$vpp_startup_file
	echo "}" >>$vpp_startup_file
	echo "dpdk {" >>$vpp_startup_file
	echo "    dev default {" >>$vpp_startup_file
	echo "        num-rx-queues $queues" >>$vpp_startup_file
	echo "        num-tx-queues $queues" >>$vpp_startup_file
	if [ ! -z "${pci_desc_override}" ]; then
		echo "overriding PCI descriptors/queue with ${pci_desc_override}"
		echo "        num-rx-desc ${pci_desc_override}" >>$vpp_startup_file
		echo "        num-tx-desc ${pci_desc_override}" >>$vpp_startup_file
	else
		echo "setting PCI descriptors/queue with ${pci_descriptors}"
		echo "        num-rx-desc ${pci_descriptors}" >>$vpp_startup_file
		echo "        num-tx-desc ${pci_descriptors}" >>$vpp_startup_file
	fi
	echo "    }" >>$vpp_startup_file
	echo "    no-multi-seg" >>$vpp_startup_file
	echo "    uio-driver vfio-pci" >>$vpp_startup_file
	avail_pci_devs="$pci_devs"
	for i in `seq 0 1`; do
		pci_dev=`echo $avail_pci_devs | awk -F, '{print $1}'`
		avail_pci_devs=`echo $avail_pci_devs | sed -e s/^$pci_dev,//`
		echo "    dev $pci_dev" >>$vpp_startup_file
	done
	echo "    num-mbufs 32768" >>$vpp_startup_file
	echo "}" >>$vpp_startup_file
	echo "api-trace {" >>$vpp_startup_file
	echo "    on" >>$vpp_startup_file
	echo "}" >>$vpp_startup_file
	echo "api-segment {" >>$vpp_startup_file
	echo "    gid vpp" >>$vpp_startup_file
	echo "}" >>$vpp_startup_file
	screen -dmS vpp /usr/bin/vpp -c /etc/vpp/startup.conf
	echo -n "Waiting for VPP to be available"
	vpp_wait_counter=0
	case "${vpp_version}" in
		"17.04")
		# if a command is submitted to VPP 17.04 too quickly
		# it might never return, so delay a bit
		for i in `seq 1 10`; do
		    echo -n "."
		    sleep 1
		    (( vpp_wait_counter++ ))
		done
		;;
		"17.10")
		while [ ! -e /run/vpp/cli.sock -a ! -S /run/vpp/cli.sock ]; do
			echo -n "."
			sleep 1
			(( vpp_wait_counter++ ))
		done
		;;
	esac
	echo
	echo "Waited ${vpp_wait_counter} seconds for VPP to be available"
	vpp_wait_counter=0
	vpp_version_start=$(date)
	while [ 1 ]; do
		# VPP 17.04 and earlier will block here and wait until
		# the command is accepted.  VPP 17.07 will return with
		# an error immediately until the daemon is ready
		vpp_version_string=$(vppctl show version 2>&1)
		if echo ${vpp_version_string} | grep -q "FileNotFoundError\|Connection refused"; then
			echo -n "."
			sleep 1
			(( vpp_wait_counter++ ))
		else
			echo -n "done"
			break
		fi
	done
	echo
	if [ ${vpp_wait_counter} -gt 0 ]; then
	    echo "Waited ${vpp_wait_counter} seconds for VPP to return version information"
	else
	    vpp_version_stop=$(date)
	    echo "Started waiting for VPP version at ${vpp_version_start} and finished at ${vpp_version_stop}"
	fi
	echo "VPP version: ${vpp_version_string}"
	vpp_nics=`vppctl show interface | grep Ethernet | awk '{print $1}'`
	echo "vpp nics: $vpp_nics"
	avail_pci_devs="$pci_devs"
	for i in `seq 0 1`; do
		pci_dev=`echo $avail_pci_devs | awk -F, '{print $1}'`
		avail_pci_devs=`echo $avail_pci_devs | sed -e s/^$pci_dev,//`
		pci_dev_bus=`echo $pci_dev | awk -F: '{print $2}'`
		pci_dev_bus=`printf "%d" $pci_dev_bus`
		pci_dev_dev=`echo $pci_dev | awk -F: '{print $3}' | awk -F. '{print $1}'`
		pci_dev_dev=`printf "%d" $pci_dev_dev`
		pci_dev_func=`echo $pci_dev | awk -F: '{print $3}' | awk -F. '{print $2}'`
		pci_dev_func=`printf "%d" $pci_dev_func`
		echo "vpp device: Ethernet$pci_dev_bus/$pci_dev_dev/$pci_dev_func"
		vpp_nic[$i]=`vppctl show interface | grep Ethernet$pci_dev_bus/$pci_dev_dev/$pci_dev_func | awk '{print $1}'`
		echo vpp NIC: ${vpp_nic[$i]}
	done

	case $topology in
		"pp")   # 10GbP1<-->10GbP2
		set_vpp_bridge_mode ${vpp_nic[0]} ${vpp_nic[1]} ${switch_mode} 10

		case "${vpp_version}" in
			"17.07"|"17.10")
			vppctl set interface rx-placement ${vpp_nic[0]} queue 0 worker 0
			vppctl set interface rx-placement ${vpp_nic[1]} queue 0 worker 1
			;;
			"17.04"|*)
			vppctl set dpdk interface placement ${vpp_nic[0]} queue 0 thread 1
			vppctl set dpdk interface placement ${vpp_nic[1]} queue 0 thread 2
			;;
		esac
		;;
		"pvp"|"pv,vp")   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
		vpp_nic_index=2
		for i in `seq 0 1`; do
			pci_dev_index=$(( i + 1 ))
			pci_dev=`echo ${pci_devs} | awk -F, "{ print \\$${pci_dev_index}}"`
			pci_node=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`
			vpp_nic[${vpp_nic_index}]=$(vpp_create_vhost_user vhost-user-${i}-n${pci_node})
			(( vpp_nic_index++ ))
		done

		set_vpp_bridge_mode ${vpp_nic[0]} ${vpp_nic[2]} ${switch_mode} 10
		set_vpp_bridge_mode ${vpp_nic[1]} ${vpp_nic[3]} ${switch_mode} 20

		case "${vpp_version}" in
			"17.07"|"17.10")
			vppctl set interface rx-placement ${vpp_nic[0]} queue 0 worker 0
			vppctl set interface rx-placement ${vpp_nic[1]} queue 0 worker 1
			;;
			"17.04"|*)
			vppctl set dpdk interface placement ${vpp_nic[0]} queue 0 thread 3
			vppctl set dpdk interface placement ${vpp_nic[1]} queue 0 thread 4
			;;
		esac
		;;
	esac

	for nic in ${vpp_nic[@]}; do
		echo "Bringing VPP interface ${nic} online"
		vppctl set interface state ${nic} up
	done

	# query for some configuration details
	vppctl show interface
	vppctl show interface address
	vppctl show threads
	case "${vpp_version}" in
		"17.07"|"17.10")
		vppctl show interface rx-placement
		;;
		"17.04"|*)
		vppctl show dpdk interface placement
		;;
	esac
	;;
	ovs)
	DB_SOCK="$prefix/var/run/openvswitch/db.sock"
	ovs_ver=`$prefix/sbin/ovs-vswitchd --version | awk '{print $4}'`
	echo "starting ovs (ovs_ver=${ovs_ver})"
	mkdir -p $prefix/var/run/openvswitch
	mkdir -p $prefix/etc/openvswitch
	$prefix/bin/ovsdb-tool create $prefix/etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
	$prefix/sbin/ovsdb-server -v --remote=punix:$DB_SOCK \
    	--remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    	--pidfile --detach || exit_error "failed to start ovsdb"

	if echo $ovs_ver | grep -q "^2\.6\|^2\.7\|^2\.8"; then
		dpdk_opts=""
		$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
		case $numa_mode in
			strict)
			$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="$local_socket_mem_opt"
			$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask="`get_cpumask $local_nodes_non_iso_cpus_list`"
			;;
			preferred)
			$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="$all_socket_mem_opt"
			$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask="`get_cpumask $all_nodes_non_iso_cpus_list`"
			;;
		esac
	else
		dpdk_opts="--dpdk -n 4 --socket-mem $local_socket_mem_opt --"
	fi
	/bin/rm -f /var/log/openvswitch/ovs-vswitchd.log
	echo starting ovs-vswitchd
	case $numa_mode in
		strict)
		sudo su -g qemu -c "umask 002; numactl --cpunodebind=$local_numa_nodes $prefix/sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach"
		;;
		preferred)
		sudo su -g qemu -c "umask 002; $prefix/sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach"
		;;
	esac
	rc=$?
	if [ $rc -ne 0 ]; then
		exit_error "Aborting since openvswitch did not start correctly. Openvswitch exit code: [$rc]"
	fi
	
	echo waiting for ovs to init
	$prefix/bin/ovs-vsctl --no-wait init

	if echo $ovs_ver | grep -q "^2\.7\|^2\.8"; then
	    ovs_dpdk_interface_0_name="dpdk-0"
	    pci_dev=`echo ${pci_devs} | awk -F, '{ print $1}'`
	    ovs_dpdk_interface_0_args="options:dpdk-devargs=${pci_dev}"
	    ovs_dpdk_interface_1_name="dpdk-1"
	    pci_dev=`echo ${pci_devs} | awk -F, '{ print $2}'`
	    ovs_dpdk_interface_1_args="options:dpdk-devargs=${pci_dev}"
	else
	    ovs_dpdk_interface_0_name="dpdk0"
	    ovs_dpdk_interface_0_args=""
	    ovs_dpdk_interface_1_name="dpdk1"
	    ovs_dpdk_interface_1_args=""
	fi
	
	echo "configuring ovs with network topology: $topology"
	case $topology in
		"vv,vv")  # VM1P1<-->VM2P1, VM1P2<-->VM2P2
		# create a bridge with 2 virt devs per bridge, to be used to connect to 2 VMs
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user3 -- set Interface vhost-user3 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		set_ovs_bridge_mode ovsbr0 ${switch_mode}
	
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr1
		$prefix/bin/ovs-vsctl add-br ovsbr1 -- set bridge ovsbr1 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user4 -- set Interface vhost-user4 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr1
		set_ovs_bridge_mode ovsbr1 ${switch_mode}
		ovs_ports=4
		;;
		"v")  # vm1 <-> vm1 
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		set_ovs_bridge_mode ovsbr0 ${switch_mode}
		ovs_ports=2
		;;
		# pvvp probably does not work
		pvvp|pv,vv,vp)  # 10GbP1<-->VM1P1, VM1P2<-->VM2P2, VM2P1<-->10GbP2
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_0_name} -- set Interface ${ovs_dpdk_interface_0_name} type=dpdk ${ovs_dpdk_interface_0_args}
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		set_ovs_bridge_mode ovsbr0 ${switch_mode}
	
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr1
		$prefix/bin/ovs-vsctl add-br ovsbr1 -- set bridge ovsbr1 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user3 -- set Interface vhost-user3 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr1
		set_ovs_bridge_mode ovsbr1 ${switch_mode}
	
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr2
		$prefix/bin/ovs-vsctl add-br ovsbr2 -- set bridge ovsbr2 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr2 ${ovs_dpdk_interface_1_name} -- set Interface ${ovs_dpdk_interface_1_name} type=dpdk ${ovs_dpdk_interface_1_args}
		$prefix/bin/ovs-vsctl add-port ovsbr2 vhost-user4 -- set Interface vhost-user4 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr2
		set_ovs_bridge_mode ovsbr2 ${switch_mode}
		ovs_ports=6
		;;
		pvp|pv,vp)   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
		# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
		vhost_ports=""
		for i in `seq 0 1`; do
			phy_br="phy-br-$i"
			pci_dev_index=$(( i + 1 ))
			pci_dev=`echo ${pci_devs} | awk -F, "{ print \\$${pci_dev_index}}"`
			pci_node=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`
			if [ "$vhost_affinity" == "local" ]; then
				vhost_port="vhost-user-$i-n$pci_node"
			else # use a non-local node
				remote_pci_nodes=`sub_from_list $node_list $pci_node`
				remote_pci_node=`echo $remote_pci_nodes | awk -F, '{print $1}'`
				vhost_port="vhost-user-$i-n$remote_pci_node"
			fi
			echo vhost_port: $vhost_port
			vhost_ports="$vhost_ports,$vhost_port"
			if echo $ovs_ver | grep -q "^2\.7\|^2\.8"; then
				phys_port_name="dpdk-${i}"
				phys_port_args="options:dpdk-devargs=${pci_dev}"
			else
				phys_port_name="dpdk$i"
				phys_port_args=""
			fi
			$prefix/bin/ovs-vsctl --if-exists del-br $phy_br
			$prefix/bin/ovs-vsctl add-br $phy_br -- set bridge $phy_br datapath_type=netdev
			$prefix/bin/ovs-vsctl add-port $phy_br ${phys_port_name} -- set Interface ${phys_port_name} type=dpdk ${phys_port_args}
			if [ -z "$overlay" -o "$overlay" == "none" -o "$overlay" == "half-vxlan" -a $i -eq 1 ]; then
				$prefix/bin/ovs-vsctl add-port $phy_br $vhost_port -- set Interface $vhost_port type=dpdkvhostuser
				if [ ! -z "$vhu_desc_override" ]; then
					echo "overriding vhostuser descriptors/queue with $vhu_desc_override"
					ovs-vsctl set Interface $vhost_port options:n_txq_desc=$vhu_desc_override
					ovs-vsctl set Interface $vhost_port options:n_rxq_desc=$vhu_desc_override
				fi
				$prefix/bin/ovs-ofctl del-flows $phy_br
				set_ovs_bridge_mode $phy_br ${switch_mode}
			else
				if [ "$overlay" == "vxlan" -o "$overlay" == "half-vxlan" -a $i -eq 0 ]; then
					vxlan_br="vxlan-br-$i"
					hwaddr=`echo $hwaddrs | awk '{print $1}'`
					hwaddrs=`echo $hwaddrs | sed -e s/^$hwaddr//`
					vxlan_port="vxlan-$i"
					vni=`echo "100 + $i" | bc`
					local_ip="10.0.$vni.1"
					remote_ip="10.0.$vni.2"
					$prefix/bin/ovs-vsctl set Bridge $phy_br other-config:hwaddr=$hwaddr
					$prefix/bin/ovs-vsctl --if-exists del-br $vxlan_br
					$prefix/bin/ovs-vsctl add-br $vxlan_br -- set bridge $vxlan_br datapath_type=netdev
					$prefix/bin/ovs-vsctl add-port $vxlan_br $vhost_port -- set Interface $vhost_port type=dpdkvhostuser
					$prefix/bin/ovs-vsctl add-port $vxlan_br $vxlan_port -- set interface $vxlan_port type=vxlan options:remote_ip=$remote_ip options:dst_port=4789 options:key=$vni
					ip addr add $local_ip/24 dev $phy_br
					ip l set dev $phy_br up
					ip l set dev $vxlan_br up
				fi
			fi
		done
		vhost_ports=`echo $vhost_ports | sed -e 's/^,//'`
		ovs_ports=4
		;;
		"pp")  # 10GbP1<-->10GbP2
		# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_0_name} -- set Interface ${ovs_dpdk_interface_0_name} type=dpdk ${ovs_dpdk_interface_0_args}
		$prefix/bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_1_name} -- set Interface ${ovs_dpdk_interface_1_name} type=dpdk ${ovs_dpdk_interface_1_args}
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		set_ovs_bridge_mode ovsbr0 ${switch_mode}
		ovs_ports=2
	esac
	echo "using $queues queue(s) per port"
	$prefix/bin/ovs-vsctl set interface ${ovs_dpdk_interface_0_name} options:n_rxq=$queues
	$prefix/bin/ovs-vsctl set interface ${ovs_dpdk_interface_1_name} options:n_rxq=$queues
	if [ ! -z "$pci_desc_override" ]; then
		echo "overriding PCI descriptors/queue with $pci_desc_override"
		ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_txq_desc=$pci_desc_override
		ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_rxq_desc=$pci_desc_override
		ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_txq_desc=$pci_desc_override
		ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_rxq_desc=$pci_desc_override
	else
		echo "setting PCI descriptors/queue with $pci_descriptors"
		ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_txq_desc=$pci_descriptors
		ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_rxq_desc=$pci_descriptors
		ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_txq_desc=$pci_descriptors
		ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_rxq_desc=$pci_descriptors
	fi
	
	#configure the number of PMD threads to use
	pmd_threads=`echo "$ovs_ports * $queues" | bc`
	echo "using a total of $pmd_threads PMD threads"
	pmdcpus=`get_pmd_cpus "$pci_devs,$vhost_ports" $queues "ovs-pmd"`
	if [ -z "$pmdcpus" ]; then
		exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUAM nodes?"
	fi
	pmd_cpu_mask=`get_cpumask $pmdcpus`
	echo pmd_cpus_list is [$pmdcpus]
	echo pmd_cpu_mask is [$pmd_cpu_mask]
	vm_cpus=`sub_from_list $ded_cpus_list $pmdcpus`
	echo vm_cpus is [$vm_cpus]
	ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$pmd_cpu_mask
	echo "PMD cpumask command: ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$pmd_cpu_mask"
	echo "PMD thread assinments:"
	ovs-appctl dpif-netdev/pmd-rxq-show
	;;

	testpmd)
	if [ ! -e ${testpmd_path} -o ! -x "${testpmd_path}" ]; then
		exit_error "testpmd_path: [${testpmd_path}] does not exist or is not exexecutable"
	fi
	echo "testpmd_path: [${testpmd_path}]"
	echo configuring testpmd with $topology
	# note that we cannot choose a different number of descriptors for each testpmd device
	if [ ! -z "$pci_desc_override" ]; then
		testpmd_descriptors=$pci_desc_override
	else
		testpmd_descriptors=$pci_descriptors
	fi
	if [ "$numa_mode" == "strict" ]; then
		testpmd_socket_mem_opt="$local_socket_mem_opt"
	else
		testpmd_socket_mem_opt="$all_socket_mem_opt"
	fi
	console_cpu=`echo $local_nodes_non_iso_cpus_list | awk -F, '{print $1}'`
	case $topology in
		pp)
		testpmd_ports=2
		pmd_threads=`echo "$testpmd_ports * $queues" | bc`
		avail_pci_devs="$pci_devs"
		i=0
		pci_location_arg=""
		for nic in `echo $pci_devs | sed -e 's/,/ /g'`; do
			pci_location_arg="$pci_location_arg -w $nic"
		done
		echo use_ht: [$use_ht]
		pmd_cpus=`get_pmd_cpus "$pci_devs" "$queues" "testpmd-pmd"`
		if [ -z "$pmd_cpus" ]; then
			exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUAM nodes?"
		fi
		pmd_cpu_mask=`get_cpumask $pmd_cpus`
		echo pmd_cpu_list is [$pmd_cpus]
		echo pmd_cpu_mask is [$pmd_cpu_mask]
		rss_flags=""
		if [ $queues -gt 1 ]; then
		    rss_flags="--rss-ip --rss-udp"
		fi
		testpmd_cmd="${testpmd_path} -l $console_cpu,$pmd_cpus --socket-mem $testpmd_socket_mem_opt -n 4\
		  --proc-type auto --file-prefix testpmd$i $pci_location_arg\
                  --\
		  $testpmd_numa --nb-cores=$pmd_threads\
		  --nb-ports=2 --portmask=3 --auto-start --rxq=$queues --txq=$queues ${rss_flags}\
		  --rxd=$testpmd_descriptors --txd=$testpmd_descriptors >/tmp/testpmd-$i"
		echo testpmd_cmd: $testpmd_cmd
		screen -dmS testpmd-$i bash -c "$testpmd_cmd"
		ded_cpus_list=`sub_from_list $ded_cpus_list $pmd_cpus`
		;;
		pvp|pv,vp)
		mkdir -p /var/run/openvswitch
		testpmd_ports=2
		pmd_threads=`echo "$testpmd_ports * $queues" | bc`
		avail_pci_devs="$pci_devs"
		echo use_ht: [$use_ht]
		for i in `seq 0 1`; do
			pci_dev_index=$(( i + 1 ))
			pci_dev=`echo ${pci_devs} | awk -F, "{ print \\$${pci_dev_index}}"`
			pci_node=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`
			vhost_port="/var/run/openvswitch/vhost-user-$i-n$pci_node"
			if [ "$vhost_affinity" == "local" ]; then
				vhost_port="/var/run/openvswitch/vhost-user-$i-n$pci_node"
			else # use a non-local node
				remote_pci_nodes=`sub_from_list $node_list $pci_node`
				remote_pci_node=`echo $remote_pci_nodes | awk -F, '{print $1}'`
				vhost_port="/var/run/openvswitch/vhost-user-$i-n$remote_pci_node"
			fi
			pmd_cpus=`get_pmd_cpus "$pci_dev,$vhost_port" $queues "testpmd-pmd"`
			if [ -z "$pmd_cpus" ]; then
				exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUAM nodes?"
			fi
			#log_cpu_usage "$pmd_cpus" "testpmd-pmd"
			pmd_cpu_mask=`get_cpumask $pmd_cpus`
			echo pmd_cpu_list is [$pmd_cpus]
			echo pmd_cpu_mask is [$pmd_cpu_mask]
			rss_flags=""
			if [ $queues -gt 1 ]; then
			    rss_flags="--rss-ip --rss-udp"
			fi
			testpmd_cmd="${testpmd_path} -l $console_cpu,$pmd_cpus --socket-mem $testpmd_socket_mem_opt -n 4\
			  --proc-type auto --file-prefix testpmd$i -w $pci_dev --vdev eth_vhost0,iface=$vhost_port -- --nb-cores=$pmd_threads\
			  $testpmd_numa --nb-ports=2 --portmask=3 --auto-start --rxq=$queues --txq=$queues ${rss_flags}\
			  --rxd=$testpmd_descriptors --txd=$testpmd_descriptors >/tmp/testpmd-$i"
			echo testpmd_cmd: $testpmd_cmd
			screen -dmS testpmd-$i bash -c "$testpmd_cmd"
			count=0
			while [ ! -e $vhost_port -a $count -le 30 ]; do
				echo "waiting for $vhost_port"
				sleep 1
				((count+=1))
			done
			chmod 777 $vhost_port || exit_error "could not chmod 777 $vhost_port"
			#ded_cpus_list=`sub_from_list $ded_cpus_list $pmd_cpus`
		done
		;;
	esac
	;;
esac

	
