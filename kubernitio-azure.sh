#!/bin/bash
#
# Spin up a Kognitio cluster on Azure AKS
#
# References:
#
# https://kognitio.com/blog/kognitio-on-kubernetes-on-azure/
# https://github.com/kognitio-ltd/kognitio-docker-container
# https://hub.docker.com/r/kognitio/kognitio
#

KOGNITIO_IMAGE="kognitio/kognitio:latest"   # which Kognitio docker image to use 
AZ_RES_GROUP="kognitio-rg"	       # the Azure resource group to build this cluster in
AZ_ZONE="ukwest"                       # which Azure zone to build the cluster and filesystem in
AZ_VNET="kog-vnet"                     # a VNET for the project
AZ_SUBNET="kog-subnet"                 # and it's subnet
AZ_NFS_SERVER="kognfs"                 # the name of the NFS server used to provide storage for the Kognitio instance
AZ_STORAGE_AC="kogsa"                  # the name of the storage account to create the blob container in
AZ_STORAGE_BUCKET="kogblob"            # the blob container (AWS bucket equivalent)
AZ_NFS_USER="kognitio"                 # the name of the user on the NFS server
AZ_NFS_NODE_SIZE="Standard_F2s"        # size of the VM for the NFS server
#AZ_NFS_NODE_SIZE="Standard_F4s_v2"    # size of the VM for the NFS server
AZ_NFS_DISK_SIZE=1000                  # size of data disk for the NFS server
K8S_NUM_NODES=2                        # number of nodes to provision in the Kubernetes cluster
K8S_NODE_TYPE="Standard_E4s_v3"        # the type of node to provision
#K8S_NODE_TYPE="Standard_E8s_v3"       # the type of node to provision (need to increase deffault allocation)
KOGNITIO_NODE_MEMORY="26Gi"            # the amount of memory to allocate to the Kognitio containers
#KOGNITIO_NODE_MEMORY="56Gi"           # the amount of memory to allocate to the Kognitio containers (for bigger node)
AZ_SP_NAME="kog-rbac-sp"               # name of the Kubernetes service principal
K8S_CLUSTER="kog-kube"                 # name of the Kubernetes cluster
K8S_APP_TAG="kog-cluster"              # app label 
K8S_NODE_TAG="kog-cluster-db"          # tag for kognitio cluster nodes
K8S_NODEGROUP="kognodes"               # nodegroup for the Kognitio nodes
K8S_PV="kog-cluster-volume"            # name of the persistent volume
K8S_PVC="kog-cluster-storage"          # name of the persistent volume claim
K8S_LB_SVC="kog-cluster-lb"            # name of the load balancer service
# set load balancer to max timeout (use keep alives or "Check session alive" option in Kognitio Console)
K8S_LB_ANNOTATION='service.beta.kubernetes.io/azure-load-balancer-tcp-idle-timeout: "30"'

# execute a command on all pods in tagged with the APP_TAG
function execOnAllPods {
  matching_pods=$(kubectl get pods --output=jsonpath="{$.items[?(@.metadata.labels.app == \"${K8S_APP_TAG}\")].metadata.name}")
  for pod in $matching_pods; do
    kubectl exec -it $pod -- "${@:1}"
  done
}

# execute a command on one of the pods tagged with the APP_TAG
function execOnOnePod {
  pod=$(kubectl get pods --output=jsonpath="{$.items[?(@.metadata.labels.app == \"${K8S_APP_TAG}\")].metadata.name}" | awk '{print $1}')
  kubectl exec -it $pod -- "${@:1}"
}

# some of the infrastructure was taken from
# https://docs.microsoft.com/en-us/azure/aks/configure-kubenet

# we create a resource group to simplify tidying up
#  deleting the resource group deletes all the resources we created in it
function createProject {
  az group create --name ${AZ_RES_GROUP} --location ${AZ_ZONE}

  # create a vnet (we're going to use kubenet (basic networking))
  az network vnet create \
    --name ${AZ_VNET} \
    --resource-group ${AZ_RES_GROUP} \
    --address-prefixes 192.168.0.0/16 \
    --subnet-name ${AZ_SUBNET} \
    --subnet-prefix 192.168.1.0/24
}

