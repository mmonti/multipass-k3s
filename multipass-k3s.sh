#!/usr/bin/env bash

# Configure your settings
# Name for the cluster/configuration files
NAME=""
# Ubuntu image to use (xenial/bionic)
IMAGE="focal"
# How many additional server instances to create
SERVER_COUNT_MACHINE="0"
# How many agent instances to create
AGENT_COUNT_MACHINE="1"
# How many CPUs to allocate to each machine
SERVER_CPU_MACHINE="2"
AGENT_CPU_MACHINE="1"
# How much disk space to allocate to each machine
SERVER_DISK_MACHINE="5G"
AGENT_DISK_MACHINE="5G"
# How much memory to allocate to each machine
SERVER_MEMORY_MACHINE="1G"
AGENT_MEMORY_MACHINE="512M"
# Install channel to use (fixed to testing for embedded etcd support)
CHANNEL=testing
# Preconfigured secret to join the cluster (or autogenerated if empty)
SERVER_TOKEN=""
# Preconfigured secret to join the cluster (or autogenerated if empty)
AGENT_TOKEN=""


## Nothing to change after this line
if [ -x "$(command -v multipass.exe)" > /dev/null 2>&1 ]; then
    # Windows
    MULTIPASSCMD="multipass.exe"
elif [ -x "$(command -v multipass)" > /dev/null 2>&1 ]; then
    # Linux/MacOS
    MULTIPASSCMD="multipass"
else
    echo "The multipass binary (multipass or multipass.exe) is not available or not in your \$PATH"
    exit 1
fi

if [ -z $SERVER_TOKEN ]; then
    SERVER_TOKEN=$(cat /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1 | tr '[:upper:]' '[:lower:]')
    echo "No server token given, generated server token: ${SERVER_TOKEN}"
fi

if [ -z $AGENT_TOKEN ]; then
    AGENT_TOKEN=$(cat /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | fold -w 20 | head -n 1 | tr '[:upper:]' '[:lower:]')
    echo "No agent token given, generated agent token: ${AGENT_TOKEN}"
fi

# Check if name is given or create random string
if [ -z $NAME ]; then
    NAME=$(cat /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1 | tr '[:upper:]' '[:lower:]')
    echo "No name given, generated name: ${NAME}"
fi

echo "Creating cluster ${NAME} with $(( $SERVER_COUNT_MACHINE + 1 )) server(s) and ${AGENT_COUNT_MACHINE} agent(s)"

# Prepare cloud-init
# Cloud init template
read -r -d '' SERVER_INIT_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=$CHANNEL K3S_TOKEN=$SERVER_TOKEN K3S_AGENT_TOKEN=$AGENT_TOKEN INSTALL_K3S_EXEC="server --cluster-init" K3S_KUBECONFIG_MODE=644 sh -'
EOM

echo "$SERVER_INIT_CLOUDINIT_TEMPLATE" > "${NAME}-init-cloud-init.yaml"
echo "Cloud-init is created at ${NAME}-init-cloud-init.yaml"

echo "Creating initial server instance: k3s-server-${NAME}"

echo "Running $MULTIPASSCMD launch --cpus $SERVER_CPU_MACHINE --disk $SERVER_DISK_MACHINE --mem $SERVER_MEMORY_MACHINE $IMAGE --name k3s-server-$NAME --cloud-init ${NAME}-init-cloud-init.yaml"
$MULTIPASSCMD launch --cpus $SERVER_CPU_MACHINE --disk $SERVER_DISK_MACHINE --mem $SERVER_MEMORY_MACHINE $IMAGE --name k3s-server-$NAME --cloud-init "${NAME}-init-cloud-init.yaml"
if [ $? -ne 0 ]; then
    echo "There was an error launching the instance"
    exit 1
fi

echo "Checking for Node being Ready on k3s-server-${NAME}"
$MULTIPASSCMD exec k3s-server-$NAME -- /bin/bash -c 'while [[ $(sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -c -v "NotReady") -eq 0 ]]; do sleep 2; done'
echo "Node is Ready on k3s-server-${NAME}"

# Retrieve info to join agent to cluster
SERVER_IP=$($MULTIPASSCMD info k3s-server-$NAME | grep IPv4 | awk '{ print $2 }')
URL="https://$(echo $SERVER_IP | sed -e 's/[[:space:]]//g'):6443"

