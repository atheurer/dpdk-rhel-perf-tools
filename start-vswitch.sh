#!/bin/bash

# This script will start a vswitch of your choice, doing the following:
# -use multi-queue (for DPDK)
# -bind DPDK PMDs to optimal CPUs
# -for pvp topologies, provide a list of optimal cpus available for the VM
# configure an overlay network such as VxLAN

# The following features are not implemented but would be nice to add:
# -for ovs, configure x flows
# -for a router, configure x routes
# -configure VLAN
# -configure a firewall

set -u

script_root=$(dirname $(readlink -f $0))
. $script_root/utils/cpu_parsing.sh


###############################################################################
# Default values
###############################################################################

#
# topology:
#
#	Two physical devices on one switch.  'topology' is desctibed by a list 
#	of 1 or more switches separated by commas.  The supported interfaces on 
#	a switch are:
#
#	p:		A physical port.  This may include host physical ports, or 
#			SR-IOV PCIe or virtio devices seen within a guest
#
#	v:		A virtio-net interface like dpdkvhostuser or vhost-net (depending on dataplane)
#
topology="pp"	


#
# queues:
#
#	Number of queue-pairs (rx/tx) to use per device	
#
queues=1


#
# switch:
#
#	Type of forwarding engine to be used on the DUT topology.
#	Currently supported switch types:
#
#	testpmd:	DPDK's L2 forwarding test program
#
#	ovs:		Open vSwitch
#
#	linuxbridge:	L2 kernel networking stack
#
#	linuxrouter:	L3 kernel networking stack
#
switch="ovs"


#
# switch_mode:
#
# 	Configuration of the $switch in use.  Currently supported list depends on $switch.
#	Modes support by switch type are:
#
#	linuxbridge:	default
#
#	linuxrouter:	default
#
#	testpmd:	default
#
#	ovs:		default/direct-flow-rule, l2-bridge
#
switch_mode="default"


#
# numa_mode:
#
#	'numa_mode' is for DPDK vswitches only.
#
#	strict:		All PMD threads for all phys and virt devices use memory and cpu only 
#			from the numa node where the physical adapters are located.
#			This implies the VMs must be on the same node.
#
#	preferred:	Just like 'strict', but the vswitch also has memory and in some cases 
#			uses cpu from the non-local NUMA nodes.
#
#	cross:		The PMD threads for all phys devices use memory and cpu from
#			the local NUMA node, but VMs are present on another NUMA node,

#			and so the PMD threads for those virt devices are also on
#			another NUMA node.
#
numa_mode="strict" 


#
# vm_numa_node:
#
#	'vm_numa_node' is for DPDK vswitches only.
#
#       A number representing which NUMA node a VM is defined
#
vm_numa_node="" 



#
# ovs_build:
#
#	Specify to use OVS either from:
#
#	rpm:		Pre-built package
#
#	src:		Manually built and installed
#
ovs_build="rpm"


#
# dpdk_nic_kmod:
#
#	The kernel module to use when assigning an Intel network device to a 
#	userspace program (DPDK application)
#
dpdk_nic_kmod="vfio-pci"


#
# dataplane:
#
#	The type of forwarding plane to be used on the DUT.
#
#	dpdk:			Intel's Data Plane Development Kit
#
#	kernel:			The Linux kernel's networking stack
#
#	kernel-hw-offload:	OVS dataplane handled in NIC hardware
#
dataplane="dpdk"


#
# use_ht:
#
#	Specify if hyperthreaded processors should be used or not for
#	forwading packets
#
#	y:			yes
#
#	n:			no
#
use_ht="y"


#
# testpmd_path:
#
#	Specifies the location of DPDK's L2 forwarding program testpmd
#
testpmd_path="/usr/bin/testpmd"


#
# supported_switches:
#
#	The list of supported switches that may be used upon the DUT
#
supported_switches="linuxbridge ovs linuxrouter testpmd"


#
# pci_descriptors:
#
#	Sets the DPDK physical port queue size.
#	NOTE:  Also used to set testpmd rxd/txd ring size.  We may want to make this separate
#       from the DPDK physical port descriptor programming.
#
#	Size should probably not be larger than 2048.  Using a size of 4096 may have a negative 
#	impact upon performance.  See:  http://docs.openvswitch.org/en/latest/intro/install/dpdk/
#	
pci_descriptors=2048


#
# pci_desc_ovveride:
#
#	Used to override the desriptor size of any of the vswitches here.  
#
pci_desc_override="" 


#
# vhu_desc_override:
#
#	Use to override the desriptor size of any of the vswitches here. 
#	NOTE:  This needs to be fixed given we also have pci_desc_override as
#	well as pci_descriptors all doing similar things
#
vhu_desc_override=""


#
# cpu_usage_file:
#
#	After the vswitch is started, it must decide which host cpus the VM uses.  
#	The file $cpu_usage_file, defaulting to /var/log/isolated_cpu_usage.conf, 
#	shows which cpus are used for the vswitch and which cpus are left for the 
#	VM.  The shell script can be used virt-pin.sh to pin the vcpus. It will read 
#	the /var/log/isolated_cpu_usage.conf ($cpu_usage_file) file to make sure 
#	it does not use cpus already used by the vswitch.
#
cpu_usage_file="/var/log/isolated_cpu_usage.conf"


#
# vhost_affinity:
#
# 	NOTE:  This is not working yet 
#
# 	local: the vhost interface will reside in the same node as the physical interface on the same bridge
#
#  	remote: The vhost interface will reside in remote node as the physical interface on the same bridge
#
#	This locality is an assumption and must match what was configured when VMs are created
#
vhost_affinity="local"


#
# no_kill:
#
# Don't kill all OVS sessions.  However, any process 
# owning a DPDK device will still be killed
#
no_kill=0


#
# use_ovs_systemd_services:
#
# Allow openvswitch.services to set up OVS database and daemon
# instead of this script doing it
#
use_ovs_systemd_services=0


function log() {
	echo -e "start-vswitch: LINENO: ${BASH_LINENO[0]} $1"
}

function exit_error() {
	local error_message=$1
	local error_code=$2
	if [ -z "$error_code"] ; then
		error_code=1
	fi
	log "ERROR: $error_message"
	exit $error_code
}

function set_ovs_bridge_mode() {
	local bridge=$1
	local switch_mode=$2

	$ovs_bin/ovs-ofctl del-flows ${bridge}
	case "${switch_mode}" in
		"l2-bridge")
			$ovs_bin/ovs-ofctl add-flow ${bridge} action=NORMAL
			;;
		"default"|"direct-flow-rule")
			$ovs_bin/ovs-ofctl add-flow ${bridge} "in_port=1,idle_timeout=0 actions=output:2"
			$ovs_bin/ovs-ofctl add-flow ${bridge} "in_port=2,idle_timeout=0 actions=output:1"
			;;
	esac
}



function get_dev_loc() {
	# input should be pci_location/port-number, like 0000:86:0.0/1
	echo $1 | awk -F/ '{print $1}'
}

function get_devs_locs() {
	# input should be a list of pci_location/port-number, like 0000:86:0.0/0,0000:86:0.0/1
	# returns a list of PCI location IDs with no repeats
	# for exmaple get_devs_locs "0000:86:0.0/0,0000:86:0.0/1" returns "0000:86:0.0"
	local this_dev
	for this_dev in `echo $1 | sed -e 's/,/ /g'`; do
		get_dev_loc $this_dev
	done | sort | uniq 
}

function get_dev_port() {
	# input should be pci_location/port-number, like 0000:86:0.0/1
	echo $1 | awk -F/ '{print $2}'
}

function get_dev_desc() {
	# input should be pci_location/port-number, like 0000:86:0.0/1
	lspci -s $(get_dev_loc $1) | cut -d" " -f 2- | sed -s 's/ (.*$//'
}

