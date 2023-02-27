# System authorization information
#auth --enableshadow --passalgo=sha512
# Use network installation
#url --url="http://download.eng.bos.redhat.com/released/fedora/F-35/GOLD/Server/x86_64/os/"
url --url="http://fedora.mirror.constant.com/fedora/linux/releases/35/Server/x86_64/os/"
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
network  --bootproto=dhcp --ipv6=auto --activate
# Root password
rootpw --iscrypted $6$u/KnxAzbRwPmTlO5$hZ.lPbgaDh3Y8XZlDU7R34.yjE9UKsiWR73IOTn/M2cHqKvW5piJrx3FXsibcHFG1Yq3PkQHnZTbC6G.4LEwk/
# Do not configure the X Window System
skipx
# System timezone
timezone US/Eastern --isUtc --ntpservers=10.16.31.254,clock.util.phx2.redhat.com,clock02.util.phx2.redhat.com
# System bootloader configuration
bootloader --location=mbr --boot-drive=vda
autopart --type=btrfs
# Partition clearing information
clearpart --all --initlabel --drives=vda

%packages
@Container Management
%end


%post
curl https://password.corp.redhat.com/RH-IT-Root-CA.crt -o /etc/pki/ca-trust/source/anchors/RH-IT-Root-CA.crt
update-ca-trust
# dnf update -y
dnf install -y git podman vim bc jq 
git clone https://gitlab.cee.redhat.com/atheurer/crucible-internal.git
pushd crucible-internal
./rh-install-crucible.sh </dev/null
popd
%end

shutdown