# Create additional servers
if [ "${SERVER_COUNT_MACHINE}" -gt 0 ]; then
    read -r -d '' SERVER_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=$CHANNEL K3S_TOKEN=$SERVER_TOKEN K3S_AGENT_TOKEN=$AGENT_TOKEN INSTALL_K3S_EXEC="server --server $URL" K3S_KUBECONFIG_MODE=644 sh -'
EOM

    echo "$SERVER_CLOUDINIT_TEMPLATE" > "${NAME}-cloud-init.yaml"

    echo "Creating ${SERVER_COUNT_MACHINE} additional server instances"
    for i in $(eval echo "{1..$SERVER_COUNT_MACHINE}"); do
        echo "Running $MULTIPASSCMD launch --cpus $SERVER_CPU_MACHINE --disk $SERVER_DISK_MACHINE --mem $SERVER_MEMORY_MACHINE $IMAGE --name k3s-server-$NAME-$i --cloud-init ${NAME}-cloud-init.yaml"
        $MULTIPASSCMD launch --cpus $SERVER_CPU_MACHINE --disk $SERVER_DISK_MACHINE --mem $SERVER_MEMORY_MACHINE $IMAGE --name k3s-server-$NAME-$i --cloud-init "${NAME}-cloud-init.yaml"
        if [ $? -ne 0 ]; then
            echo "There was an error launching the instance"
            exit 1
        fi

        echo "Checking for Node being Ready on k3s-server-${NAME}"
        $MULTIPASSCMD exec k3s-server-$NAME-$i -- /bin/bash -c 'while [[ $(sudo k3s kubectl get nodes --no-headers 2>/dev/null | grep -c -v "NotReady") -eq 0 ]]; do sleep 2; done'
        echo "Node is Ready on k3s-server-${NAME}-${i}"
    done
fi

if [ "${AGENT_COUNT_MACHINE}" -gt 0 ]; then
    # Prepare agent cloud-init
    # Cloud init template
    read -r -d '' AGENT_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=$CHANNEL K3S_TOKEN=$AGENT_TOKEN K3S_URL=$URL sh -'
EOM

    echo "$AGENT_CLOUDINIT_TEMPLATE" > "${NAME}-agent-cloud-init.yaml"
    echo "Cloud-init is created at ${NAME}-agent-cloud-init.yaml"

    for i in $(eval echo "{1..$AGENT_COUNT_MACHINE}"); do
        echo "Running $MULTIPASSCMD launch --cpus $AGENT_CPU_MACHINE --disk $AGENT_DISK_MACHINE --mem $AGENT_MEMORY_MACHINE $IMAGE --name k3s-agent-$NAME-$i --cloud-init ${NAME}-agent-cloud-init.yaml"
        $MULTIPASSCMD launch --cpus $AGENT_CPU_MACHINE --disk $AGENT_DISK_MACHINE --mem $AGENT_MEMORY_MACHINE $IMAGE --name k3s-agent-$NAME-$i --cloud-init "${NAME}-agent-cloud-init.yaml"
        if [ $? -ne 0 ]; then
            echo "There was an error launching the instance"
            exit 1
       fi
        echo "Checking for Node k3s-agent-$NAME-$i being registered"
        $MULTIPASSCMD exec k3s-server-$NAME -- bash -c "until sudo k3s kubectl get nodes --no-headers | grep -c k3s-agent-$NAME-$i >/dev/null; do sleep 2; done" 
        echo "Checking for Node k3s-agent-$NAME-$i being Ready"
        $MULTIPASSCMD exec k3s-server-$NAME -- bash -c "until sudo k3s kubectl get nodes --no-headers | grep k3s-agent-$NAME-$i | grep -c -v NotReady >/dev/null; do sleep 2; done"
        echo "Node k3s-agent-$NAME-$i is Ready on k3s-server-${NAME}"
    done
fi

$MULTIPASSCMD copy-files k3s-server-$NAME:/etc/rancher/k3s/k3s.yaml $NAME-kubeconfig-orig.yaml
sed "/^[[:space:]]*server:/ s_:.*_: \"https://$(echo $SERVER_IP | sed -e 's/[[:space:]]//g'):6443\"_" $NAME-kubeconfig-orig.yaml > $NAME-kubeconfig.yaml

echo "k3s setup finished"
$MULTIPASSCMD exec k3s-server-$NAME -- sudo k3s kubectl get nodes
echo "You can now use the following command to connect to your cluster"
echo "$MULTIPASSCMD exec k3s-server-${NAME} -- sudo k3s kubectl get nodes"
echo "Or use kubectl directly"
echo "kubectl --kubeconfig ${NAME}-kubeconfig.yaml get nodes"
