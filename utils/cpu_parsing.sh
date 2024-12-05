#!/bin/bash

function log() {
	echo -e "start-vswitch: LINENO: ${BASH_LINENO[0]} $1"
}

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
	iso_cpus=$(cat /sys/devices/system/cpu/nohz_full)
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
	local cpu=""
	local list=""
	for cpu in `grep -E "[0-9]+:$" $cpu_usage_file | awk -F: '{print $1}'`; do
		list="$list,$cpu"
		echo "BILL10 list = $list" >> mydebug.txt
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
		echo "cpu = $cpu, bitmask = $bitmask"
	done
	bitmask=`echo "obase=2; $bitmask" | bc`
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
      local node_iso_cpus_list=""
      declare -a cpu_set_a
      declare -a cpu_set_b
      declare -a intersect_cpu_list

      for i in {0..512}
       do
            cpu_set_b[$i]=''
            intersect_cpu_list[$i]=''
       done

      # for easier manipulation, convert the cpu list strings to a associative array
      for i in `echo $cpus_a | sed -e 's/,/ /g'`; do
          cpu_set_a["$i"]=1
      done

      for i in `echo $cpus_b | sed -e 's/,/ /g'`; do
          cpu_set_b["$i"]=1
      done

      for cpu in "${!cpu_set_a[@]}"; do
          if [ "x${cpu_set_b[$cpu]}" != "x" ]; then
              intersect_cpu_list="$intersect_cpu_list,$cpu"
          fi
      done
      intersect_cpu_list=`echo $intersect_cpu_list | sed -e s/^,//`
      node_iso_cpus_list=`echo $intersect_cpu_list`
      echo $node_iso_cpus_list
}

function remove_sibling_cpus() {
	local cpu_range=$1
	local cpu_list=`convert_number_range $cpu_range`
	local no_sibling_list=""
	local socket_core_id_list="," #commas on front and end of list and in between IDs for easier grepping
	while [ ! -z "$cpu_list" ]; do
		this_cpu=`echo $cpu_list | awk -F, '{print $1}'`
		cpu_list=`echo $cpu_list | sed -e s/^$this_cpu//`
		cpu_list=`echo $cpu_list | sed -e s/^,//`
		core=`cat /sys/devices/system/cpu/cpu$this_cpu/topology/core_id`
		socket=`cat /sys/devices/system/cpu/cpu$this_cpu/topology/physical_package_id`
		socket_core_id="$socket:$core"
		if echo $socket_core_id_list | grep -q ",$socket_core_id,"; then
			# this core has already been taken
			continue
		else
			# first time this core has been found, use it
			socket_core_id_list="${socket_core_id_list}${socket_core_id},"
			no_sibling_list="$no_sibling_list,$this_cpu"
		fi

	done
	no_sibling_list=`echo $no_sibling_list | sed -e s/^,//`
	echo "$no_sibling_list"
}

# pmdcpus=`get_pmd_cpus "$devs,$vhost_ports" $queues "ovs-pmd"`
function get_pmd_cpus() {

	local devs1=$1
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
	local this_dev
	for this_dev in `echo $devs1 | sed -e 's/,/ /g'`; do
		if echo $this_dev | grep -q vhost; then
			# the file name for vhostuser ends with a number matching the NUMA node
			node_id="${this_dev: -1}"
		else
			node_id=`cat /sys/bus/pci/devices/$(get_dev_loc $this_dev)/numa_node`
			# -1 means there is no topology, so we use node0
			if [ "$node_id" == "-1" ]; then
				node_id=0
			fi
		fi
		cpus_list=`node_cpus_list "$node_id"`

		echo "BILL6 cpus_list = $cpus_list" > mydebug.txt
		iso_cpus_list=`get_iso_cpus`
		echo "BILL7 iso_cpus_list = $iso_cpus_list" >> mydebug.txt

		node_iso_cpus_list=`intersect_cpus "$cpus_list" "$iso_cpus_list"`
		echo "BILL8 node_iso_cpus_list = $node_iso_cpus_list" >> mydebug.txt

		if [ "$use_ht" == "n" ]; then
			node_iso_cpus_list=`remove_sibling_cpus $node_iso_cpus_list`
		fi
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
				echo "BILL9 cpu_siblings_range = $cpu_siblings_range" >> mydebug.txt
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
			if [ "$use_ht" == "n" ]; then
				# make sure sibling threads don't get used next time a isolated cpu is found
				sibling_cpus=`cat /sys/devices/system/cpu/cpu$new_cpu/topology/thread_siblings_list`
				sibling_cpus=`convert_number_range $sibling_cpus`
				sibling_cpus=`sub_from_list $sibling_cpus $new_cpu`
                sleep 5
				for i in `echo $sibling_cpus | sed -e 's/,/ /g'`; do
					log_cpu_usage "$i" "idle-sibling-thread"
					if [ $? -gt 0 ]; then
						exit 1
					fi
				done
			fi
			log_cpu_usage "$new_cpu" "$cpu_usage"
			if [ $? -gt 0 ]; then
				exit 1
			fi
			node_iso_cpus_list=`sub_from_list "$node_iso_cpus_list" "$new_cpu"`
			pmd_cpus_list="$pmd_cpus_list,$new_cpu"
			((queue_num++))
			((count++))
			prev_cpu=$new_cpu
		done
	done
	pmd_cpus_list=`echo $pmd_cpus_list | sed -e 's/^,//'`
	echo "$pmd_cpus_list"
}

function get_cpumask() {
	local cpu_list=$1
	local pmd_cpu_mask=0
    local bc_math=""
	for cpu in `echo $cpu_list | sed -e 's/,/ /'g`; do
		bc_math="$bc_math + 2^$cpu"
	done
	bc_math=`echo $bc_math | sed -e 's/\+//'`
	pmd_cpu_mask=`echo "obase=16; $bc_math" | bc`
	echo "$pmd_cpu_mask"
}



