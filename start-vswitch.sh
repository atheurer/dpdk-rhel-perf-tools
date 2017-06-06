#!/bin/bash

# defaults
topology="pp" # two physical devices on one switch
queues=1 # queues: Number of queue-pairs (rx/tx) to use per device
switch="ovs" # switch: Currently supported is: testpmd, ovs, linuxbridge, linuxrouter
overlay="none" # overlay: Currently supported is: none (for all switch types) and vxlan (for linuxbridge and ovs)
prefix="" # prefix: the path prepended to the calls to operate ovs.  use "" for ovs RPM and "/usr/local" for src built OVS
dpdk_nic_kmod="vfio-pci" # dpdk-devbind: the kernel module to use when assigning a network device to a userspace program (DPDK application)
dataplane="dpdk"
use_ht="y"
testpmd_ver="v17.05"


# Process options and arguments
opts=$(getopt -q -o i:c:t:r:m:p:M:S:C:o --longoptions "devices:,nr-queues:,use-ht:,overlay:,topology:,dataplane:,switch:" -n "getopt.sh" -- "$@")
if [ $? -ne 0 ]; then
	printf -- "$*\n"
	printf "\n"
	printf "\t${benchmark_name}: you specified an invalid option\n\n"
	printf "\tThe following options are available:\n\n"
	#              1   2         3         4         5         6         7         8         9         0         1         2         3
	#              678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012
	printf -- "\t\t             --devices=str,str          two PCI locations of Ethenret adapters to use, like --devices=0000:83:00.0,0000:86:00.0\n"
	printf -- "\t\t             --nr-queues=int            the number of queues per device\n"
	printf -- "\t\t             --use-ht=[y|n]             y=use both cpu-threads on HT core, n=only use 1 cpu-thread per core\n"
	printf -- "\t\t                                        Using HT has better per/core throuhgput, but not using HT has better per-queue throughput\n"
	printf -- "\t\t             --overlay=[none|vxlan]     network overlay used, if any (not supported on all bridge types)\n"
	printf -- "\t\t             --topology=str             pp (which is just 2 physical devices on same bridge) or pvp (which is 2 bridges, each with a phys port and a virtio port)\n"
	printf -- "\t\t             --dataplane=str            dpdk or kernel\n"
	printf -- "\t\t             --switch=str               testpmd, ovs, linuxbridge\n"
	exit 1
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
		--switch)
		shift
		if [ -n "$1" ]; then
			switch="$1"
			echo switch: [$switch]
			shift
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

# make sure all of the pci devices used are exactly the same
pci_dev_count=0
prev_pci_desc=""
for this_pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
	pci_desc=`lspci -s $this_pci_dev | cut -d" " -f 2-`
	if [ "$prev_pci_desc" != "" -a "$prev_pci_desc" != "$pci_desc" ]; then
		echo "ERROR: PCI devices are not the exact same type"
		echo "$prev_pci_desc"
		echo "$pci_desc"
		exit 1
	fi
	prev_pci_desc="$pci_desc"
	((pci_dev_count++))
done
if [ $pci_dev_count -ne 2 ]; then
	echo "ERROR: you must use 2 PCI devices"
	echo "$pci_dev_count devices were specified"
	exit 1
fi
kernel_nic_kmod=`lspci -k -s $this_pci_dev | grep "Kernel modules:" | awk -F": " '{print $2}'`

function convert_cpu_range() {
	# converts a range of cpus, like "1-3,5" to a list, like "1,2,3,5"
	local cpu_range=$1
	local cpus_list=""
	local cpus=""
	for cpus in `echo "$cpu_range" | sed -e 's/,/ /g'`; do
		if echo "$cpus" | grep -q -- "-"; then
			cpus=`echo $cpus | sed -e 's/-/ /'`
			cpus=`seq $cpus | sed -e 's/ /,/g'`
			cpus_list="$cpus,$i"
		fi
		for cpu in $cpus; do
			cpus_list="$cpus_list,$cpu"
		done
	done
	cpus_list=`echo $cpus_list | sed -e 's/^,//'`
	echo "$cpus_list"
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
			fi
		done
	done
	for cpu in "${!current_cpus_set[@]}"; do
		sub_cpu_list="$sub_cpu_list,$cpu"
	done
	sub_cpu_list=`echo $sub_cpu_list | sed -e 's/^,//'`
	echo "$sub_cpu_list"
}


