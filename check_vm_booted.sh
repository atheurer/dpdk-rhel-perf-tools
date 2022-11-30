#!/bin/bash
#
# Get the IP address of the guest's Ethernet management port when its available
#
while [[ -z $guest_booted_check ]]; do
         echo "Testing if guest networking is online..."
         sleep 2
         guest_booted_check=`virsh domifaddr --source agent $1 | grep enp1s0 | awk '{print $4}' | sed 's/\/.*//'`
         if [[ -n $guest_booted_check ]]; then
                echo "Attempting ping..."
                ping -c 1 -W 1 $guest_booted_check > /dev/null 2>&1
                if [[ $? -ne 0 ]]; then
                        guest_booted_check=''
			echo "$1 not booted yet..."
                fi
fi
done

echo "$1 has successfully booted, management interface:  $guest_booted_check"
