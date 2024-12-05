#!/bin/bash

for i in $(seq 0 7);
do
        free_hugepages=$(cat /sys/devices/system/node/node$i/hugepages/hugepages-1048576kB/free_hugepages)
	total_hugepages=$(cat /sys/devices/system/node/node$i/hugepages/hugepages-1048576kB/nr_hugepages)
	echo "Node $i hugepages free $free_hugepages out of $total_hugepages"
done
	