function get_pmd_cpus() {
	local avail_cpus=$1
	local nr_queues=$2
	local nr_devs=$3
	local nr_pmd_threads=`echo "$nr_queues * $nr_devs" | bc`
	local avail_cpus_set
	local count
	local pmd_cpu_list=""
	# for easier manipulation, convert the avail_cpus string to a associative array
	for i in `echo $avail_cpus | sed -e 's/,/ /g'`; do
		avail_cpus_set["$i"]=1
	done
	if [ "$use_ht" == "n" ]; then
		# when using 1 thread per core (higher per-PMD-thread throughput)
		count=0
		for cpu in "${!avail_cpus_set[@]}"; do
			pmd_cpu_list="$pmd_cpu_list,$cpu"
			unset avail_cpus_set[$cpu]
			((count++))
			[ $count -ge $nr_pmd_threads ] && break
		done
	else
		# when using 2 threads per core (higher throuhgput/core)
		count=0
		for cpu in "${!avail_cpus_set[@]}"; do
			pmd_cpu_hyperthreads=`cat /sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list`
			pmd_cpu_hyperthreads=`convert_cpu_range $pmd_cpu_hyperthreads`
			for cpu_thread in `echo $pmd_cpu_hyperthreads | sed -e 's/,/ /g'`; do
				pmd_cpu_list="$pmd_cpu_list,$cpu_thread"
				unset avail_cpus_set[$cpu_thread]
				((count++))
			done
			[ $count -ge $nr_pmd_threads ] && break
		done
	fi
	pmd_cpu_list=`echo $pmd_cpu_list | sed -e 's/^,//'`
	echo "$pmd_cpu_list"
}

function get_cpumask() {
	local cpu_list=$1
	local pmd_cpu_mask=0
	for cpu in `echo $cpu_list | sed -e 's/,/ /'g`; do
		pmd_cpu_mask=`echo "$pmd_cpu_mask + 2^$cpu" | bc`
	done
	printf "%x" $pmd_cpu_mask
}


# kill any process using the 2 PCI devices
echo Checking for an existing process using $pci_devs
for pci_dev in `echo $pci_devs | sed -e 's/,/ /g'`; do
	iommu_group=`readlink /sys/bus/pci/devices/$pci_dev/iommu_group | awk -Fiommu_groups/ '{print $2}'`
	pids=`lsof | grep -- "/dev/vfio/$iommu_group" | awk '{print $2}' | sort | uniq`
	if [ ! -z "$pids" ]; then
		echo killing PID $pids, which is using device $pci_dev
		kill $pids
	fi