# we need to create an NFS server because the standard readWriteMany options 
# don't support sparse files and aren't POSIX compliant
function createNfsServer {

  AZ_NFS_VALUES=$(az vm create \
    --resource-group ${AZ_RES_GROUP} \
    --name ${AZ_NFS_SERVER} \
    --vnet-name ${AZ_VNET} \
    --subnet ${AZ_SUBNET} \
    --accelerated-networking \
    --image UbuntuLTS \
    --admin-username ${AZ_NFS_USER} \
    --size ${AZ_NFS_NODE_SIZE} \
    --data-disk-sizes-gb ${AZ_NFS_DISK_SIZE} \
    --generate-ssh-keys)

  # give server time to wake up
  sleep 10

  AZ_NFS_PUB_IP=$(jq -r '.publicIpAddress' <<< $AZ_NFS_VALUES)
  AZ_NFS_PRIV_IP=$(jq -r '.privateIpAddress' <<< $AZ_NFS_VALUES)
  SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${AZ_NFS_USER}@${AZ_NFS_PUB_IP}"
  DATA_DIRECTORY="/data"

  # find out which device the data disk has been added as
  DATA_DISK=$(${SSH_CMD} "lsblk | grep ${AZ_NFS_DISK_SIZE}G | head -1 | awk '{ print \$1 }'")
 
  # partition, format and mount the data disk 
  ${SSH_CMD} "cat >/tmp/mountdisk.sh" <<EOF
#set -x
parted /dev/${DATA_DISK} mklabel gpt
parted /dev/${DATA_DISK} unit TB
parted --align optimal /dev/${DATA_DISK} mkpart primary 0% 100%
sleep 5
mkfs.ext4 /dev/${DATA_DISK}1
sleep 5
mkdir -p ${DATA_DIRECTORY}
echo "/dev/${DATA_DISK}1	${DATA_DIRECTORY}    ext4    defaults        0 0" >> /etc/fstab
mount ${DATA_DIRECTORY}
chmod 777 ${DATA_DIRECTORY}
EOF
  ${SSH_CMD} "sudo bash /tmp/mountdisk.sh"
  
  # create script to setup NFS on the server and execute it
  ${SSH_CMD} "cat >/tmp/setupnfs.sh" <<EOF
#set -x

echo "Updating packages"
apt-get -y update

echo "Installing NFS kernel server"

apt-get -y install nfs-kernel-server

echo "Appending localhost and Kubernetes subnet address 192.168.1.0/24 to exports configuration file"
echo "${DATA_DIRECTORY}        192.168.1.0/24(rw,async,insecure,fsid=0,crossmnt,no_subtree_check)" >> /etc/exports
echo "${DATA_DIRECTORY}        localhost(rw,async,insecure,fsid=0,crossmnt,no_subtree_check)" >> /etc/exports

echo "Exporting ${DATA_DIRECTORY}"
exportfs -a

EOF
  ${SSH_CMD} "sudo bash /tmp/setupnfs.sh"

  # wait for the nfs server to settle
  sleep 2
}

# create a storage account and a container for the data access examples
function createStorageAccount  {

  az storage account create \
    --name ${AZ_STORAGE_AC} \
    --resource-group ${AZ_RES_GROUP} \
    --location ${AZ_ZONE} \
    --kind StorageV2 \
    --sku Standard_LRS 

  # export the keys
  export AZURE_STORAGE_ACCOUNT=${AZ_STORAGE_AC}
  export AZURE_STORAGE_KEY=\
$(az storage account keys list \
   --account-name ${AZ_STORAGE_AC} \
   --resource-group ${AZ_RES_GROUP} \
   --output json | jq -r '.[0].value' \
 )

  # create an example bucket 
  az storage container create --name ${AZ_STORAGE_BUCKET}
}