function get_dev_netdevs() {
	/bin/ls /sys/bus/pci/devices/$(get_dev_loc $1)/net
}

# Return the netdev device name for a PCI location and matching phys_port_name
# This is necessary when there are more than one netdev ports per PF
# This is also used to identify a netdev device with no actual port (use "" as the match)

# Return the netdev name. Input must be "pf_location/port_number"
function get_dev_netdev() {
	local dev_pf_loc=`get_dev_loc $1`
	local dev_pf_port=`get_dev_port $1`
	local netdevs=(`get_dev_netdevs $dev_pf_loc`)
	echo "${netdevs[$dev_pf_port]}"
}

function get_switch_id() {
	# input shold be the netdev name
	cat /sys/class/net/$1/phys_switch_id || return 1
}

# Return the netdev of the switchdev (representor) device
# You must provide the full device name, aka pci_location/port-id
function get_sd_netdev_name() {
	local dev="$1"
	local dev_loc=`get_dev_loc $dev`
	local dev_port=`get_dev_port $dev`
	local dev_netdev=`get_dev_netdev $dev`
	local dev_sw_id=`get_switch_id $dev_netdev`
	local veth_name=""
	local veth_sw_id=""
	local veth_port_name=""
	local count=0
	# search all virtual devices, looking for a switch_id that matches the 
	# physical port and pick the Nth match, where N = the port ID od the device
	for veth_name in `/bin/ls /sys/devices/virtual/net`; do
		veth_sw_id=`cat /sys/class/net/$veth_name/phys_switch_id 2>/dev/null`
		if [ "$dev_sw_id" == "$veth_sw_id" ]; then
			veth_phys_port_name=`cat /sys/class/net/$veth_name/phys_port_name`
			#if [ $dev_port -eq $count ]; then
			if [ "$veth_phys_port_name" == "pf0vf$dev_port" ]; then
				echo "$veth_name"
				return
			fi
			if [ "$veth_phys_port_name" == "pf1vf$dev_port" ]; then
				echo "$veth_name"
				return
			fi
			if [ "$veth_phys_port_name" == "$dev_port" ]; then
				echo "$veth_name"
				return
			fi
			#((count++))
		fi
	done
	if [ "$sd_eth_name" == "" ]; then
		return 1
	fi
}

# Process options and arguments
opts=$(getopt -q -o i:c:t:r:m:p:M:S:C:o --longoptions "no-kill,vhost-affinity:,numa-mode:,vm-numa-node:,desc-override:,vhost_devices:,pci-devices:,devices:,nr-queues:,use-ht:,overlay-network:,topology:,dataplane:,switch:,switch-mode:,testpmd-path:,dpdk-nic-kmod:,prefix:,pci-desc-override:,use-ovs-systemd-services:,sprint-config" -n "getopt.sh" -- "$@")
if [ $? -ne 0 ]; then
	printf -- "$*\n"
	printf "\n"
	printf "\t${benchmark_name}: you specified an invalid option\n\n"
	printf "\tThe following options are available:\n\n"
	#              1   2         3         4         5         6         7         8         9         0         1         2         3
	#              678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012
	printf -- "\t\t--[pci-]devices=str/port,str/port ..... Two PCI locations of Ethenret adapters to use, like:\n"
        printf -- "\t\t                                        '--devices=0000:83:00.0/0,0000:86:00.0/0'.  Port numbers are optional\n"
	printf -- "\t\t                                        You can list the same PCI device twice only if the physical function has \n"
	printf -- "\t\t                                        two netdev devices\n\n"
	printf -- "\t\t--device-ports=int,int ................ If a PCI device has more than 1 netdev, then you need to specify the port ID for each device.  Port enumeration starts with \"0\"\n\n"
	printf -- "\t\t--no-kill ............................. Don't kill all OVS sessions (however, anything process owning a DPDK device will still be killed)\n\n"
	printf -- "\t\t--vhost-affinity=str .................. local [default]: Use same numa node as PCI device\n"
	printf -- "\t\t                                        remote:          Use opposite numa node as PCI device\n\n"
	printf -- "\t\t--nr-queues=int ....................... The number of queues per device\n\n"
	printf -- "\t\t--use-ht=[y|n] ........................ y=Use both cpu-threads on HT core\n"
	printf -- "\t\t                                        n=Only use 1 cpu-thread per core\n"
	printf -- "\t\t                                        Note: Using HT has better per/core throuhgput, but not using HT has better per-queue throughput\n\n"
	printf -- "\t\t--topology=str ........................ pp:            Two physical devices on same bridge\n"
        printf -- "\t\t                                        pvp or pv,vp:  Two bridges, each with a phys port and a virtio port)\n\n"
	printf -- "\t\t--dataplane=str ....................... dpdk, kernel, or kernel-hw-offload\n\n"
	printf -- "\t\t--desc-override ....................... Override default size for descriptor size\n\n"
	printf -- "\t\t--switch=str .......................... testpmd, ovs, linuxrouter, or linuxbridge\n\n"
	printf -- "\t\t--switch-mode=str ..................... Mode that the selected switch operates in.  Modes differ between switches\n"
	printf -- "\t\t                                        \tlinuxbridge: default\n"
	printf -- "\t\t                                        \tlinuxrouter: default\n"
	printf -- "\t\t                                        \ttestpmd:     default\n"
	printf -- "\t\t                                        \tovs:         default/direct-flow-rule, l2-bridge\n"
	printf -- "\t\t--testpmd-path=str .................... Override the default location for the testpmd binary (${testpmd_path})\n\n"
	printf -- "\t\t--dpdk-nic-kmod=str ................... Use this kernel modeule for the devices (default is $dpdk_nic_kmod)\n\n"
	printf -- "\t\t--numa-mode=str ....................... strict:    (default).  All PMD threads for all phys and virt devices use memory and cpu only\n"
        printf -- "\t\t                                                   from the numa node where the physical adapters are located.\n"
        printf -- "\t\t                                                   This implies the VMs must be on the same node.\n"
	printf -- "\t\t                                        preferred: Just like 'strict', but the vswitch also has memory and in some cases\n"
	printf -- "\t\t                                                   uses cpu from the non-local NUMA nodes.\n"
	printf -- "\t\t                                        cross:     The PMD threads for all phys devices use memory and cpu from\n"
	printf -- "\t\t                                                   the local NUMA node, but VMs are present on another NUMA node,\n"
	printf -- "\t\t                                                   and so the PMD threads for those virt devices are also on\n"
	printf -- "\t\t                                                   another NUMA node.\n"
        printf -- "\t\t--vm-numa-node ........................ Number representing which NUMA node the VM exists.  To be used with 'numa-mode=cross'\n"
        printf -- "\t\t--use-ovs-systemd-services .............Use openvswitch systemd services to start OVS\n"
	exit_error "" ""
