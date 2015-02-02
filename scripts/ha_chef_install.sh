#!/bin/bash

# Installs open-source Chef 11 in a highly available configuration (with back-end stream replication)
# on 2 nodes: Node A - Node B

# Prerequisites:
# - Need to run as root on Node A
# - Need to be able to ssh into Node B without password
# - Need to have the Chef server rpm downloaded on Node A and located at $ChefRPMPath
#   (can be downloaded from: https://www.chef.io/download-open-source-chef-server-11/)
# - Chef should be already fully installed on Node A
# - Node B should be able to connect to Node A and vice versa (check /etc/hosts on both sides)

#### Define these variable before running: ###
NodeA=HOSTNAME_OR_IP_OF_NODE_A
NodeB=HOSTNAME_OR_IP_OF_NODE_B
NodeBNetwork=10.0.0.0/16
ChefRPMPath=/home/admin/packages/chef/chef-server-11.0.8-1.el6.x86_64.rpm
RepUser=repuser
RepPass=password12345
Port=5432
##############################################

add_only_once () {
# This function adds line $2 into file $1 only once:
# if the line is already in that file, it won't be added twice
	tempfile="`basename $1`-workingcopy"
	cat $1 | egrep -v "$2" > /tmp/$tempfile
        # Add optional comment with a timestamp if the 3rd parameter is "-c"
	if [ $# -eq 3 ] && [ "$3" == "-c" ] ; then echo "# Added by add_only_once() on `date`" >> /tmp/$tempfile ; fi
	echo $2 >> /tmp/$tempfile
	cat /tmp/$tempfile > $1
	rm -f /tmp/$tempfile
}

ssh $NodeB hostname 
if [ $? -eq 0 ]
then
	echo "Can ssh into $NodeB. Proceeding."
else
	echo "Failed to ssh into $NodeB. Exiting."
	exit 1
fi

# Setting up chef-server on Node B
tmpName=/tmp/chef-server.rpm
scp $ChefRPMPath $NodeB:$tmpName
ssh $NodeB rpm -ivh $tmpName
ssh $NodeB chef-server-ctl reconfigure

# Chef should be already installed and configured on Node A 

# Setting data replication between Node A and Node B
dataPath=/var/opt/chef-server/postgresql/data
add_only_once $dataPath/pg_hba.conf "host replication repl_user $NodeBNetwork trust" -c
add_only_once $dataPath/postgresql.conf "listen_addresses = '*'" -c
add_only_once $dataPath/postgresql.conf "wal_level = hot_standby"
add_only_once $dataPath/postgresql.conf "max_wal_senders = 1"
add_only_once $dataPath/postgresql.conf "hot_standby = on"

# Create repl_user and restart PostgreSQL
su - opscode-pgsql << 'EOF'
psql postgres -c "CREATE ROLE $RepUser LOGIN REPLICATION PASSWORD '$RepPass'"
EOF
chef-server-ctl restart postgresql

# Set up replication on Node B
# Stop PostgreSQL and remove old data 
ssh $NodeB chef-server-ctl stop postgresql
ssh $NodeB rm -rf $dataPath

# Pull data from Node A
ssh $NodeB yum -y install expect
echo "spawn /opt/chef-server/embedded/bin/pg_basebackup -x -p $Port -h $NodeA -U $RepUser -W -D $dataPath --progress --verbose" > /tmp/interaction
echo "expect \"Password*\" {send \"$RepPass\r\"}" >> /tmp/interaction
echo "expect eof" >> /tmp/interaction
scp /tmp/interaction $NodeB:/tmp
ssh $NodeB expect /tmp/interaction

# Create custom recovery.conf   
scp $NodeB:/opt/chef-server/embedded/share/postgresql/recovery.conf.sample /tmp/recovery.conf
add_only_once /tmp/recovery.conf "standby_mode = on" -c
add_only_once /tmp/recovery.conf "primary_conninfo = 'host=$NodeA port=$Port user=$RepUser password=$RepPass application_name=stby'" 
scp /tmp/recovery.conf $NodeB:/var/opt/chef-server/postgresql/data/recovery.conf

# Start PostgreSQL
ssh $NodeB chown -R opscode-pgsql:opscode-pgsql $dataPath
ssh $NodeB chef-server-ctl start postgresql