# we're using an Azure managed AKS Kubernetes cluster
function createKubernetesCluster  {
  # create a service principal for the AKS cluster and capture returned values
  AZ_SP_VALUES=$(az ad sp create-for-rbac --name ${AZ_SP_NAME} --skip-assignment); echo ${AZ_SP_VALUES}
  
  # get vnet and subnet id 
  VNET_ID=$(az network vnet show --resource-group ${AZ_RES_GROUP} --name ${AZ_VNET} --query id -o tsv)
  SUBNET_ID=$(az network vnet subnet show --resource-group ${AZ_RES_GROUP} --vnet-name ${AZ_VNET} --name ${AZ_SUBNET} --query id -o tsv)

  # repeats unti the service principal propogates and the assignment succeeds
  set +e
  while true; do
    az role assignment create --assignee $(jq -r '.appId' <<< $AZ_SP_VALUES) --scope ${VNET_ID} --role Contributor
    if [ $? -eq 0 ]; then
      set -e
      break;
    fi
    sleep 5
  done

  sleep 60

  # create the Kubernetes cluster
  az aks create \
    --resource-group ${AZ_RES_GROUP} \
    --name ${K8S_CLUSTER} \
    --node-count ${K8S_NUM_NODES} \
    --node-vm-size ${K8S_NODE_TYPE} \
    --nodepool-name ${K8S_NODEGROUP} \
    --network-plugin kubenet \
    --service-cidr 10.0.0.0/16 \
    --dns-service-ip 10.0.0.10 \
    --pod-cidr 10.244.0.0/16 \
    --docker-bridge-address 172.17.0.1/16 \
    --vnet-subnet-id $SUBNET_ID \
    --service-principal $(jq -r '.appId' <<< $AZ_SP_VALUES) \
    --client-secret $(jq -r '.password' <<< $AZ_SP_VALUES)

  # configure kubectl to connect to this cluster
  az aks get-credentials --resource-group ${AZ_RES_GROUP} --name ${K8S_CLUSTER} --overwrite-existing
}

#set -x

case "$1" in
"execOnOnePod")
  execOnOnePod ${@:2}
  ;;
"execOnAllPods")
  execOnAllPods ${@:2}
  ;;
"delete")
  set +e
  # deleting the resource group will cascade delete pretty much everything
  az group delete --name ${AZ_RES_GROUP} --yes
  # except the service principal...
  objid=$(az ad sp list --display-name ${AZ_SP_NAME} | jq -r '.[].objectId')
  az ad sp delete --id $objid
  ;;
"create") 
  set -e
  
  # test to see if we have a valid CIDR for the load balancer firewall
  CIDR=$2
  if [[ ! "$CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then 
    echo "CIDR block [$CIDR] for load balancer missing or malformed"
    echo "Usage $0 create <cidr block>"
    echo "Suggested CIDR is <your IP address>/32 "
    exit 1
  fi

  # create the Azure infrastructure to deploy Kognitio on
  createProject
  createNfsServer
  createKubernetesCluster
  createStorageAccount

  # Deploy Kognitio onto the Kubernetes cluster we created above

  # attach a Kubernetes persistent volume to the NFS server

  kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${K8S_PV}
spec:
  capacity:
    storage: 1000Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: ${AZ_NFS_PRIV_IP}
    path: "/data"
EOF

  # create a persistent volume claim to give to the deployment 

  kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_PVC}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 1000Gi
EOF

  # deploy the Kognitio app
  echo "creating the Deployment with one pod"
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_APP_TAG}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${K8S_APP_TAG}
  template:
    metadata:
      labels:
        app: ${K8S_APP_TAG}
    spec:
      volumes:
      - name: ${K8S_PVC}
        persistentVolumeClaim:
          claimName: ${K8S_PVC}
      containers:
      - name: ${K8S_NODE_TAG}
        image: ${KOGNITIO_IMAGE}
        resources:
            limits:
              memory: "${KOGNITIO_NODE_MEMORY}"
        ports:
          - name: odbc
            containerPort: 6550
        volumeMounts:
            - name: ${K8S_PVC}
              mountPath: /data
EOF

  echo "waiting for pods to stabilise"
  while true; do
    sleep 5
    PODS_RUNNING=true
    for pod_status in $(kubectl get pods -l app=${K8S_APP_TAG} -o=jsonpath={.items[*].status.phase}); do
      if [[ "${pod_status}" != "Running" ]] ; then
        PODS_RUNNING=false
      fi
    done
    if [[ ${PODS_RUNNING} == true ]] ; then
      break;
    fi
    echo "Waiting for all pods to enter Running state"
  done

# create a load balancer to enable access to the Kognitio cluster 
  echo "creating load balancer"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${K8S_LB_SVC}
  annotations:
    ${K8S_LB_ANNOTATION}
spec:
  type: LoadBalancer
  selector:
    app: ${K8S_APP_TAG}
  ports:
  - protocol: TCP
    port: 6550
    targetPort: 6550
  loadBalancerSourceRanges:
  - $CIDR
