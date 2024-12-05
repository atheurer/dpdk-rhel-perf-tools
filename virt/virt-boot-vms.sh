#!/bin/bash

# This script will boot VMs and provide a list like the following:
# 
# waiting to vms to boot up
#             vm-name            hostname
#                 vm1       virbr0-122-11
#                 vm4      virbr0-122-194
#                 vm3      virbr0-122-209
#
# There are a couple things required to make this work:
#
# 1) The VM config must have 2 serial ports configured in the XML, like:
#
#    <serial type='pty'>
#      <target port='0'/>
#    </serial>
#    <serial type='file'>
#      <source path='/var/log/libvirt/qemu/<vm-name>.serial.log'/>
#      <target port='1'/>
#    </serial>
#    <console type='pty'>
#      <target type='serial' port='0'/>
#    </console>
#
#    The first serial port is for the systems main console,
#    which provides access to grub and access to log in
#    without a graphical console or network, should you need
#    to trouble-shoot something.
#
#    The seconds serial port is used to log kernel & console
#    message to a file on the kvm host.  This script expects
#    that file in /var/log/libvirt/qemu/<vm-name>.serial.log.
#
#  2) The VM OS must have both ttyS0 and ttyS1 configured:
#    
#    In the VM's /etc/default/grub, add these lines:
#       GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS1,115200n8 console=ttyS0,115200n8"
#       GRUB_TERMINAL=serial
#       GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
#
#    And then on the VM run:
#
#       grub2-mkconfig -o /boot/grub2/grub.cfg
#
#  3) The VM's login service needs to be configured for the serial consoles:
#
#    Create /etc/systemd/system/  files:
#
#       [Unit]
#       Description=Serial Getty on %I
#       Documentation=man:agetty(8) man:systemd-getty-generator(8)
#       Documentation=http://0pointer.de/blog/projects/serial-console.html
#       BindsTo=dev-%i.device
#       After=dev-%i.device systemd-user-sessions.service plymouth-quit-wait.service
#       After=rc-local.service
#       After=network-online.target
#       Wants=network-online.target
# 
#       Before=getty.target
#       IgnoreOnIsolate=yes
# 
#       [Service]
#       ExecStart=-/sbin/agetty --keep-baud %I 115200,38400,9600
#       Type=idle
#       Restart=always
#       RestartSec=0
#       UtmpIdentifier=%I
#       TTYPath=/dev/%I
#       TTYReset=yes
#       TTYVHangup=yes
#       KillMode=process
#       IgnoreSIGPIPE=no
#       SendSIGHUP=yes
# 
#       [Install]
#       WantedBy=getty.target
#
#    The "After/Wants=networ-online.target" will wait until the network
#    device is online before the login prompt is available for the serial
#    consoles.  We wait for that because we want the login prompt to
#    include the hostname, like:
#
#       virbr0-122-195 login:
# 
#    This is what this script looks for in the /var/log/libvirt/qemu/<vn-name>.serial.log
#    file in order to detect the VM's hostname.
	



vms=$1 #comma separated list (no spaces) of vms: vm1,vm2,vm4
vms=`echo $vms | sed -e s/","/" "/g`
log_dir=/tmp

# clear out the current serial log
for vm in $vms; do
	if [ -f $log_dir/$vm.console ]; then
		/bin/rm $log_dir/$vm.console
	fi
done

for vm in $vms; do
	virsh start $vm
done
wait

echo "waiting to vms to boot up"
printf "%20s%20s\n" "vm-name" "hostname"
while [ ! -z "$vms" ]; do
	for vm in $vms; do
		if grep -q "login:" "$log_dir/$vm.console"; then
			vm_hostname=`grep "login:" "$log_dir/$vm.console" | awk '{print $1}'`
			printf "%20s%20s\n" $vm $vm_hostname
			vms="`echo $vms | sed -e s/"$vm"//`"
			vms="`echo $vms | sed -e s/\s+/\s/`"
			break
		fi
	sleep 5
	done
done
