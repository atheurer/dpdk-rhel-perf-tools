#!/bin/bash
#
# Monitor host and alarm if preemption is detected

declare -A PMD_SW #store number of task switches by pmd name
declare -A VCPU_SW #store number of task switch by vCPU ID
declare -A INT_NR #store interrupt count by $cpu_$int
declare -A CPU_TASK #store active task by $cpu
declare -A CPU_TID #store active task ID by $cpu
declare -A TASK_CPU #store cpu by active task name
active_cpus=""
interval=10 # time in seconds between checks

function exit_error() {
	echo "Error: $1"
	exit 1
}

function check_interrupts() {
	cat /proc/interrupts | grep -v CPU >/tmp/interrupts
	while read line; do
		int=`echo $line | cut -d : -f 1`
		#echo int: $int
		for cpu in `echo $active_cpus | sed -e 's/,/ /g'`; do
			#echo cpu: $cpu
			int_count=`echo $line | cut -d " " -f $(( $cpu + 2 ))`

			if [ "${INT_NR[${cpu}_$int]}abc" == "abc" ]; then
				INT_NR[${cpu}_$int]=$int_count
			else
				diff=$(( $int_count - ${INT_NR[${cpu}_${int}]} ))
				elapsed_time=$(( $timestamp - $old_timestamp ))
				if [ "$int" == "LOC" ]; then
					if echo ${CPU_TASK[$cpu]} | grep -q CPU; then
						allowable_diff=$(( $elapsed_time * 2 + 1 ))
					else 
						allowable_diff=$(( $elapsed_time + 1 ))
					fi
					if [ $diff -gt $allowable_diff ]; then
						echo "WARNING: CPU $cpu (${CPU_TASK[$cpu]}, ${CPU_TID[$cpu]}) IRQ $int increase higher than expected: $allowable_diff actual: $diff"
					fi
				else
					allowable_diff=0
					if [ $diff -gt $allowable_diff ]; then
						echo "WARNING: CPU $cpu (${CPU_TASK[$cpu]}, ${CPU_TID[$cpu]}) IRQ $int increase higher than expected: $allowable_diff actual: $diff"
					fi
				fi
				INT_NR[${cpu}_$int]=$int_count
				
			fi
		done
	done </tmp/interrupts
	#echo "${!INT_NR[@]}"
}

function check_kvm_cpu_switches() {
	grep -P '(^R\s+CPU\s\d+\/KVM\s+\d+\s+\-*\d+\.\d+\s+\d+\s+\d+\s+\d+\.\d+\s+)|(^cpu\#\d+,)' /proc/sched_debug >/tmp/sched_debug
	while read line; do
		if echo $line | grep -q -P '(^cpu\#\d+,)'; then
			cpu=`echo $line | sed -e 's/^cpu\#\([0-9]*\), .*/\1/'`
		else
			line="`echo $line | sed -e 's/CPU /CPU_/'`"
			vcpu=`echo $line | awk '{print $2}'`
			tid=`echo $line | awk '{print $3}'`
			nr_sw=`echo $line | awk '{print $5}'`
			if echo $iso_cpus_list | grep -q -P "(,$cpu,)"; then
				active_cpus="$active_cpus,$cpu"
				if [ "${VCPU_SW[$vcpu]}abc" != "abc" ]; then
					if [ $nr_sw -gt ${VCPU_SW[$vcpu]} ]; then
                                               diff=$(echo "$nr_sw - ${VCPU_SW[$pmd]}" | bc)
						echo "WARNING: number of switches increased by $diff for $vcpu on CPU ${TASK_CPU[$vcpu]}"
					fi
				fi
				VCPU_SW[$vcpu]=$nr_sw
				CPU_TASK[$cpu]="$vcpu"
				CPU_TID[$cpu]="$tid"
				TASK_CPU[$vcpu]=$cpu
			else
				echo "WARNING: there is a vCPU thread placed on a non-isolated CPU: $vcpu on CPU $cpu"
			fi
			
		fi
	done </tmp/sched_debug
}

function check_pmd_switches() {
	grep -P '(^R\s+(pmd\d+)\s+\d+\s+\-*\d+\.\d+\s+\d+\s+\d+\s+\d+\.\d+\s+)|(^R\s+(lcore-slave-\d+)\s+\d+\s+\-*\d+\.\d+\s+\d+\s+\d+\s+\d+\.\d+\s+)|(^cpu\#\d+,)' /proc/sched_debug >/tmp/sched_debug
	while read line; do
		if echo $line | grep -q -P '(^cpu\#\d+,)'; then
			cpu=`echo $line | sed -e 's/^cpu\#\([0-9]*\), .*/\1/'`
		else
			pmd=`echo $line | awk '{print $2}'`
			tid=`echo $line | awk '{print $3}'`
			nr_sw=`echo $line | awk '{print $5}'`
			if echo $iso_cpus_list | grep -q -P "(,$cpu,)"; then
				active_cpus="$active_cpus,$cpu"
				if [ "${PMD_SW[$pmd]}abc" != "abc" ]; then
					if [ $nr_sw -gt ${PMD_SW[$pmd]} ]; then
						diff=$(( $nr_sw - ${PMD_SW[$pmd]} ))
						echo "WARNING: number of switches increased by $diff for $pmd on CPU ${TASK_CPU[$pmd]}"
					fi
				fi
				PMD_SW[$pmd]=$nr_sw
				CPU_TASK[$cpu]="$pmd"
				CPU_TID[$cpu]="$tid"
				TASK_CPU[$pmd]=$cpu
			else
				echo "WARNING: there is a PMD thread placed on a non-isolated CPU: $pmd on CPU $cpu"
			fi
		fi
	done </tmp/sched_debug
}

iso_cpus_range=`cat /sys/devices/system/cpu/isolated`
if [ "$iso_cpus_range" == "" ]; then
	exit_error "isolcpus must be used"
fi

iso_cpus_list=""
for i in `echo $iso_cpus_range | sed -e 's/,/ /g'`; do
	if echo $i | grep -q -- '-'; then
		i="`echo $i | sed -e 's/-/ /'`"
		for j in `seq $i`; do
			iso_cpus_list="$iso_cpus_list,$j"
		done
	else
		iso_cpus_list="$iso_cpus_list,$i"
	fi
done
iso_cpus_list="$iso_cpus_list," # leave a trailing , here for easier grepping later
echo "isoalted cpus: $iso_cpus_list"
old_timestamp=`date +%s`
sleep $interval
while true; do
	timestamp=`date +%s`
	date
	check_pmd_switches
	check_kvm_cpu_switches
	check_interrupts
	sleep $interval
	old_timestamp=$timestamp
	active_cpus=`echo $active_cpus | sed -e 's/,//'`
	echo active and isolated cpus: $active_cpus
	active_cpus=""
	echo -e "\n\n"
done
