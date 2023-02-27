# System authorization information
auth --enableshadow --passalgo=sha512
# Use network installation
#url --url="http://download.eng.bos.redhat.com/released/fedora/F-34/GOLD/Server/x86_64/os/"
url --url="http://fedora.mirror.constant.com/fedora/linux/releases/34/Server/x86_64/os/"
# Use text mode install
text
# Run the Setup Agent on first boot
firstboot --enable
ignoredisk --only-use=vda
# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'
# System language
lang en_US.UTF-8
# Network information
network  --bootproto=dhcp --device=ens2 --ipv6=auto --activate
#network  --hostname=dhcp31-246.perf.lab.eng.bos.redhat.com
# Root password
rootpw --iscrypted $6$u/KnxAzbRwPmTlO5$hZ.lPbgaDh3Y8XZlDU7R34.yjE9UKsiWR73IOTn/M2cHqKvW5piJrx3FXsibcHFG1Yq3PkQHnZTbC6G.4LEwk/
# Do not configure the X Window System
skipx
# System timezone
timezone US/Eastern --isUtc --ntpservers=10.16.31.254,clock.util.phx2.redhat.com,clock02.util.phx2.redhat.com
# System bootloader configuration
bootloader --location=mbr --boot-drive=vda
autopart --type=plain
# Partition clearing information
clearpart --all --initlabel --drives=vda

%packages
%end

shutdown
