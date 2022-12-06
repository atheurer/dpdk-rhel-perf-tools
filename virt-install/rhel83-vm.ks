# Kickstart file to build RHEL-8 KVM image

text
lang en_US.UTF-8
keyboard us
timezone US/Eastern --isUtc --ntpservers=10.16.31.254,clock.util.phx2.redhat.com,clock02.util.phx2.redhat.com
# add console and reorder in %post
bootloader --timeout=1 --location=mbr --append="console=ttyS0 console=ttyS0,115200n8 no_timer_check crashkernel=auto net.ifnames=0"
#auth --enableshadow --passalgo=sha512
selinux --enforcing
firewall --enabled --service=ssh
network --bootproto=dhcp --device=link --activate --onboot=on
#services --enabled=sshd,ovirt-guest-agent --disabled kdump,rhsmcertd
services --enabled=sshd,NetworkManager,rngd --disabled kdump,rhsmcertd
rootpw --iscrypted $6$u/KnxAzbRwPmTlO5$hZ.lPbgaDh3Y8XZlDU7R34.yjE9UKsiWR73IOTn/M2cHqKvW5piJrx3FXsibcHFG1Yq3PkQHnZTbC6G.4LEwk/

#
# Partition Information. Change this as necessary
# This information is used by appliance-tools but
# not by the livecd tools.
#
zerombr
clearpart --all --initlabel
# autopart --type=plain --nohome # --nohome doesn't work because of rhbz#1509350
# autopart is problematic in that it creates /boot and swap partitions rhbz#1542510 rhbz#1673094
reqpart
part / --fstype="xfs" --ondisk=vda --size=8000
reboot

# Packages
%packages
@core
dnf
kernel
yum
dnf-utils

# We need this image to be portable; also, rescue mode isn't useful here.
dracut-config-generic
dracut-norescue

# Needed initially, but removed below.
firewalld

# cherry-pick a few things from @base
tar
rsync

# @base packages necessary for subscription management. RCMWORK-10049

# Some things from @core we can do without in a minimal install
-biosdevname
-plymouth
NetworkManager
-iprutils

# Because we need networking
dhcp-client


# Exclude all langpacks for now
-langpacks-*
-langpacks-en

# We are building RHEL
redhat-release
redhat-release-eula
-fedora-release
-fedora-repos

# Add rng-tools as source of entropy
rng-tools

%end

#
# Add custom post scripts after the base post.
#
%post --erroronfail


# setup systemd to boot to the right runlevel
echo -n "Setting default runlevel to multiuser text mode"
rm -f /etc/systemd/system/default.target
ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
echo .

# this is installed by default but we don't need it in virt
echo "Removing linux-firmware package."
dnf -C -y remove linux-firmware

# Remove firewalld; it is required to be present for install/image building.
echo "Removing firewalld."
dnf -C -y remove firewalld --setopt="clean_requirements_on_remove=1"

echo -n "Getty fixes"
# although we want console output going to the serial console, we don't
# actually have the opportunity to login there. FIX.
# we don't really need to auto-spawn _any_ gettys.
sed -i '/^#NAutoVTs=.*/ a\
NAutoVTs=0' /etc/systemd/logind.conf

echo -n "Network fixes"
# initscripts don't like this file to be missing.
cat > /etc/sysconfig/network << EOF
NETWORKING=yes
NOZEROCONF=yes
EOF

# For cloud images, 'eth0' _is_ the predictable device name, since
# we don't want to be tied to specific virtual (!) hardware
rm -f /etc/udev/rules.d/70*
ln -s /dev/null /etc/udev/rules.d/80-net-name-slot.rules
rm -f /etc/sysconfig/network-scripts/ifcfg-*
# simple eth0 config, again not hard-coded to the build hardware
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
BOOTPROTOv6="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
USERCTL="yes"
PEERDNS="yes"
IPV6INIT="yes"
PERSISTENT_DHCLIENT="1"
EOF

# set virtual-guest as default profile for tuned
echo "virtual-guest" > /etc/tuned/active_profile

# generic localhost names
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

EOF
echo .

cat <<EOL > /etc/sysconfig/kernel
# UPDATEDEFAULT specifies if new-kernel-pkg should make
# new kernels the default
UPDATEDEFAULT=yes

# DEFAULTKERNEL specifies the default kernel package type
DEFAULTKERNEL=kernel
EOL

# make sure firstboot doesn't start
echo "RUN_FIRSTBOOT=NO" > /etc/sysconfig/firstboot

# workaround https://bugzilla.redhat.com/show_bug.cgi?id=966888
if ! grep -q growpart /etc/cloud/cloud.cfg; then
  sed -i 's/ - resizefs/ - growpart\n - resizefs/' /etc/cloud/cloud.cfg
fi

# allow sudo powers to cloud-user
echo -e 'cloud-user\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers

# Disable subscription-manager yum plugins
sed -i 's|^enabled=1|enabled=0|' /etc/yum/pluginconf.d/product-id.conf
sed -i 's|^enabled=1|enabled=0|' /etc/yum/pluginconf.d/subscription-manager.conf

echo "Cleaning old yum repodata."
dnf clean all

# clean up installation logs
rm -rf /var/log/yum.log
rm -rf /var/lib/yum/*
rm -rf /root/install.log
rm -rf /root/install.log.syslog
rm -rf /root/anaconda-ks.cfg
rm -rf /var/log/anaconda*

echo "Fixing SELinux contexts."
touch /var/log/cron
touch /var/log/boot.log
mkdir -p /var/cache/yum
/usr/sbin/fixfiles -R -a restore

# remove random-seed so it's not the same every time
rm -f /var/lib/systemd/random-seed

# Remove machine-id on the pre generated images
cat /dev/null > /etc/machine-id

%end
