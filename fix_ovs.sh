#!/bin/bash


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

cpu_mask="52,116"
new_cpu_mask=`get_cpumask $cpu_mask`
echo "new_cpu_mask = $new_cpu_mask"
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=$new_cpu_mask

ovs-appctl dpif-netdev/pmd-rxq-show



