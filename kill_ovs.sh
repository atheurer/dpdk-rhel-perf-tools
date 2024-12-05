#!/bin/bash
# using "rpm"
ovs_bin="/usr/bin"
ovs_sbin="/usr/sbin"
ovs_run="/var/run/openvswitch"
ovs_etc="/etc/openvswitch"

killall -q -w ovs-vswitchd
killall -q -w ovsdb-server
killall -q -w ovsdb-server ovs-vswitchd
killall -q -w testpmd
rm -rf $ovs_run/ovs-vswitchd.pid
rm -rf $ovs_run/ovsdb-server.pid
rm -rf $ovs_etc/*db*

