#!/bin/bash

# This is a script that controls the order of the ethernet interfaces.
# it can either set up interfaces based on a list of hardware addresses or based on the PCI bus id.

# Author:  Petre Rodan <petre.rodan@simplex.ro>
# Date:    2012 03 31
# License: GPLv3
# URL:     github.com/rodan/fix_eth_order
# dependencies: iproute2-2.6.36 or newer

# a default profile that contains all known ethernet devices and their hardware address
CONF='/etc/ethers.conf'

# the maximum number of moves allowed during the reordering process
MAX_MOVES=20

GOOD=$'\e[32;01m'
WARN=$'\e[33;01m'
BAD=$'\e[31;01m'
HILITE=$'\e[36;01m'
NORMAL=$'\e[0m'

[ -e "${CONF}" ] && . "${CONF}"

show_usage()
{
cat <<- EOF
 $0 available options:
   -h     help
   -c <file>    use config <file>
   -p     pretend - don't do any changes to the interfaces, just show what should be done
   -s     store the current iface order as the default profile
   -b     show current iface order compared to bus id order
   -e     show current iface order compared to stored profile
   -bo    reorder ethernet devices to match the pci bus order
   -eo    reorder ethernet devices to match the stored profile
EOF
}

swap_eth()
{
    src="$1"
    dst="$2"

    # route save and route restore needs at least iproute2-2.6.36

    echo -n " ${src} <-> ${dst} "

    rm -f /tmp/${dst}_routes /tmp/${src}_routes

    ip route save dev ${src} > /tmp/${src}_routes
    ip route save dev ${dst} > /tmp/${dst}_routes

    ip link set dev ${src} down
    ip link set dev ${dst} down

    ip link set dev ${dst} name not_${dst}
    ip link set dev ${src} name ${dst}
    ip link set dev not_${dst} name ${src}

    ip link set dev ${src} up
    ip link set dev ${dst} up

    ip route restore dev ${src} < /tmp/${dst}_routes 2>/dev/null
    ip route restore dev ${dst} < /tmp/${src}_routes 2>/dev/null

    rm -f /tmp/${dst}_routes /tmp/${src}_routes
}

store_order()
{
    ifaces=`ls -1d /sys/class/net/eth* | sed 's|.*\(eth[0-9]\{1,2\}\)$|\1|'| xargs`

    echo "conf_ifaces=( ${ifaces} ) " > "${CONF}"

    for i in ${ifaces}; do
        hwaddr=`ip a s ${i} |grep ether | sed 's|.*\([0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}\) .*|\1|'`
        echo "${i}_hwaddr='${hwaddr}'" >> "${CONF}"
    done

    cat "${CONF}"

}

get_hwaddr_order()
{
    SHOW_INFO=false
    [[ "$1" == "show" ]] && SHOW_INFO=true
    SORTED=true

    [ ! -e ${CONF} ] && {
        echo " ${BAD}*${NORMAL} config file not found, exiting"
        exit 1
    }

    # get all macs of the real system ethernet nics
    sys_ifaces=`ls -1d /sys/class/net/eth* | sed 's|.*\(eth[0-9]\{1,2\}\)$|\1|'`
    for iface in ${sys_ifaces}; do
        eval ${iface}_sys_hwaddr=`ip a s ${iface} | grep ether | sed 's|.*\([0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}:[0-9a-f]\{2,\}\) .*|\1|'`
    done

    ${SHOW_INFO} && echo "   iface   sys_hwaddr         conf_hwaddr"

    for iface in ${conf_ifaces[@]}; do
        extra=""
        eval conf_hwaddr="\${${iface}_hwaddr}"
        eval sys_hwaddr="\${${iface}_sys_hwaddr}"

        if [[ "${conf_hwaddr}" == "${sys_hwaddr}" ]]; then
            ${SHOW_INFO} && echo -en " ${GOOD}*${NORMAL} "
            extra="${conf_hwaddr}"
        else
            ${SHOW_INFO} && echo -en " ${WARN}*${NORMAL} "
            extra="${conf_hwaddr}"
            SORTED=false
        fi
       
        ${SHOW_INFO} && echo "${iface}    ${sys_hwaddr}  ${extra}"
    done

    ${SORTED} || {
        ${SHOW_INFO} && echo -e " ${BAD}*${NORMAL} NICs are not ordered"
        return 1
    }
    return 0
}