EOF

  # create the kognitio database
  echo "###################################"
  echo "## Initialising Kognitio cluster ##"
  echo "##        INPUT REQUIRED         ##"
  echo "###################################"

  execOnOnePod kognitio-cluster-init

  echo "creating the rest of the pods"
  kubectl scale deployment.v1.apps/${K8S_APP_TAG} --replicas=${K8S_NUM_NODES}

  # wait for all the nodes to join the Kognitio cluster
  while true; do
    sleep 5
    NODES_READY=$(execOnOnePod wxprobe -H | grep full: | sed 's/.*: \([0-9]\).*/\1/')
    if [[ "${NODES_READY}" == "${K8S_NUM_NODES}" ]] ; then
      echo "${NODES_READY} of ${K8S_NUM_NODES} nodes ready - installing database "
      break
    else
      echo "Waiting for ${K8S_NUM_NODES} nodes to join the cluster - ${NODES_READY} joined"
    fi
  done

  # An example of how to add the storage account key to the server configuration
  # The companion data access scripts set this in the external table definition
  # so it is commented out here.
  # in production you may want to use a credential provider
  # http://hadoop.apache.org/docs/r2.8.3/hadoop-azure/index.html#Configuring_Credentials
#  execOnOnePod wxconftool -W -S -s 'hadoop' \
#    -a "javad_hadoop_config=\
#fs.azure.account.key.kubernitio.blob.core.windows.net=\
#$(az storage account keys list \
#   --account-name ${AZ_STORAGE_AC} \
#   --resource-group ${AZ_RES_GROUP} \
#   --output json | jq -r '.[0].value'\
# )"

  # add the Azure data lake hadoop filesystem libraries to each node
  execOnAllPods curl \
    https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-azure-datalake/3.2.1/hadoop-azure-datalake-3.2.1.jar \
    -o /opt/kognitio/wx2/current/java/plugins/postsyspath/hadoop-azure-datalake-3.2.1.jar

  execOnAllPods curl \
    https://repo1.maven.org/maven2/com/microsoft/azure/azure-data-lake-store-sdk/2.3.8/azure-data-lake-store-sdk-2.3.8.jar \
    -o /opt/kognitio/wx2/current/java/plugins/postsyspath/azure-data-lake-store-sdk-2.3.8.jar

  echo "###################################"
  echo "## Initialising Kognitio server  ##"
  echo "##        INPUT REQUIRED         ##"
  echo "###################################"

  execOnOnePod kognitio-create-database

  # wait for loadbalancer and report IP address 
  while true; do
    sleep 5
    LB_IP=$(kubectl get svc ${K8S_LB_SVC} -o=jsonpath={.status.loadBalancer.ingress[0].ip})
    if [[ "${LB_IP}" == "" ]] ; then
      echo "Waiting for load balancer to allocate external IP address"
    else
      echo "#######################################################################"
      echo "Kognitio server installed on ${K8S_NUM_NODES} nodes"
      echo "Load balancer ready - connect to cluster on ${LB_IP} port 6550"
      echo "Account, bucket and key for example storage:"
      STKEY=$(az storage account keys list --account-name ${AZ_STORAGE_AC} --resource-group ${AZ_RES_GROUP} --output json | jq -r '.[0].value')
      echo "Account: ${AZ_STORAGE_AC} Bucket: ${AZ_STORAGE_BUCKET} Key: ${STKEY}"
      break
    fi
  done
  ;;
"info") # provide information about the deployment
  LB_IP=$(kubectl get svc ${K8S_LB_SVC} -o=jsonpath={.status.loadBalancer.ingress[0].ip})
  echo "Connect to the Kognitio cluster on ${LB_IP} port 6550"
  echo "Account, bucket and key for the example storage:"
  STKEY=$(az storage account keys list --account-name ${AZ_STORAGE_AC} --resource-group ${AZ_RES_GROUP} --output json | jq -r '.[0].value')
  echo "Account: ${AZ_STORAGE_AC} Bucket: ${AZ_STORAGE_BUCKET} Key: ${STKEY}"
  ;;
*)
  echo "Usage $0 create <CIDR block> | delete | info "
  echo "                             | execOnAllPods <command to execute on all pods in the cluster> "
  echo "                             | execOnOnePod <command to execute on one pod in the cluster>"
  exit 1
  ;;
esac