done
# completely kill and remove old ovs configuration
echo "stopping ovs"
killall ovs-vswitchd
killall ovsdb-server
killall ovsdb-server ovs-vswitchd
sleep 3
rm -rf $prefix/var/run/openvswitch/ovs-vswitchd.pid
rm -rf $prefix/var/run/openvswitch/ovsdb-server.pid
rm -rf $prefix/var/run/openvswitch/*
rm -rf $prefix/etc/openvswitch/*db*
rm -rf $prefix/var/log/openvswitch/*

# initialize the devices
case $dataplane in
	dpdk)
	dev1=`echo $pci_devs | awk -F, '{print $1}'`
	numa_node=`cat /sys/bus/pci/devices/"$dev1"/numa_node`
	node_cpus=`cat /sys/devices/system/node/node$numa_node/cpulist`
	# convert to a list with 1 entry per cpu and no "-" for ranges
	cpus_list=`convert_cpu_range $node_cpus`
			
	
	rmmod vfio-pci
	# load modules and bind Ethernet cards to dpdk modules
	for kmod in vfio vfio-pci; do
		if lsmod | grep -q $kmod; then
		echo "not loading $kmod (already loaded)"
	else
		if modprobe -v $kmod; then
			echo "loaded $kmod module"
		else
			echo "Failed to load $kmmod module, exiting"
			exit 1
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
			echo "Could not get kernel driver to init on device $pci_dev"
			exit 1
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
		"pvp")   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
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
				brctl delbr $phy_br
				brctl addbr $phy_br
				brctl addif $phy_br $eth_dev
			fi
		done
		;;
		esac
	;;
	vpp)
	case $topology in
		"pp")   # 10GbP1<-->10GbP2
		vpp_ports=2
		vpp_startup_file=/etc/vpp/startup.conf
		pmd_threads=`echo "$vpp_ports * $queues" | bc`
		if [ $numa_node -eq 0 ]; then
			# skip the first  as it cannot be in isolcpus
			cpus_list=`echo $cpus_list | sed -e 's/^[0-9]*,//'`
		fi
		pmd_cpus=`get_pmd_cpus $cpus_list $queues $vpp_ports`
		config="xconnect"
		descriptors=2048
		vhost_feature_mask=""
		echo "#generated by start-vswitch" >$vpp_startup_file
		echo "unix {" >>$vpp_startup_file
  		echo "    nodaemon" >>$vpp_startup_file
  		echo "    log /var/log/vpp.log" >>$vpp_startup_file
  		echo "    full-coredump" >>$vpp_startup_file
		echo "}" >>$vpp_startup_file
		echo "cpu {" >>$vpp_startup_file
    		echo "    workers $pmd_threads" >>$vpp_startup_file
    		echo "    main-core 0" >>$vpp_startup_file
    		echo "    corelist-workers $pmd_cpus" >>$vpp_startup_file
		echo "}" >>$vpp_startup_file
		echo "dpdk {" >>$vpp_startup_file
    		echo "    no-multi-seg" >>$vpp_startup_file
    		echo "    uio-driver vfio-pci" >>$vpp_startup_file
    		echo "    socket-mem 1024,1024" >>$vpp_startup_file
		avail_pci_devs="$pci_devs"
		for i in `seq 0 1`; do
			pci_dev=`echo $avail_pci_devs | awk -F, '{print $1}'`
			avail_pci_devs=`echo $avail_pci_devs | sed -e s/^$pci_dev,//`
    			echo "    dev $pci_dev" >>$vpp_startup_file
    			echo "    {" >>$vpp_startup_file
       			echo "        num-rx-queues $queues" >>$vpp_startup_file
       			echo "        num-tx-queues $queues" >>$vpp_startup_file
    			echo "    }" >>$vpp_startup_file
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
		sleep 10
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
		vppctl set interface l2 xconnect ${vpp_nic[0]} ${vpp_nic[1]}
		vppctl set interface l2 xconnect ${vpp_nic[1]} ${vpp_nic[0]}
		vppctl set dpdk interface placement ${vpp_nic[0]} queue 0 thread 1
		vppctl set dpdk interface placement ${vpp_nic[1]} queue 0 thread 2
    		# fixup dpdk interface descriptors
		if [ -n "${descriptors}" ]; then
    			vppctl set dpdk interface descriptors ${vpp_nic[0]} rx ${descriptors} tx ${descriptors}
    			vppctl set dpdk interface descriptors ${vpp_nic[1]} rx ${descriptors} tx ${descriptors}
		fi
		# bringup interfaces
		vppctl set interface state ${vpp_nic[0]} up
		vppctl set interface state ${vpp_nic[1]} up
		
	esac
	;;
	ovs)
	DB_SOCK="$prefix/var/run/openvswitch/db.sock"
	ovs_ver=`$prefix/sbin/ovs-vswitchd --version | awk '{print $4}'`
	echo "starting ovs"
	mkdir -p $prefix/var/run/openvswitch
	mkdir -p $prefix/etc/openvswitch
	$prefix/bin/ovsdb-tool create $prefix/etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
	
	#$prefix/sbin/ovsdb-server -v --remote=punix:/var/run/openvswitch/db.sock \
	$prefix/sbin/ovsdb-server -v --remote=punix:$DB_SOCK \
    	--remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    	--pidfile --detach || exit 1

	if echo $ovs_ver | grep -q "^2\.6"; then
		dpdk_opts=""
		$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
		$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="1024,1024"
	else
		dpdk_opts="--dpdk -n 4 --socket-mem 1024,1024 --"
	fi
	$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
	$prefix/bin/ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="1024,1024"

	/bin/rm -f /var/log/openvswitch/ovs-vswitchd.log
	
	echo starting ovs-vswitchd
	sudo su -g qemu -c "umask 002; $prefix/sbin/ovs-vswitchd $dpdk_opts unix:$DB_SOCK --pidfile --log-file=/var/log/openvswitch/ovs-vswitchd.log --detach"
	rc=$?
	if [ $rc -ne 0 ]; then
		echo openvswitch exit code: [$rc]
		echo aborting since openvswitch did not start correctly
		exit 1
	fi
	
	echo waiting for ovs to init
	$prefix/bin/ovs-vsctl --no-wait init
	
	echo "configuring ovs with network topology: $topology"
	case $topology in
		"vv")  # VM1P1<-->VM2P1, VM1P2<-->VM2P2
		# create a bridge with 2 virt devs per bridge, to be used to connect to 2 VMs
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user3 -- set Interface vhost-user3 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=2,idle_timeout=0 actions=output:1"
	
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr1
		$prefix/bin/ovs-vsctl add-br ovsbr1 -- set bridge ovsbr1 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user4 -- set Interface vhost-user4 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr1
		$prefix/bin/ovs-ofctl add-flow ovsbr1 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr1 "in_port=2,idle_timeout=0 actions=output:1"
		ovs_ports=4
		;;
		"v")  # vm1 <-> vm1 
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=2,idle_timeout=0 actions=output:1"
		ovs_ports=2
		;;
		# pvvp probably does not work
		"pvvp")  # 10GbP1<-->VM1P1, VM1P2<-->VM2P2, VM2P1<-->10GbP2
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 dpdk0 -- set Interface dpdk0 type=dpdk
		$prefix/bin/ovs-vsctl add-port ovsbr0 vhost-user1 -- set Interface vhost-user1 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=2,idle_timeout=0 actions=output:1"
	
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr1
		$prefix/bin/ovs-vsctl add-br ovsbr1 -- set bridge ovsbr1 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user2 -- set Interface vhost-user2 type=dpdkvhostuser
		$prefix/bin/ovs-vsctl add-port ovsbr1 vhost-user3 -- set Interface vhost-user3 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr1
		$prefix/bin/ovs-ofctl add-flow ovsbr1 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr1 "in_port=2,idle_timeout=0 actions=output:1"
	
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr2
		$prefix/bin/ovs-vsctl add-br ovsbr2 -- set bridge ovsbr2 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr2 dpdk1 -- set Interface dpdk1 type=dpdk
		$prefix/bin/ovs-vsctl add-port ovsbr2 vhost-user4 -- set Interface vhost-user4 type=dpdkvhostuser
		$prefix/bin/ovs-ofctl del-flows ovsbr2
		$prefix/bin/ovs-ofctl add-flow ovsbr2 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr2 "in_port=2,idle_timeout=0 actions=output:1"
		ovs_ports=6
		;;
		"pvp")   # 10GbP1<-->VM1P1, VM1P2<-->10GbP2
		# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
		for i in `seq 0 1`; do
			phy_br="phy-br-$i"
			vhost_port="vhost-user-$i"
			phys_port="dpdk$i"
			$prefix/bin/ovs-vsctl --if-exists del-br $phy_br
			$prefix/bin/ovs-vsctl add-br $phy_br -- set bridge $phy_br datapath_type=netdev
			$prefix/bin/ovs-vsctl add-port $phy_br $phys_port -- set Interface $phys_port type=dpdk
			if [ -z "$overlay" -o "$overlay" == "none" -o "$overlay" == "half-vxlan" -a $i -eq 1 ]; then
				$prefix/bin/ovs-vsctl add-port $phy_br $vhost_port -- set Interface $vhost_port type=dpdkvhostuser
				$prefix/bin/ovs-ofctl del-flows $phy_br
				$prefix/bin/ovs-ofctl add-flow $phy_br "in_port=1,idle_timeout=0 actions=output:2"
				$prefix/bin/ovs-ofctl add-flow $phy_br "in_port=2,idle_timeout=0 actions=output:1"
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
		if [ "$kernel_nic_kmod" == "i40e" ]; then
			echo "configuring XL710 devices with 2048 descriptors/queue"
			ovs-vsctl set Interface dpdk0 options:n_txq_desc=2048
			ovs-vsctl set Interface dpdk1 options:n_txq_desc=2048
		fi
		ovs_ports=4
		;;
		"pp")  # 10GbP1<-->10GbP2
		# create the bridges/ports with 1 phys dev and 1 virt dev per bridge, to be used for 1 VM to forward packets
		$prefix/bin/ovs-vsctl --if-exists del-br ovsbr0
		$prefix/bin/ovs-vsctl add-br ovsbr0 -- set bridge ovsbr0 datapath_type=netdev
		$prefix/bin/ovs-vsctl add-port ovsbr0 dpdk0 -- set Interface dpdk0 type=dpdk
		$prefix/bin/ovs-vsctl add-port ovsbr0 dpdk1 -- set Interface dpdk1 type=dpdk
		$prefix/bin/ovs-ofctl del-flows ovsbr0
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=1,idle_timeout=0 actions=output:2"
		$prefix/bin/ovs-ofctl add-flow ovsbr0 "in_port=2,idle_timeout=0 actions=output:1"
		echo "using $queues queue(s) per port"
		$prefix/bin/ovs-vsctl set interface dpdk0 options:n_rxq=$queues
		$prefix/bin/ovs-vsctl set interface dpdk1 options:n_rxq=$queues
		if [ "$kernel_nic_kmod" == "i40e" ]; then
			echo "configuring XL710 devices with 2048 descriptors/queue"
			ovs-vsctl set Interface dpdk0 options:n_txq_desc=2048
			ovs-vsctl set Interface dpdk1 options:n_txq_desc=2048
		fi
		ovs_ports=2
	esac
	
	#configure the number of PMD threads to use
	pmd_threads=`echo "$ovs_ports * $queues" | bc`
	echo "using a total of $pmd_threads PMD threads"

	if [ $numa_node -eq 0 ]; then
		# skip the first  as it cannot be in isolcpus
		cpus_list=`echo $cpus_list | sed -e 's/^[0-9]*,//'`
	fi
	echo cpus_list is [$cpus_list]
	echo ovs_ports [$ovs_ports]
	pmdcpus=`get_pmd_cpus $cpus_list $queues $ovs_ports`
	pmd_cpu_mask=`get_cpumask $pmdcpus`
	echo pmd_cpus_list is [$pmdcpus]
	echo pmd_cpu_mask is [$pmd_cpu_mask]
	vm_cpus=`subtract_cpus $cpus_list $pmdcpus`
	echo vm_cpus is [$vm_cpus]
	
	ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$pmd_cpu_mask
	echo "PMD cpumask command: ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$pmd_cpu_mask"
	echo "PMD thread assinments:"
	ovs-appctl dpif-netdev/pmd-rxq-show
	;;

	testpmd)
	if [ $numa_node -eq 0 ]; then
		# skip the first  as it cannot be in isolcpus
		cpus_list=`echo $cpus_list | sed -e 's/^[0-9]*,//'`
	fi
	echo configuring testpmd with $topology
	case $topology in
		pp)
		console_cpu=0
		rxd=2048
		txd=$rxd
		testpmd_ports=2
		pmd_threads=`echo "$testpmd_ports * $queues" | bc`
		avail_pci_devs="$pci_devs"
		i=0
		pci_location_arg=""
		for nic in `echo $pci_devs | sed -e 's/,/ /g'`; do
			pci_location_arg="$pci_location_arg -w $nic"
		done
		echo use_ht: [$use_ht]
		echo cpus_list is [$cpus_list]
		pmd_cpus=`get_pmd_cpus $cpus_list $queues 2`
		pmd_cpu_mask=`get_cpumask $pmd_cpus`
		echo pmd_cpu_list is [$pmd_cpus]
		echo pmd_cpu_mask is [$pmd_cpu_mask]
		testpmd_cmd="/root/dpdk/build/$testpmd_ver/bin/testpmd -l $console_cpu,$pmd_cpus --socket-mem 1024,1024 -n 4\
		  --proc-type auto --file-prefix testpmd$i $pci_location_arg\
                  --\
		  --numa --nb-cores=$pmd_threads\
		  --nb-ports=2 --portmask=3 --auto-start --rxq=$queues --txq=$queues\
		  --rxd=$rxd --txd=$txd >/tmp/testpmd-$i"
		echo testpmd_cmd: $testpmd_cmd
		screen -dmS testpmd-$i bash -c "$testpmd_cmd"
		cpus_list=`subtract_cpus $cpus_list $pmd_cpus`
		;;
		pvp)
		mkdir -p /var/run/openvswitch
		console_cpu=0
		rxd=2048
		txd=$rxd
		testpmd_ports=2
		pmd_threads=`echo "$testpmd_ports * $queues" | bc`
		avail_pci_devs="$pci_devs"
		echo use_ht: [$use_ht]
		for i in `seq 0 1`; do
			pci_dev=`echo $avail_pci_devs | awk -F, '{print $1}'`
			avail_pci_devs=`echo $avail_pci_devs | sed -e s/^$pci_dev,//`
			vhost_port="/var/run/openvswitch/vhost-user-$i"
			echo cpus_list is [$cpus_list]
			pmd_cpus=`get_pmd_cpus $cpus_list $queues 2`
			pmd_cpu_mask=`get_cpumask $pmd_cpus`
			echo pmd_cpu_list is [$pmd_cpus]
			echo pmd_cpu_mask is [$pmd_cpu_mask]
			testpmd_cmd="/root/dpdk/build/$testpmd_ver/bin/testpmd -l $console_cpu,$pmd_cpus --socket-mem 1024,1024 -n 4\
			  --proc-type auto --file-prefix testpmd$i -w $pci_dev --vdev eth_vhost0,iface=$vhost_port -- --numa --nb-cores=$pmd_threads\
			  --nb-ports=2 --portmask=3 --auto-start --rxq=$queues --txq=$queues\
			  --rxd=$rxd --txd=$txd >/tmp/testpmd-$i"
			echo testpmd_cmd: $testpmd_cmd
			screen -dmS testpmd-$i bash -c "$testpmd_cmd"
			sleep 5
			cpus_list=`subtract_cpus $cpus_list $pmd_cpus`
		done
		chmod 777 /var/run/openvswitch/vhost-user-*
		;;
	esac
	;;
esac

	