fi
pci_descriptor_override=""
log "opts: [$opts]"
eval set -- "$opts"
log "Processing options:"
while true; do
	case "$1" in
		--no-kill)
		shift
		no_kill=1
		log "no_kill: [$no_kill]"
		;;
		--devices)
		shift
        devs=""
		if [ -n "$1" ]; then
			for dev in `echo $1 | sed -e 's/,/ /g'`; do
				devs="$devs,$dev"
			done
			devs=`echo $devs | sed -e s/^,//`
			log "devs: [$devs]"
			shift
		fi
		;;
		--vhost-affinity)
		shift
		if [ -n "$1" ]; then
			vhost_affinity="$1"
			log "vhost_affinity: [$vhost_affinity]"
			shift
		fi
		;;
		--nr-queues)
		shift
		if [ -n "$1" ]; then
			queues="$1"
			log "nr_queues: [$queues]"
			shift
		fi
		;;
		--use-ht)
		shift
		if [ -n "$1" ]; then
			use_ht="$1"
			log "use_ht: [$use_ht]"
			shift
		fi
		;;
		--topology)
		shift
		if [ -n "$1" ]; then
			topology="$1"
			log "topology: [$topology]"
			shift
		fi
		;;
		--dataplane)
		shift
		if [ -n "$1" ]; then
			dataplane="$1"
			log "dataplane: [$dataplane]"
			shift
		fi
		;;
		--pci-desc-override)
		shift
		if [ -n "$1" ]; then
			pci_desc_override="$1"
			log "pci-desc-override: [$pci_desc_override]"
			shift
		fi
		;;
		--vhu-desc-override)
		shift
		if [ -n "$1" ]; then
			vhu_desc_override="$1"
			log "vhu-desc-override: [$vhu_desc_override]"
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
				log "switch: [$switch]"
			else
				exit_error "switch: [$switch] is not supported by this script" ""
			fi
		fi
		;;
		--switch-mode)
		shift
		if [ -n "$1" ]; then
			switch_mode="$1"
			shift
			log "switch_mode: [$switch_mode]"
		fi
		;;
		--testpmd-path)
		shift
		if [ -n "$1" ]; then
			testpmd_path="$1"
			shift
			if [ ! -e ${testpmd_path} -o ! -x "${testpmd_path}" ]; then
				exit_error "testpmd_path: [${testpmd_path}] does not exist or is not exexecutable" ""
			fi
			log "testpmd_path: [${testpmd_path}]"
		fi
		;;
		--numa-mode)
		shift
		if [ -n "$1" ]; then
			numa_mode="$1"
			shift
			log "numa_mode: [$numa_mode]"
		fi
		;;
		--vm-numa-node)
		shift
		if [ -n "$1" ]; then
			vm_numa_node="$1"
			shift
			log "vm_numa_node: [$vm_numa_node]"
		fi
		;;
		--dpdk-nic-kmod)
		shift
		if [ -n "$1" ]; then
			dpdk_nic_kmod="$1"
			shift
			log "dpdk_nic_kmod: [$dpdk_nic_kmod]"
		fi
		;;
		--prefix)
		shift
		if [ -n "$1" ]; then
			prefix="$1"
			shift
			log "prefix: [$prefix]"
		fi
		;;
		--use-ovs-systemd-services)
		shift
		if [ -n "$1" ]; then
			use_ovs_systemd_services="$1"
			shift
			log "use_ovs_systemd_services: [$use_ovs_systemd_services]"
		fi
		;;
		--print-config)
		shift
		echo ""
		echo "topology = $topology"	
		echo "queues = $queues"	
		echo "switch = $switch"
		echo "switch_mode = $switch_mode"
		echo "numa_mode = $numa_mode"
		echo "vm_numa_node = $vm_numa_node"
		echo "ovs_build = $ovs_build"
		echo "dpdk_nic_kmod = $dpdk_nic_kmod"
		echo "dataplane = $dataplane"
		echo "use_ht = $use_ht"
		echo "testpmd_path = $testpmd_path"
		echo "supported_switches = $supported_switches"
		echo "pci_descriptors = $pci_descriptors"
		echo "pci_desc_override = $pci_descriptor_override"
		echo "vhu_desc_override = $vhu_desc_override"
		echo "cpu_usage_file = $cpu_usage_file"
		echo "vhost_affinity = $vhost_affinity"
		echo "no_kill = $no_kill"
		echo "use_ovs_systemd_services=$use_ovs_systemd_services"
		echo ""
		;;
		--)
		shift
		break
		;;
		*)
		log "[$script_name] bad option, \"$1 $2\""
		break
		;;
	esac
done

# validate switch modes
log "Validating the switch-mode $switch_mode given the switch is $switch..."
case "${switch}" in
	"linuxbridge"|"linuxrouter"|"testpmd")
		case "${switch_mode}" in
			"default")
				;;
			*)
				exit_error "switch=${switch} does not support switch_mode=${switch_mode}" ""
				;;
		esac
		;;
	"ovs")
		case "${switch_mode}" in
			"default"|"direct-flow-rule"|"l2-bridge")
				;;
			*)
				exit_error "switch=${switch} does not support switch_mode=${switch_mode}" ""
				;;
		esac
		;;
esac
log "switch-mode $switch_mode is valid"

num_system_cpus=`getconf _NPROCESSORS_ONLN`

log "BILL - num_system_cpus = $num_system_cpus"

# check for software dependencies.  Just make sure everything possibly needed is installed.
log "Determining if proper software tools are installed..."
all_deps="lsof lspci bc dpdk-devbind.py driverctl udevadm ip screen tmux brctl"
for i in $all_deps; do
	if which $i >/dev/null 2>&1; then
		continue
	else
		exit_error "You must have the following installed to run this script: '$i'  Please install first" ""
	fi
done


# only run if selinux is disabled
selinuxenabled && exit_error "disable selinux before using this script" ""

# either "rpm" or "src"
if [ "$ovs_build"="rpm" ]; then
	ovs_bin="/usr/bin"
	ovs_sbin="/usr/sbin"
	ovs_run="/var/run/openvswitch"
	ovs_etc="/etc/openvswitch"
log "Using OVS from RPM"
else
	ovs_bin="/usr/local/bin"
	ovs_sbin="/usr/local/sbin"
	ovs_run="/usr/local/var/run/openvswitch"
	ovs_etc="/usr/local/etc/openvswitch"
log "Using OVS that has been build locally"
fi

# Get RHEL major version.  Sometimes /sysfs changes between versions
rhel_major_version=`cat /etc/redhat-release | tr -dc '0-9.'|cut -d \. -f1`

dev_count=0
# make sure all of the pci devices used are exactly the same
prev_dev_desc=""
prev_pci_desc=""
log "devs = $devs"
for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
	this_pci_desc=$(get_dev_desc $this_dev)
	if [ "$prev_pci_desc" != "" -a "$prev_pci_desc" != "$(get_dev_desc $this_dev)" ]; then
		exit_error "PCI devices are not the exact same type: $prev_pci_desc, $this_pci_desc" ""
	else
		prev_pci_desc=$this_pci_desc
		log "Using PCI device: $(lspci -s $this_dev)"
	fi
	((dev_count++))
done
if [ $dev_count -ne 2 ]; then
	exit_error "you must use 2 PCI devices, you used: $dev_count" ""
fi

kernel_nic_kmod=`lspci -k -s $(get_dev_loc $this_dev) | grep "Kernel modules:" | awk -F": " '{print $2}' | sed -e s/virtio_pci/virtio-pci/`
log "kernel mod: $kernel_nic_kmod"

# kill any process using the 2 devices
log "Checking for an existing process using $devs"
for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
	iommu_group=`readlink /sys/bus/pci/devices/$(get_dev_loc $this_dev)/iommu_group | awk -Fiommu_groups/ '{print $2}'`
	pids=`lsof -n -T -X | grep -- "/dev/vfio/$iommu_group" | awk '{print $2}' | sort | uniq`
	if [ ! -z "$pids" ]; then
		log "killing PID $pids, which is using device $this_dev"
		kill $pids
	fi
done