order_by_hwaddr()
{

    for iface in ${conf_ifaces[@]}; do
        eval sys_hwaddr="\${${iface}_sys_hwaddr}"
        eval conf_hwaddr="\${${iface}_hwaddr}"
        if [[ "${conf_hwaddr}" != "${sys_hwaddr}" ]]; then
            replace=""
            # find which system interface has that hwaddr
            for sys_iface in ${sys_ifaces}; do
                eval sys_hwaddr="\${${sys_iface}_sys_hwaddr}"
                [[ "${conf_hwaddr}" == "${sys_hwaddr}" ]] && {
                    replace=${sys_iface}
                    break
                }
            done
            if [ ! -z "${replace}" ]; then
                if ${PRETEND}; then
                    echo swap_eth ${replace} ${iface}
                else
                    swap_eth ${replace} ${iface}
                fi
                eval tmp="\${${iface}_sys_hwaddr}"
                eval ${iface}_sys_hwaddr=${conf_hwaddr}
                eval ${replace}_sys_hwaddr=${tmp}
                return 1
            else
                echo " ${BAD}*${NORMAL} hwaddr from config has not been found"
            fi
        fi
    done
    return 0
}

loop_order_by_hwaddr()
{
    tries=0
    while [ ${tries} -lt ${MAX_MOVES} ]; do
        order_by_hwaddr && return 0
        tries="$(( ${tries} + 1 ))"
    done
}

get_pci_bus_order()
{
    SHOW_INFO=false
    [[ "$1" == "show" ]] && SHOW_INFO=true
    SORTED=true

    ifaces=`ls -al /sys/class/net/eth*/device | sed 's|.*net/\(eth.*\)/device.*\([0-9a-f]\{4,\}:[0-9a-f]\{2,\}:[0-9a-f.]\{3,\}\).*|\2 \1|' | sort -n`
    n=`echo "${ifaces}" | wc -l`
    for ((i=0;i<${n};i++)); do
        extra=""
        int[${i}]=`echo "${ifaces}" | sed "$((${i}+1))!d" | awk '{ print $2 }'`
        [[ "eth${i}" != "${int[${i}]}" ]] && {
            ${SHOW_INFO} && echo -en " ${WARN}*${NORMAL} "
            extra="should be eth${i}"
            SORTED=false
        } || {
            ${SHOW_INFO} && echo -en " ${GOOD}*${NORMAL} "
        }
        ${SHOW_INFO} && echo bus id `echo "${ifaces}" | sed "$((${i}+1))!d"` ${extra}
    done
    ${SORTED} || {
        ${SHOW_INFO} && echo -e " ${BAD}*${NORMAL} NICs are not in pci bus order"
        return 1
    }
    return 0
}

order_by_bus_id() 
{
    for ((i=0;i<${n};i++)); do
        [[ "eth${i}" != "${int[${i}]}" ]] && {
            if ${PRETEND}; then
                echo swap_eth "${int[${i}]}" "eth${i}"
            else
                swap_eth "${int[${i}]}" "eth${i}"
            fi
            for ((j=0;j<${n};j++)); do
                [[ "${int[${j}]}" == "eth${i}" ]] && {
                    int[${j}]="${int[${i}]}"
                }
            done
            int[${i}]="eth${i}"
            return 1
        }
    done
    return 0
}

loop_order_by_bus_id()
{
    tries=0
    while [ ${tries} -lt ${MAX_MOVES} ]; do
        order_by_bus_id && return 0
        tries="$(( ${tries} + 1 ))"
    done
}

PRETEND=false

if [ "$#" -lt 1 ]; then
    show_usage
fi

while (( "$#" )); do
    if [ "$1" = "-p" ]; then
        shift;
        PRETEND=true
    elif [ "$1" = "-c" ]; then
        CONF="$2"
        [ -e "${CONF}" ] && . "${CONF}"
        shift;
        shift;
     elif [ "$1" = "-b" ]; then
        shift;
        get_pci_bus_order show
    elif [ "$1" = "-bo" ]; then
        shift;
        get_pci_bus_order
        loop_order_by_bus_id
    elif [ "$1" = "-e" ]; then
        shift;
        get_hwaddr_order show
    elif [ "$1" = "-eo" ]; then
        shift;
        get_hwaddr_order
        loop_order_by_hwaddr
    elif [ "$1" = "-s" ]; then
        shift;
        store_order
    elif [ "$1" = "-h" ]; then
        shift;
        show_usage
    else
        echo "unknown option $1"
        shift;
        show_usage
    fi
done

