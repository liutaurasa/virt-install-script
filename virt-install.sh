#!/bin/bash

if (( $EUID != 0 )); then
    echo "Please run as root"
    exit 1
fi

HELP=`cat<<-EOF

Parameters for $0 script:
    -d | --distro:      distro rocky or centos.
    -h | --hostname:    hostname of new VM. Required.
    -m | --mac:         mac address for new VM. Optional.
    -n | --network:     Libvirt network name. One of: $(virsh net-list --name | xargs)
    -r | --run:         Run the script
    -v | --version:     CentOS version 7 or 8
 
EOF
`
# Dry run by default
DRY_RUN=1

while [ 0 -lt $# ]; do
    case $1 in
        -d|--distro) shift
            DISTRO=$1; shift;;
        -h|--hostname ) shift
            HOST_NAME=$1; shift;;
        -m|--mac ) shift
            MAC=",mac=$1"; shift;;
        -n|--network ) shift
            NETWORK=$1; shift;;
        -r|--run ) shift
            DRY_RUN=0;;
        -v|--version ) shift
            VERSION=$1; shift;;
        * )
            echo "${HELP}"; exit 1;;
    esac
done

if $(virsh list --state-running --name | grep ${HOST_NAME}); then
    echo "Domain ${HOST_NAME} is stil running."
    exit 1
fi

if [[ -z "${MAC}" && -z "${NETWORK}" ]]; then
    if $(virsh list --state-shutoff --name | grep ${HOST_NAME}); then
        read -p "Do you want reinstall ${HOST_NAME} (y/n): " REINSTALL
        if [[ ${REINSTALL} == "y" || ${REINSTALL} == "Y" ]]; then
            MAC=",mac="$(virsh domiflist ${HOST_NAME} | grep network | awk '{print $5}')
            NETWORK="$(virsh domiflist ${HOST_NAME} | grep network | awk '{print $3}')"
            sudo virsh undefine ${HOST_NAME} --remove-all-storage --delete-snapshots
        fi
    fi
fi

POOL_NAME="images"
KS_PATH="./"
KS_FILE="centos${VERSION:-7}-kickstart.cfg"
DISK_FORMAT="qcow2"
case ${DISTRO} in
    centos) LOCATION=http://mirror.hetzner.de/centos/${VERSION}/BaseOS/x86_64/os/;;
    rocky)  LOCATION=https://download.rockylinux.org/pub/rocky/${VERSION}/BaseOS/x86_64/os/;;
    *) echo "Specify either centos or rocky as distro (-d)"; exit 1;;
esac

if VOL_INFO=$(virsh vol-info --pool ${POOL_NAME} ${HOST_NAME}.${DISK_FORMAT} 2>/dev/null); then
    echo "Volume ${POOL_NAME} - ${HOST_NAME}.${DISK_FORMAT} already exists:"
    echo "${VOL_INFO}"
    read -p "Do you want to remove it (y/n): " YN
    if [[ ${YN} == "y" ]]; then
        VOL_DEL_CMD="virsh vol-delete --pool ${POOL_NAME} ${HOST_NAME}.${DISK_FORMAT}"
        if [[ ${DRY_RUN} -eq 1 ]]; then
            echo "${VOL_DEL_CMD}"
        else
            ${VOL_DEL_CMD}
        fi
    else
        exit 1
    fi
fi

# Create disk image
VOL_CREATE_CMD="virsh vol-create-as ${POOL_NAME} ${HOST_NAME}.${DISK_FORMAT} 20G --allocation 5G --format ${DISK_FORMAT} --prealloc-metadata"
if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "${VOL_CREATE_CMD}"
else
    ${VOL_CREATE_CMD}
fi


read -p "VM Title, used in virt-manager VM list: " TITLE
read -p "VM Description (the purpose of VM): " DESC

# Remove temporary kickstart file
trap 'rm -f "${TMP_KSFILE}"' EXIT

TMP_KSFILE=$(mktemp) || exit

cat ${KS_PATH}${KS_FILE} | HOST_NAME=${HOST_NAME} envsubst > ${TMP_KSFILE}

CMD="virt-install \
        --name ${HOST_NAME} \
        --vcpus 2 \
        --ram 4096 \
        --disk pool=${POOL_NAME},size=20 \
        --metadata title=\"${TITLE}\",description=\"${DESC}\" \
        --location ${LOCATION} \
        --os-type=linux \
        --os-variant=centos${VERSION:-7} \
        --network network=${NETWORK}${MAC}\
        --initrd-inject=${TMP_KSFILE} \
        --extra-args=\"ks=file:/$(basename ${TMP_KSFILE}) console=ttyS0,115200n8 SERVERNAME=${HOST_NAME} NOTIFYEMAIL=liutauras.adomaitis@infosaitas.lt net.ifnames=0 biosdevname=0\" \
        --noautoconsole \
        --hvm $@"

if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "${CMD}"
else
    eval ${CMD}
fi
        
# --initrd-inject=${KS_PATH}${KS_FILE} \
# --network bridge:virbr0 \