if [ $no_kill -ne 1 ]; then
	# completely kill and remove old ovs configuration
	log "stopping ovs"
	killall -q -w ovs-vswitchd
	killall -q -w ovsdb-server
	killall -q -w ovsdb-server ovs-vswitchd
	log "stopping testpmd"
	killall -q -w testpmd
	rm -rf $ovs_run/ovs-vswitchd.pid
	rm -rf $ovs_run/ovsdb-server.pid
	rm -rf $ovs_etc/*db*
fi


# initialize the devices
case $dataplane in
	dpdk)
	log "Initializing devices to use DPDK as the dataplane"
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
	for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
		dev_numa_node=`cat /sys/bus/pci/devices/$(get_dev_loc $this_dev)/numa_node`
		if [ $dev_numa_node -eq -1 ]; then
			dev_numa_node=0
		fi
		log "device $this_dev node is $dev_numa_node"
		local_socket_mem[$dev_numa_node]=1024
	done
	log "local_socket_mem: ${local_socket_mem[@]}"
	local_socket_mem_opt=""
        all_socket_mem_opt=""
	for mem in "${local_socket_mem[@]}"; do
		log "mem: $mem"
		local_socket_mem_opt="$local_socket_mem_opt,$mem"
		all_socket_mem_opt="$all_socket_mem_opt,1024"
	done
        local_numa_nodes=""
        local_nodes_cpus_list=""
	for node in "${!local_socket_mem[@]}"; do
		if [ "${local_socket_mem[$node]}" == "1024" ]; then
			local_numa_nodes="$local_numa_nodes,$node"
			local_node_cpus_list=`node_cpus_list $node`
			local_nodes_cpus_list=`add_to_list "$local_nodes_cpus_list" "$local_node_cpus_list"`
		fi
	done
	local_nodes_non_iso_cpus_list=`sub_from_list "$local_nodes_cpus_list" "$iso_cpus_list"`
	local_numa_nodes=`echo $local_numa_nodes | sed -e 's/^,//'`
	log "local_numa_nodes: $local_numa_nodes"
	local_socket_mem_opt=`echo $local_socket_mem_opt | sed -e 's/^,//'`
	log "local_socket_mem_opt: $local_socket_mem_opt"
	all_socket_mem_opt=`echo $all_socket_mem_opt | sed -e 's/^,//'`
	log "all_socket_mem_opt: $all_socket_mem_opt"
	
	all_cpus_range=`cat /sys/devices/system/cpu/online`
	all_cpus_list=`convert_number_range $all_cpus_range`
	all_nodes_non_iso_cpus_list=`sub_from_list $all_cpus_list $iso_cpus_list`
	log "isol cpus_list is $iso_cpus_list"
	log "all-nodes-non-isolated cpus list is $all_nodes_non_iso_cpus_list"

	# load modules and bind Ethernet cards to dpdk modules
	for kmod in vfio vfio-pci; do
		if lsmod | grep -q $kmod; then
			log "not loading $kmod (already loaded)"
		else
			if modprobe -v $kmod; then
				log "loaded $kmod module"
			else
				exit_error "Failed to load $kmmod module, exiting" ""
			fi
		fi
	done

	log "DPDK devs: $devs"
	# bind the devices to dpdk module
	declare -A pf_num_netdevs
	for this_pf_loc in $(get_devs_locs $devs); do
		driverctl unset-override $this_pf_loc
		log "unbinding module from $this_pf_loc"
		dpdk-devbind.py --unbind $this_pf_loc
		log "binding $kernel_nic_kmod to $this_pf_loc"
		dpdk-devbind.py --bind $kernel_nic_kmod $this_pf_loc
		num_netdevs=0
		if [ -e /sys/bus/pci/devices/"$this_pf_loc"/net/ ]; then
			for netdev in `get_dev_netdevs $this_pf_loc`; do
				log "taking down link on $netdev"
				ip link set dev $netdev down
				((num_netdevs++))
			done
			# this info might be needed later and it not readily available
			# once the kernel nic driver is not bound
			pf_num_netdevs["$this_pf_loc"]=$num_netdevs
		else
			# some devices don't have /sys/bus/pci/devices/$this_pf_loc/net/a so assume they have 1 netdev
			pf_num_netdevs["$this_pf_loc"]=1
		fi
		log "unbinding $kernel_nic_kmod from $this_pf_loc"
		dpdk-devbind.py --unbind $this_pf_loc
		log "binding $dpdk_nic_kmod to $this_pf_loc"
		dpdk-devbind.py --bind $dpdk_nic_kmod $this_pf_loc
	done
	;;
	kernel*)
	log "Initializing devices to use the Linux kernel as the dataplane"
	# bind the devices to kernel module
	eth_devs=""
	if [ ! -e /sys/module/$kernel_nic_kmod ]; then
		log "loading kenrel module $kernel_nic_kmod"
		modprobe $kernel_nic_kmod || exit_error "Kernel module load failed" ""
	fi
	for this_pf_loc in $(get_devs_locs $devs); do
		dpdk-devbind --unbind $this_pf_loc
		dpdk-devbind --bind $kernel_nic_kmod $this_pf_loc
		if [ ! -e /sys/bus/pci/drivers/$kernel_nic_kmod/$this_pf_loc/sriov_numvfs ]; then
			exit_error "Could not find /sys/bus/pci/drivers/$kernel_nic_kmod/$this_pf_loc/sriov_numvfs, exiting" ""
		fi
		log "pci $this_pf_loc num VFs:"
		cat /sys/bus/pci/drivers/$kernel_nic_kmod/$this_pf_loc/sriov_numvfs
		udevadm settle
		if [ -e /sys/bus/pci/devices/"$this_pf_loc"/net/ ]; then
			eth_dev=`/bin/ls /sys/bus/pci/devices/"$this_pf_loc"/net/ | head -1`
			eth_devs="$eth_devs $eth_dev"
		else
			exit_error "Could not get kernel driver to init on device $this_pf_loc" ""
		fi
	done
	echo ethernet devices: $eth_devs
	;;
esac

# configure the vSwitch
log "configuring the vswitch: $switch"

case $switch in
linuxbridge) #switch configuration
	case $topology in
		"pp")   # 10GbP1<-->10GbP2
		phy_br="phy-br-0"

		if /bin/ls /sys/class/net | grep -q ^$phy_br; then
			ip l s $phy_br down
			brctl delbr $phy_br
		fi

		brctl addbr $phy_br
		ip l set dev $phy_br up
		pf_count=1

		for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
			pf_eth_name=`get_pf_eth_name "$this_dev"` || exit_error "could not find a netdev name for $this_pf_location" ""
			log "pf_eth_name: $pf_eth_name"
			ip l set dev $pf_eth_name up
			brctl addif $phy_br $pf_eth_name
			((pf_count++))
		done
		;;

		pvp|pv,vp)   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
		# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
		for i in `seq 0 1`; do
			eth_dev=`echo $eth_devs | awk '{print $1}'`
			eth_devs=`echo $eth_devs | sed -e s/$eth_dev//`

			if [ "$overlay_network" == "vxlan" ]; then
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
			else # no overlay network
				phy_br="phy-br-$i"

				if /bin/ls /sys/class/net | grep -q ^$phy_br; then
					ip l s $phy_br down
					brctl delbr $phy_br
				fi

				brctl addbr $phy_br
				ip l set dev $phy_br up
				ip l set dev $eth_dev up
				brctl addif $phy_br $eth_dev
			fi
		done
		;;
	esac
	;;
ovs) #switch configuration
	ovs_ver=`$ovs_sbin/ovs-vswitchd --version | awk '{print $4}'`
        if [ $use_ovs_systemd_services -eq 0 ]; then
		DB_SOCK="$ovs_run/db.sock"
		log "starting ovs (ovs_ver=${ovs_ver})"
		mkdir -p $ovs_run
		mkdir -p $ovs_etc
		log "Initializing the OVS configuration database at $ovs_etc/conf.db using 'ovsdb-tool create'..."
		$ovs_bin/ovsdb-tool create $ovs_etc/conf.db /usr/share/openvswitch/vswitch.ovsschema
		log "Starting the OVS configuration database process ovsdb-server and connecting to Unix socket $DB_SOCK..." 
		$ovs_sbin/ovsdb-server -v --remote=punix:$DB_SOCK \
		--remote=db:Open_vSwitch,Open_vSwitch,manager_options \
		--pidfile --detach || exit_error "failed to start ovsdb" ""
		/bin/rm -f /var/log/openvswitch/ovs-vswitchd.log

		log "Now intialize the OVS database using 'ovs-vsctl --no-wait init' ..."
		$ovs_bin/ovs-vsctl --no-wait init
		log "starting ovs-vswitchd"
	else
		log "Using systemd services to initialize OVS database and server daemon"
	fi
	case $dataplane in
	"dpdk")
		if echo $ovs_ver | grep -q "^2\.6\|^2\.7\|^2\.8\|^2\.9\|^2\.10\|^2\.11\|^2\.12\|^2\.13\|^2\.14\|^2\.15\|^2\.16\|^2\.17\|^3\.2\.3\|^3\.3\|^3\.4"; then
			dpdk_opts=""
			log "BILL init DPDK"
			#
			# Specify OVS should support DPDK ports
			#
			$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
			#$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:vhost-sock-dir=/tmp

			#
			# Enable Vhost IOMMU feature which restricts memory that a virtio device can access.  
			# Setting 'vfio-iommu-support' to 'true' enable vhost IOMMU support for all vhost ports 
			# 
			$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:vhost-iommu-support=true

			log "BILL - Local NUMA node non-isolated CPUs list: $local_nodes_non_iso_cpus_list"
			log "BILL - OVS setting other_config:dpdk-lcore-mask = `get_cpumask $local_nodes_non_iso_cpus_list`"

			#
			# Note both dpdk-socket-mem and dpdk-lcore-mask should be set before dpdk-init is set to 
			# true (OVS 2.7) or OVS-DPDK is started (OVS 2.6)
			#

			echo "local_nodes_non_iso_cpus_list = $local_nodes_non_iso_cpus_list" > seemask.txt
                        mask_all_nodes_non_iso_cpus_list=`get_cpumask $local_nodes_non_iso_cpus_list` 
			echo "mask_all_nodes_non_iso_cpus_list = $mask_all_nodes_non_iso_cpus_list" >> seemask.txt
                        #log "mask_all_nodes_non_iso_cpus_list = $mask_all_nodes_non_iso_cpus_list"
			case $numa_mode in
			strict)
				log "NUMA setting is strict"
				log "OVS setting other_config:dpdk-socket-mem = $local_socket_mem_opt"
				$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="$local_socket_mem_opt"
				#$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask=0x1000000010000000100000001
				#$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask="`get_cpumask $local_nodes_non_iso_cpus_list`"
				;;
			preferred)
				log "NUMA setting is perferred"
				$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="$all_socket_mem_opt"
				#$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask=0x1000000010000000100000001
				#$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask=$mask_all_nodes_non_iso_cpus_list
				#$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-extra="--lcores 0@32,1@160,2@33,4@161"
				;;
			cross)
				log "NUMA setting is cross"
				$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="$all_socket_mem_opt"
				$ovs_bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-lcore-mask=$mask_all_nodes_non_iso_cpus_list
				;;
			esac
		else
			log "Starting with --dpdk option"
			dpdk_opts="--dpdk -n 4 --socket-mem $local_socket_mem_opt --"
		fi


		#
		# umask 002 changes the default file creation mode for the ovs-vswitchd process to itself and its group.
		#
		# su -g qemu changes the default group the ovs-vswitchd process runs as part of to the same group as the qemu process.
		#
		# The sudo causes the ovs-vswitchd process to run as the root user.  sudo support setting the group with the -g flag directly so su is not needed.
		#
		# The result of combining these commands is that all vhost-user socket created by OVS will be owned by the root user and the 
		# Libvirt-qemu users group (previously "libvirt-qemu" now "kvm")
		# 

		#
		# umask 002 changes the default file creation mode for the ovs-vswitchd process to itself and its group.
		#
		# su -g qemu changes the default group the ovs-vswitchd process runs as part of to the same group as the qemu process.
		#
		# The sudo causes the ovs-vswitchd process to run as the root user.  sudo support setting the group with the -g flag directly so su is not needed.
		#
		# The result of combining these commands is that all vhost-user socket created by OVS will be owned by the root user and the 
		# qemu users group
		# 
		# For example, if we start ovs-vswitchd daemon without above commands, we get the file permissions as follows:
		#
		#
		# numactl --cpunodebind=$local_numa_nodes $ovs_sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach
		# 
		# ls /var/run/openvswitch/ -ltra
		# 
		# total 8
		# drwxr-xr-x 36 root root  ..
		# -rw-r--r--  1 root root  ovsdb-server.pid
		# srwxr-x---  1 root root  db.sock
		# srwxr-x---  1 root root  ovsdb-server.53200.ctl
		# -rw-r--r--  1 root root  ovs-vswitchd.pid
		# srwxr-x---  1 root root  ovs-vswitchd.53229.ctl
		# drwxr-xr-x  2 root root  .
		# 
		# Note group is owned by root, and ovs-vswitchd.pid and ovs-vswitchd.53229.ctl do not have the group 'w' bit set.  
		# 
		# Creating the rest of the OVS related sockets, we see the same ownership and permissions issue:
		# 
		# srwxr-x---  1 root root phy-br-0.snoop
		# srwxr-x---  1 root root phy-br-0.mgmt
		# srwxr-xr-x  1 root root vm0-vhu-0-n0
		# srwxr-x---  1 root root phy-br-1.mgmt
		# srwxr-x---  1 root root phy-br-1.snoop
		# srwxr-xr-x  1 root root vm0-vhu-1-n0
		# 
		# When this occurs, the VM will fail to start (virsh start ....) because of the socket permissions.
		# 
		# What we want is to use this:
		# 
		# sudo su -g qemu -c "umask 002; numactl --cpunodebind=$local_numa_nodes $ovs_sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach"
		# 
		# which will eventually yield the following (not the group qemu and group 'w' permissions:
		# 
		# -rw-r--r--  1 root root ovsdb-server.pid
		# srwxr-x---  1 root root db.sock
		# srwxr-x---  1 root root ovsdb-server.18481.ctl
		# -rw-rw-r--  1 root qemu ovs-vswitchd.pid
		# srwxrwx---  1 root qemu ovs-vswitchd.18515.ctl
		# srwxrwx---  1 root qemu phy-br-0.snoop
		# srwxrwx---  1 root qemu phy-br-0.mgmt
		# srwxrwxr-x  1 root qemu vm0-vhu-0-n0
		# srwxrwx---  1 root qemu phy-br-1.mgmt
		# srwxrwx---  1 root qemu phy-br-1.snoop
		# srwxrwxr-x  1 root qemu vm0-vhu-1-n0
		# 
		# and therefore allow the VM to start successfully
		# 
        	if [ $use_ovs_systemd_services -eq 0 ]; then
			case $numa_mode in
			strict)
				log "Using strict NUMA configuration mode when starting OVS: local_numa_nodes = $local_numa_nodes"
				sudo su -g qemu -c "umask 002; numactl --cpunodebind=$local_numa_nodes $ovs_sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach"
				#numactl --cpunodebind=$local_numa_nodes $ovs_sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach
				;;
			preferred)
				log "Using preferred NUMA configuration mode when starting OVS:"
				#log "BILL - dpdk_opts = $dpdk_opts"
				#log "BILL - DB_SOCK = $DB_SOCK"
				#sleep 5
				#exit
				sudo su -g qemu -c "umask 002; $ovs_sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach"
				;;
			esac
		fi

		rc=$?
		;;
	esac

	if [ $rc -ne 0 ]; then
		exit_error "Aborting since openvswitch did not start correctly. Openvswitch exit code: [$rc]" ""
	fi
	
	log "waiting for ovs to init"
	$ovs_bin/ovs-vsctl --no-wait init

	if [ "$dataplane" == "dpdk" ]; then
		if echo $ovs_ver | grep -q "^2\.6\|^2\.7\|^2\.8\|^2\.9\|^2\.10\|^2\.11\|^2\.12\|^2\.13\|^2\.14\|^2\.15\|^2\.16\|^2\.17\|^3\.2\.3\|^3\.3\|^3\.4"; then
			pci_devs=`get_devs_locs $devs`

			ovs_dpdk_interface_0_name="dpdk-0"
			#pci_dev=`echo ${devs} | awk -F, '{ print $1}'`
			pci_dev=`echo $pci_devs | awk '{print $1}'`
			ovs_dpdk_interface_0_args="options:dpdk-devargs=${pci_dev}"
			log "ovs_dpdk_interface_0_args[$ovs_dpdk_interface_0_args]"

			ovs_dpdk_interface_1_name="dpdk-1"
			#pci_dev=`echo ${devs} | awk -F, '{ print $2}'`
			pci_dev=`echo $pci_devs | awk '{print $2}'`
			ovs_dpdk_interface_1_args="options:dpdk-devargs=${pci_dev}"
			log "ovs_dpdk_interface_1_args[$ovs_dpdk_interface_1_args]"
		else
			ovs_dpdk_interface_0_name="dpdk0"
			ovs_dpdk_interface_0_args=""
			ovs_dpdk_interface_1_name="dpdk1"
			ovs_dpdk_interface_1_args=""
		fi
	
		log "configuring ovs with network topology: $topology"

		case $topology in
		pvp|pv,vp)   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
			# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
			vhost_ports=""
			ifaces=""
			for i in `seq 0 1`; do
				phy_br="phy-br-$i"
				pci_dev_index=$(( i + 1 ))
				pci_dev=`echo ${devs} | awk -F, "{ print \\$${pci_dev_index}}"`
				#pci_dev=`echo "$pci_dev" | sed 's/..$//'`
				pci_node=`cat /sys/bus/pci/devices/"$pci_dev"/numa_node`

				if [ "$vhost_affinity" == "local" ]; then
					vhost_port="vhost-user-$i-n$pci_node"
				else # use a non-local node
					remote_pci_nodes=`sub_from_list $node_list $pci_node`
					remote_pci_node=`echo $remote_pci_nodes | awk -F, '{print $1}'`
					vhost_port="vhost-user-$i-n$remote_pci_node"
				fi

				log "vhost_port: $vhost_port"
				vhost_ports="$vhost_ports,$vhost_port"

		        if echo $ovs_ver | grep -q "^2\.6\|^2\.7\|^2\.8\|^2\.9\|^2\.10\|^2\.11\|^2\.12\|^2\.13\|^2\.14\|^2\.15\|^2\.16\|^2\.17\|^3\.2\.3\|^3\.3\|^3\.4"; then
					phys_port_name="dpdk-${i}"
					phys_port_args="options:dpdk-devargs=${pci_dev}"
				else
					phys_port_name="dpdk$i"
					phys_port_args=""
				fi

				$ovs_bin/ovs-vsctl --if-exists del-br $phy_br
				$ovs_bin/ovs-vsctl add-br $phy_br -- set bridge $phy_br datapath_type=netdev
				$ovs_bin/ovs-vsctl add-port $phy_br ${phys_port_name} -- set Interface ${phys_port_name} type=dpdk ${phys_port_args}
				ifaces="$ifaces,${phys_port_name}"
				phy_ifaces="$ifaces,${phys_port_name}"

				$ovs_bin/ovs-vsctl add-port $phy_br $vhost_port -- set Interface $vhost_port type=dpdkvhostuserclient options:vhost-server-path=/tmp/$vhost_port
				#$ovs_bin/ovs-vsctl add-port $phy_br $vhost_port -- set Interface $vhost_port type=dpdkvhostuserclient options:vhost-server-path=/var/run/openvswitch/$vhost_port
				ifaces="$ifaces,$vhost_port"
				vhu_ifaces="$ifaces,$vhost_port"

				if [ ! -z "$vhu_desc_override" ]; then
					echo "overriding vhostuser descriptors/queue with $vhu_desc_override"
					$ovs_bin/ovs-vsctl set Interface $vhost_port options:n_txq_desc=$vhu_desc_override
					$ovs_bin/ovs-vsctl set Interface $vhost_port options:n_rxq_desc=$vhu_desc_override
				fi

				$ovs_bin/ovs-ofctl del-flows $phy_br
				set_ovs_bridge_mode $phy_br ${switch_mode}
			done

			ifaces=`echo $ifaces | sed -e s/^,//`
			vhost_ports=`echo $vhost_ports | sed -e 's/^,//'`
			ovs_ports=4
			;;
		"pp")  # 10GbP1<-->10GbP2
			# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
			log "BILL PP"
			$ovs_bin/ovs-vsctl --if-exists del-br ovsbr0
			$ovs_bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
			echo "ovs_dpdk_interface_0_name = $ovs_dpdk_interface_0_name"
			echo "ovs_dpdk_interface_0_args = $ovs_dpdk_interface_0_args"
			echo "ovs_dpdk_interface_1_name = $ovs_dpdk_interface_1_name"
			echo "ovs_dpdk_interface_1_args = $ovs_dpdk_interface_1_args"

			$ovs_bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_0_name} -- set Interface ${ovs_dpdk_interface_0_name} type=dpdk ${ovs_dpdk_interface_0_args}
			$ovs_bin/ovs-vsctl add-port ovsbr0 ${ovs_dpdk_interface_1_name} -- set Interface ${ovs_dpdk_interface_1_name} type=dpdk ${ovs_dpdk_interface_1_args}
			$ovs_bin/ovs-ofctl del-flows ovsbr0
			set_ovs_bridge_mode ovsbr0 ${switch_mode}
			ovs_ports=2
			;;
		esac
                
		log "using $queues queue(s) per port"
		$ovs_bin/ovs-vsctl set interface ${ovs_dpdk_interface_0_name} options:n_rxq=$queues
		$ovs_bin/ovs-vsctl set interface ${ovs_dpdk_interface_1_name} options:n_rxq=$queues
		
		if [ ! -z "$pci_desc_override" ]; then
			log "overriding PCI descriptors/queue with $pci_desc_override"
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_txq_desc=$pci_desc_override
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_rxq_desc=$pci_desc_override
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_txq_desc=$pci_desc_override
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_rxq_desc=$pci_desc_override
		else
			log "setting PCI descriptors/queue with $pci_descriptors"
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_txq_desc=$pci_descriptors
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_0_name} options:n_rxq_desc=$pci_descriptors
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_txq_desc=$pci_descriptors
			$ovs_bin/ovs-vsctl set Interface ${ovs_dpdk_interface_1_name} options:n_rxq_desc=$pci_descriptors
		fi
		
		#configure the number of PMD threads to use
		pmd_threads=`echo "$ovs_ports * $queues" | bc`

		log "using a total of $pmd_threads PMD threads"
		pmdcpus=""
		case $topology in
		"pp")  # 10GbP1<-->10GbP2
			vhost_ports=""
			log "BILL1 PP"
		esac
		log "BILL3"
		echo "devs = $devs"
		echo "vhost_ports = $vhost_ports"
		echo "queues = $queues"

		pmdcpus=`get_pmd_cpus "$devs,$vhost_ports" $queues "ovs-pmd"`

		if [ -z "$pmdcpus" ]; then
			exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUMA nodes?" ""
		fi

		pmd_cpu_mask=`get_cpumask $pmdcpus`

		#vm_cpus=`sub_from_list $ded_cpus_list $pmdcpus`
		#log "vm_cpus is [$vm_cpus]"
		log "BILL pmd_cpu_mask = $pmd_cpu_mask"
		$ovs_bin/ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$pmd_cpu_mask

		#if using HT, bind 1 PF and 1 VHU to same core
		if [ "$use_ht" == "y" ]; then
			iface=""
			#ifaces=""
			while [ ! -z "$pmdcpus" ]; do
				this_cpu=`echo $pmdcpus | awk -F, '{print $1}'`
				echo "this_cpu = $this_cpu"
				cpu_siblings_range=`cat /sys/devices/system/cpu/cpu$this_cpu/topology/thread_siblings_list`
				echo "cpu_siblings_range = $cpu_siblings_range"
				cpu_siblings_list=`convert_number_range $cpu_siblings_range`
				echo "cpu_siblings_list = $cpu_siblings_list"
				pmdcpus=`sub_from_list $pmdcpus $cpu_siblings_list`
				while [ ! -z "$cpu_siblings_list" ]; do
				this_cpu_thread=`echo $cpu_siblings_list | awk -F, '{print $1}'`
				cpu_siblings_list=`sub_from_list $cpu_siblings_list $this_cpu_thread`
				iface=`echo $ifaces | awk -F, '{print $1}'`
				ifaces=`echo $ifaces | sed -e s/^$iface,//`
				echo "this_cpu_thread = $this_cpu_thread"
				log "$ovs_bin/ovs-vsctl set Interface $iface other_config:pmd-rxq-affinity=0:$this_cpu_thread"
				if [ ! -z "$iface" ]; then
					$ovs_bin/ovs-vsctl set Interface $iface other_config:pmd-rxq-affinity=0:$this_cpu_thread
				fi
			done
		done
		fi

		#log "PMD cpumask command: ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$pmd_cpu_mask"
		log "PMD thread assignments:"
		$ovs_bin/ovs-appctl dpif-netdev/pmd-rxq-show
	
	else #dataplane=kernel-hw-offload
		log "configuring ovs with network topology: $topology"
		case $topology in
			pvp|pv,vp)
			# create the bridges/ports with 1 phys dev and 1 representer dev per bridge

			log "Deleting any existing bridges"
			for this_pf_loc in `get_devs_locs $devs`; do
				for netdev in `get_dev_netdevs $this_pf_loc`; do
					$ovs_bin/ovs-vsctl --if-exists del-br phy-br-$netdev
				done
			done

			log "Cleaning out the udev rules for the representer devices"
			rules=/etc/udev/rules.d/ovs_offload.rules
			if [ -e $rules ]; then
				/bin/rm -rf $rules
			fi

			for this_pf_loc in `get_devs_locs $devs`; do
				num_vfs=0
				for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
					this_dev_loc=`get_dev_loc $this_dev`
					if [ "$this_pf_loc" == "$this_dev_loc" ]; then
						((num_vfs++))
						#((num_vfs++))
					fi
				done
				echo "0" >/sys/bus/pci/devices/$this_pf_loc/sriov_numvfs || exit_error "Could not set number of VFs to 0: /sys/bus/pci/devices/$this_pf_loc/sriov_numvfs" ""
				echo "$num_vfs" >/sys/bus/pci/devices/$this_pf_loc/sriov_numvfs || exit_error "Could not set number of VFs to $num_vfs: /sys/bus/pci/devices/$this_pf_loc/sriov_numvfs" ""
			done

			log "Unbinding all the VFs from their kernel driver"
			# this is necessary before enabling switchdev
			for this_pf_loc in `get_devs_locs $devs`; do
				log "  for physical function at location $this_pf_loc"
				for i in `/bin/ls /sys/bus/pci/devices/$this_pf_loc/ | grep virtfn`; do
					vf_dev=`readlink /sys/bus/pci/devices/$this_pf_loc/$i | sed -e 'sX../XX'`
					log "    unbinding VF at pci locaiton $vf_dev"
					echo $vf_dev >/sys/bus/pci/drivers/$kernel_nic_kmod/unbind
				done
			done

			#log "Creating new udev rules for the representer devices (switchdev devices):"
			## switchdev device names should look like "p4p1_sd_0"
			#for this_pf_loc in `get_devs_locs $devs`; do
				#eth_dev=`/bin/ls /sys/bus/pci/devices/$this_pf_loc/net | head -1`
				#sw_id=`ip -d l show dev $eth_dev | grep 'link/ether' | sed -e 's/.*switchid //' | awk '{print $1}'`
			#done
			#udevadm control --reload

			log "Changing to switchdev mode for the PFs"
			# this will create the representer devices for the VFs
			for this_pf_loc in `get_devs_locs $devs`; do
				mode=`devlink dev eswitch show pci/$this_pf_loc | awk '{print $3}'`
				if [ "$mode" != "switchdev" ]; then
					devlink dev eswitch set pci/$this_pf_loc mode switchdev
				fi
			done
			udevadm settle

			log "Binding the VFs to their driver"
			# vf device names should look like "p4p1_0"
			for this_pf_loc in `get_devs_locs $devs`; do
				log "  for physical function at location $this_pf_loc"
				for i in `/bin/ls /sys/bus/pci/devices/$this_pf_loc/ | grep virtfn`; do
					vf_dev=`readlink /sys/bus/pci/devices/$this_pf_loc/$i | sed -e 'sX../XX'`
					log "    binding VF to $kernel_nic_kmod at pci locaiton $vf_dev"
					echo $vf_dev >/sys/bus/pci/drivers/$kernel_nic_kmod/bind
				done
			done
			udevadm settle
			vf_eth_names=""
			vf_devs=""
			log "\nEnabling the hw offload feature on PFs and switchdevs\n"
			pf_count=1
			#for pf_loc in `get_devs_locs $devs`; do
			for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
				pf_loc=`get_dev_loc $this_dev`
				log "  working on this device: $this_dev"
				dev_netdev_name=`get_dev_netdev $this_dev`
				log "  netdev name for this device: $dev_netdev_name"
				log "  checking if hw-tc-offload is enabled for: $dev_netdev_name"
				hw_tc_offload=`ethtool -k $dev_netdev_name | grep hw-tc-offload | awk '{print $2}'`
				if [ "$hw_tc_offload" == "off" ]; then
					ethtool -K $dev_netdev_name hw-tc-offload on
				fi
				dev_sw_id=`get_switch_id $dev_netdev_name` || exit_error "  could not find a switch ID for $dev_netdev_name" ""
				log "  switch ID for this device: $dev_sw_id"
				port_id=`get_dev_port $this_dev`
				vf_loc=`readlink /sys/bus/pci/devices/$pf_loc/virtfn$port_id | sed -e 'sX../XX'` # the PCI location of the VF
				log "  virtual function's PCI locaton that's used from this device: $vf_loc"
				if [ $rhel_major_version -eq 8 ]; then
					vf_eth_name=`/bin/ls /sys/bus/pci/devices/"$vf_loc"/net | grep "$dev_netdev_name"`
				else
					vf_eth_name=`/bin/ls /sys/bus/pci/devices/"$vf_loc"/net | grep "_$port_id"`
				fi
				log "  netdev name for this virtual function: $vf_eth_name"
				sd_eth_name=`get_sd_netdev_name $this_dev` || exit_error "  could not find a representor device for $this_dev ($dev_eth_name)" ""
				log "  netdev name for the switchdev (representor) device: $sd_eth_name"
				log "  Checking if hw-tc-offload is enabled for for switchdev (representor) netdev:  $sd_eth_name"
				hw_tc_offload=`ethtool -k $sd_eth_name | grep hw-tc-offload | awk '{print $2}'`
				if [ "$hw_tc_offload" == "off" ]; then
					ethtool -K $sd_eth_name hw-tc-offload on
				fi
				bridge_name="br-${dev_netdev_name}"
				log "  creating OVS bridge: $bridge_name with devices $dev_netdev_name and $sd_eth_name"
				$ovs_bin/ovs-vsctl add-br $bridge_name || exit
				ip l s $bridge_name up || exit
				$ovs_bin/ovs-vsctl add-port $bridge_name $dev_netdev_name || exit
				ip l s $dev_netdev_name up || exit
				$ovs_bin/ovs-vsctl add-port $bridge_name $sd_eth_name || exit
				ip l s $sd_eth_name up || exit
				set_ovs_bridge_mode $bridge_name $switch_mode || exit
				ip l s $vf_eth_name up || exit
				ip link s $vf_eth_name promisc on || exit
				vf_eth_names="$vf_eth_names $vf_eth_name"
				vf_devs="$vf_devs $vf_loc"
				log "  ovs bridge $bridge_name has PF $dev_netdev_name and representor $sd_eth_name, which represents VF $vf_eth_name"
				((pf_count++))
			# Is there a netdev for the PF which has no port name?  If there is, it needs its "link" up
			pf_eth_name=""
			pf_eth_name=`get_dev_netdev "$pf_loc" ""`
			if [ $? -eq 0 ]; then 
				echo "setting link up on $pf_eth_name"
				ip l s $pf_eth_name up
			fi
			done
			log  "Note: you must bridge these VF devices in order to complete the PVP topology: $vf_eth_names ($vf_devs)"
			;;
		esac
	fi
	;;
testpmd) #switch configuration
	if [ ! -e ${testpmd_path} -o ! -x "${testpmd_path}" ]; then
		exit_error "testpmd_path: [${testpmd_path}] does not exist or is not exexecutable" ""
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
		i=0
		pci_location_arg=""
		portmask=0
		portnum_base=0
		# build the "-w" option for DPDK (the whitelist of PCI locations)
		for pf_loc in `get_devs_locs $devs`; do
			pci_location_arg="$pci_location_arg -w $pf_loc"

			# also build the port bitmask
			for this_dev in `echo $devs | sed -e 's/,/ /g'`; do
				if [ "$(get_dev_loc $this_dev)" == "$pf_loc" ]; then
					this_portnum=`echo "$(get_dev_port $this_dev) + $portnum_base" | bc`
					portmask=`echo "$portmask + 2^$this_portnum" | bc`
				fi
			done

			portnum_base=`echo "$portnum_base + ${pf_num_netdevs[$pf_loc]}" | bc`
		done

		log "use_ht: [$use_ht]"
		pmd_cpus=`get_pmd_cpus "$devs" "$queues" "testpmd-pmd"`
        log "This is a test"

		if [ -z "$pmd_cpus" ]; then
			exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUAM nodes?" ""
		fi

		pmd_cpu_mask=`get_cpumask $pmd_cpus`
		log "pmd_cpu_list is [$pmd_cpus]"
		log "pmd_cpu_mask is [$pmd_cpu_mask]"
		rss_flags=""

		if [ $queues -gt 1 ]; then
			rss_flags="--rss-ip --rss-udp"
		fi

		log "kernel_nic_kmod: $kernel_nic_kmod"
		if [ $kernel_nic_kmod == "nfp" ]; then
			vlan_opts="--disable-hw-vlan"
		else
			vlan_opts=""
		fi

		testpmd_cmd="${testpmd_path} -l $console_cpu,$pmd_cpus --socket-mem $testpmd_socket_mem_opt -n 4\
		  --proc-type auto --file-prefix testpmd$i $pci_location_arg\
                  --\
		  $testpmd_numa --nb-cores=$pmd_threads\
		  --nb-ports=2 --portmask=$portmask --auto-start --rxq=$queues --txq=$queues ${rss_flags}\
		  --rxd=$testpmd_descriptors --txd=$testpmd_descriptors $vlan_opts >/tmp/testpmd-$i"
		log "testpmd_cmd: $testpmd_cmd"
		echo $testpmd_cmd >/tmp/testpmd-$i-cmd.txt
		screen -dmS testpmd-$i bash -c "$testpmd_cmd"
		ded_cpus_list=`sub_from_list $ded_cpus_list $pmd_cpus`
		;;
	pvp|pv,vp)
		mkdir -p /var/run/openvswitch
		testpmd_ports=2
		pmd_threads=`echo "$testpmd_ports * $queues" | bc`
		log "use_ht: [$use_ht]"
		for i in `seq 0 1`; do
			pci_dev_index=$(( i + 1 ))
			pci_dev=`echo ${devs} | awk -F, "{ print \\$${pci_dev_index}}"`
			pci_loc=`get_dev_loc $pci_dev`
			pci_node=`cat /sys/bus/pci/devices/"$pci_loc"/numa_node`
			vhost_port="/var/run/openvswitch/vhost-user-$i-n$pci_node"

			if [ "$vhost_affinity" == "local" ]; then
				vhost_port="/var/run/openvswitch/vhost-user-$i-n$pci_node"
			else # use a non-local node
				remote_pci_nodes=`sub_from_list $node_list $pci_node`
				remote_pci_node=`echo $remote_pci_nodes | awk -F, '{print $1}'`
				vhost_port="/var/run/openvswitch/vhost-user-$i-n$remote_pci_node"
			fi

			pmd_cpus=`get_pmd_cpus "$pci_loc,$vhost_port" $queues "testpmd-pmd"`
            log "This is a test1"
			if [ -z "$pmd_cpus" ]; then
				exit_error "Could not allocate PMD threads.  Do you have enough isolated cpus in the right NUAM nodes?" ""
			fi

			#log_cpu_usage "$pmd_cpus" "testpmd-pmd"
			pmd_cpu_mask=`get_cpumask $pmd_cpus`
			log "pmd_cpu_list is [$pmd_cpus]"
			log "pmd_cpu_mask is [$pmd_cpu_mask]"
			rss_flags=""

			if [ $queues -gt 1 ]; then
			    rss_flags="--rss-ip --rss-udp"
			fi

			echo kernel_nic_kmod: $kernel_nic_kmod
			if [ $kernel_nic_kmod == "nfp" ]; then
				vlan_opts="--disable-hw-vlan"
			else
				vlan_opts=""
			fi
			testpmd_cmd="${testpmd_path} -l $console_cpu,$pmd_cpus --socket-mem $testpmd_socket_mem_opt -n 4\
			  --proc-type auto --file-prefix testpmd$i -w $pci_loc --vdev eth_vhost0,iface=$vhost_port -- --nb-cores=$pmd_threads\
			  $testpmd_numa --nb-ports=2 --portmask=3 --auto-start --rxq=$queues --txq=$queues ${rss_flags}\
			  --rxd=$testpmd_descriptors --txd=$testpmd_descriptors $vlan_opts >/tmp/testpmd-$i"
			log "testpmd_cmd: $testpmd_cmd"
			echo $testpmd_cmd >/tmp/testpmd-$i-cmd.txt
			screen -dmS testpmd-$i bash -c "$testpmd_cmd"
			count=0

			while [ ! -e $vhost_port -a $count -le 30 ]; do
				echo "waiting for $vhost_port"
				sleep 1
				((count+=1))
			done

			chmod 777 $vhost_port || exit_error "could not chmod 777 $vhost_port" ""
			#ded_cpus_list=`sub_from_list $ded_cpus_list $pmd_cpus`
		done
		;;
	esac
esac
