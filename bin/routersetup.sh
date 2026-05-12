#!/usr/bin/env bash
### script to setup router functionality in Kubuntu
### version 2.2.0
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

# stop script if a variable is used before being defined
set -u

### global variables
# define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# do NOT use trailing / here
CONFIG_DIR='../config'
TMP_DIR='/tmp/routersetup'
IF_LAN_ADDRESSES='iflan-addresses.conf'

# private IP addresses if not configured in IF_LAN_ADDRESSES
PRIVATE_IPV4_LAN_ADDRESS='192.168.10.1'
PRIVATE_IPV4_LAN_CIDR='24'

LAN_SUFFIX='lan'

# dnscrypt-proxy variables
DNSCRYPT_PROXY_URL='https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.18/dnscrypt-proxy-linux_x86_64-2.1.18.tar.gz'
DNSCRYPT_GZIP_FOLDER='linux-x86_64'

# dnsmasq variables
DNSMASQ_MASTER_CONFIG='90-dnsmasq.master.conf'
DNSMASQ_MASTER_EXTERNALDNS_CONFIG='90-dnsmasq-external-dns.master.conf'
DNSMASQ_CONFIG='90-dnsmasq.conf'

# dhcpcd variables

# systemd-resolved variables

# nftables variables

# chrony variables

# sysctld variables
SYSCTLD_NET_CONFIG='90-sysctl-net.conf'
SYSCTLD_WANIPV6_MASTER_CONFIG='91-wan-ipv6.master.conf'
SYSCTLD_WANIPV6_CONFIG='91-wan-ipv6.conf'
SYSCTLD_TCPUDP_CONFIG='92-tcpudp.conf'
SYSCTLD_MEMIO_CONFIG='93-memio.conf'

# netqos variables

# ddclient variables
DDCLIENT_URL='https://github.com/ddclient/ddclient/releases/download/v4.0.0/ddclient-4.0.0.tar.gz'
DDCLIENT_GZIP_FOLDER='ddclient-4.0.0'

# slapd variables
SLAPD_CREATE_DB='createdb.ldif'
SLAPD_MODIFY_DB='modifydb.ldif'
SLAPD_INIT_DB='initldap.ldif'

### helper functions

## get a yes / no response from the user
## $1: default choice ('y' or 'n')
## returns user choice: 'y' or 'n'
function getYesNoResponse() {
    local default="$1"
    local response

    # validate input parameter
    # if $default is not exactly 'y' or 'n', force it to 'y'
    if [[ "$default" != 'y' && "$default" != 'n' ]]; then
        default='y'
    fi

    # read user input
    while true; do
        read -r response
        # convert to lowercase
        response="${response,,}"

        case "${response:-$default}" in
            y|yes)
                echo 'y'
                return 0
                ;;
            n|no)
                echo 'n'
                return 0
                ;;
            *)
                echo "invalid input. please enter 'y' or 'n'." >&2
                ;;
        esac
    done
}

## install a package if it has not been installed already
## $1: package to install
## $2: masked installation? true: don't activate / enable service
## returns 0 if the package is already present
## exits 1 if there was an installation error
## returns 2 if the package was newly installed
##
## exits script if package was not installed successfully
function installPackage() {
    local package="$1"
    local mask_service="${2:-false}"

    # check if package is installed
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "ok installed"; then
        echo "installPackage(): $package is installed already."
        return 0
    fi

    echo "installing $package..."

    # if masking is requested, do it BEFORE install to prevent auto-start
    [[ "$mask_service" == 'true' ]] && sudo systemctl mask --now "${package}.service"

    # perform installation
    if sudo apt-get install -y -q "$package"; then
        # if we masked it, we must unmask it after successful install
        [[ "$mask_service" == 'true' ]] && sudo systemctl unmask "${package}.service"
        return 2 # newly installed
    else
        echo -e "[ ${RED}FAIL${NC} ] installPackage(): installation of $package failed!" >&2
        # clean up mask even on failure
        [[ "$mask_service" == 'true' ]] && sudo systemctl unmask "${package}.service"
        exit 1 # installation error
    fi
}

## remove a package if it is installed
## $1: package to remove
## returns 0 if the package was removed
## returns 1 if the package was not installed
removePackage() {
    local package="$1"

    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "ok installed"; then
        echo "removing $package..."
        sudo apt-get remove -y "$package"
        return 0
    else
        echo "removePackage(): $package is not installed."
        return 1
    fi
}

## download a package if it has not been downloaded previously
## $1: name of package
## $2: URL of package
## exits script if package was not downloaded successfully
function downloadPackage() {
    local pkgName="$1"
    local url="$2"
    local fileName="${url##*/}"
    local downloadDir="$TMP_DIR/$pkgName"
    local downloadFile="$downloadDir/$fileName"

    # check if file exists and is not empty
    # shellcheck disable=SC2317
    if [[ -s "$downloadFile" ]]; then
        echo "downloadPackage(): $pkgName is downloaded already."
        return 0
    fi

    echo "downloading $pkgName..."

    # shellcheck disable=SC2317
    if wget --no-verbose --show-progress -P "$downloadDir/" "$url"; then
        echo -e "[ ${GREEN}OK${NC}   ] downloadPackage(): download of $pkgName complete." >&2
        return 0
    else
        echo -e "[ ${RED}FAIL${NC} ] downloadPackage(): download of $pkgName failed (wget exit code: $?)." >&2
        # remove partial/corrupt file so the next attempt starts fresh
        [[ -f "$downloadFile" ]] && rm -f "$downloadFile"
        exit 1
    fi
}

## determine whether the system is Ubuntu or Debian-family.
## returns:
##   "ubuntu"  – if ID=ubuntu
##   "debian"  – if ID is one of: debian, sparky, devuan
##   ""        – for all other distributions
detectDistro() {
    local os_id="$(. /etc/os-release; echo "$ID")"
    # normalize to lowercase
    os_id="${os_id,,}"

    case "$os_id" in
        ubuntu|linuxmint)
            echo "ubuntu"
            ;;
        debian|sparkylinux|sparky|devuan)
            echo "debian"
            ;;
        *)
            echo ""
            ;;
    esac
}

### install functions

## install and configure dnscrypt-proxy
## since dnscrypt-proxy may not be available as a distribution package
## or may be outdated, install it from its repo
function handleDnscryptProxy() {
    echo
    echo "******************"
    echo "* dnscrypt-proxy *"
    echo "******************"

    local archiveName="${DNSCRYPT_PROXY_URL##*/}"
    local dnscryptproxyDir="$TMP_DIR/dnscrypt-proxy"
    local installDir="/opt/dnscrypt-proxy/$DNSCRYPT_GZIP_FOLDER"

    # uninstall section
    if [[ "$RECONFIG" == 'true' ]] && systemctl list-unit-files dnscrypt-proxy.service --no-legend 2>/dev/null \
        | grep -q '^dnscrypt-proxy.service'; then

        echo "uninstalling dnscrypt-proxy..."

        # restore dnsmasq to a state without dnscrypt dependency
        if systemctl is-active --quiet dnsmasq.service; then
            sed -e "s|IFLAN|$ifLan|g" \
                -e "s|IFWAN|$ifWan|g" \
                -e "s|LANSUFFIX|$lanSuffix|g" \
                "$CONFIG_DIR/dnsmasq/$DNSMASQ_MASTER_EXTERNALDNS_CONFIG" > "$TMP_DIR/$DNSMASQ_CONFIG"

            sudo cp "$TMP_DIR/$DNSMASQ_CONFIG" "/etc/dnsmasq.d/$DNSMASQ_CONFIG"
            sudo systemctl restart dnsmasq.service
        fi

        # use dnscrypt-proxy's own service management to clean up
        if [[ -f "$installDir/dnscrypt-proxy" ]]; then
            (
                cd "$installDir"
                sudo ./dnscrypt-proxy -service stop
                sudo ./dnscrypt-proxy -service uninstall
                echo "dnscrypt-proxy uninstalled."
            )
        fi
    fi

    # install section
    if ! systemctl list-unit-files dnscrypt-proxy.service --no-legend 2>/dev/null \
        | grep -q '^dnscrypt-proxy.service'; then

        echo "installing dnscrypt-proxy..."

        # download package
        downloadPackage "dnscrypt-proxy" "$DNSCRYPT_PROXY_URL"

        # cleanup and extract
        rm -rf "$dnscryptproxyDir/$DNSCRYPT_GZIP_FOLDER"
        tar -xzf "$dnscryptproxyDir/$archiveName" -C "$dnscryptproxyDir/"

        # prepare config in /tmp before moving to /opt
        cp "$CONFIG_DIR/dnscrypt-proxy/dnscrypt-proxy.toml" "$dnscryptproxyDir/$DNSCRYPT_GZIP_FOLDER/dnscrypt-proxy.toml"

        # install to /opt
        sudo rm -rf "$installDir"
        sudo mkdir -p "/opt/dnscrypt-proxy"
        sudo cp -r "$dnscryptproxyDir/$DNSCRYPT_GZIP_FOLDER" "/opt/dnscrypt-proxy/"

        # check configuration
        if ! ( cd "$installDir" && ./dnscrypt-proxy -check >/dev/null 2>&1 ); then
            echo -e "[ ${RED}FAIL${NC} ] dnscrypt-proxy config syntax is invalid! check $installDir/dnscrypt-proxy.toml" >&2
            exit 1
        else
            echo -e "[ ${GREEN}OK${NC}   ] dnscrypt-proxy config syntax is valid."
        fi

        # service registration
        (
            cd "$installDir"
            sudo ./dnscrypt-proxy -service install
            sudo ./dnscrypt-proxy -service start
        )

        # configure dnsmasq to point to dnscrypt-proxy
        if systemctl is-active --quiet dnsmasq.service; then
            sed -e "s|IFLAN|$ifLan|g" \
                -e "s|IFWAN|$ifWan|g" \
                -e "s|LANSUFFIX|$lanSuffix|g" \
                "$CONFIG_DIR/dnsmasq/$DNSMASQ_MASTER_CONFIG" > "$TMP_DIR/$DNSMASQ_CONFIG"

            sudo cp "$TMP_DIR/$DNSMASQ_CONFIG" "/etc/dnsmasq.d/$DNSMASQ_CONFIG"
            sudo systemctl restart dnsmasq.service
        fi
        echo "dnscrypt-proxy configuration complete."
    else
        echo "dnscrypt-proxy is installed already."
    fi

    return 0
}

## configure / install dnsmasq
## exits script if dnsmasq configuration is invalid
function handleDnsmasq() {
    echo
    echo "***********"
    echo "* dnsmasq *"
    echo "***********"

    # Ubuntu autostarts dnsmasq → mask before install
    # Debian/Sparky/Devuan do NOT support masked installs
    local mask_dnsmasq="false"
    if [[ "$DISTRO" == "ubuntu" ]]; then
        mask_dnsmasq="true"
    fi

    # install dnsmasq with correct masking behavior
    installPackage 'dnsmasq' "$mask_dnsmasq"
    local installStatus=$?

    # configure if:
    # - installStatus is 2 (newly installed) OR
    # - RECONFIG is true
    if [[ "$RECONFIG" == 'true' ]] || [[ $installStatus -eq 2 ]]; then
        echo "configuring dnsmasq..."

        # apply dnsmasq-specific settings (e.g., IGNORE_RESOLVCONF=yes)
        sudo cp "$CONFIG_DIR/dnsmasq/dnsmasq" "/etc/default/dnsmasq"

        # process the master configuration
        sed -e "s|IFLAN|$ifLan|g" \
            -e "s|IFWAN|$ifWan|g" \
            -e "s|LANSUFFIX|$lanSuffix|g" \
            "$CONFIG_DIR/dnsmasq/$DNSMASQ_MASTER_CONFIG" > "$TMP_DIR/$DNSMASQ_CONFIG"

        # safety check: test dnsmasq configuration syntax before applying
        if ! sudo dnsmasq --test -C "$TMP_DIR/$DNSMASQ_CONFIG"; then
            echo -e "[ ${RED}FAIL${NC} ] dnsmasq config syntax is invalid! check $TMP_DIR/$DNSMASQ_CONFIG" >&2
            exit 1
        else
             echo -e "[ ${GREEN}OK${NC}   ] dnsmasq config syntax is valid."
        fi
        sudo cp "$TMP_DIR/$DNSMASQ_CONFIG" "/etc/dnsmasq.d/$DNSMASQ_CONFIG"

        # apply systemd override (wait for dhcpcd and IFLAN before starting dnsmasq)
        # requires network-connected.sh in ExecStartPre
        sed "s|IFLAN|$ifLan|g" "$CONFIG_DIR/dnsmasq/dnsmasq-override.master.conf" > "$TMP_DIR/dnsmasq-override.conf"

        local override_dir="/etc/systemd/system/dnsmasq.service.d"
        sudo mkdir -p "$override_dir"
        sudo install -m 644 "$TMP_DIR/dnsmasq-override.conf" "$override_dir/override.conf"

        # reload systemd now to recognize the override before we start dnsmasq
        sudo systemctl daemon-reload

        # kill resolved (the point of no return)
        # we do this last to maintain dns connectivity as long as possible
        if systemctl is-active --quiet systemd-resolved.service || systemctl is-enabled --quiet systemd-resolved.service; then
            echo "disabling systemd-resolved to free port 53..."
            sudo systemctl disable --now systemd-resolved.service
            sudo systemctl mask systemd-resolved.service
        fi

        # process resolv.conf
        # remove symlink and replace it with static file pointing to localhost
        sed "s|LANSUFFIX|$lanSuffix|g" "$CONFIG_DIR/dnsmasq/resolv.master.conf" > "$TMP_DIR/resolv.conf"
        sudo rm -f "/etc/resolv.conf"
        sudo cp "$TMP_DIR/resolv.conf" "/etc/resolv.conf"

        # start dnsmasq
        sudo systemctl enable dnsmasq.service
        sudo systemctl restart dnsmasq.service
        echo "dnsmasq is now the primary DNS/DHCP server."
    fi

    return 0
}

## install dhcpcd
function handleDhcpcd() {
    echo
    echo "**********"
    echo "* dhcpcd *"
    echo "**********"

    # let the helper handle the existence check and installation
    installPackage 'dhcpcd' 'false'
    local installStatus=$?

    # configure if:
    # - installStatus is 2 (newly installed) OR
    # - RECONFIG is true
    if [[ "$RECONFIG" == 'true' ]] || [[ $installStatus -eq 2 ]]; then
        echo "configuring dhcpcd..."

        # process the master configuration
        sed -e "s|IFWAN|$ifWan|g" \
            -e "s|IFLAN|$ifLan|g" \
            -e "s|LANIPV4ADDRESS|$ifLanIpv4Address|g" \
            -e "s|LANIPV4CIDR|$ifLanIpv4Cidr|g" \
            -e "s|LANIPV6ADDRESS|$ifLanIpv6Address|g" \
            "$CONFIG_DIR/dhcpcd/dhcpcd.master.conf" > "$TMP_DIR/dhcpcd.conf"

        local dhcpcd_version="$(dpkg-query -W -f='${Version}' dhcpcd-base 2>/dev/null || echo '')"

        # blacklist broken dhcpcd 10.x versions for testing config syntax
        if dpkg --compare-versions "$dhcpcd_version" ge "1:10.0.0" && \
            dpkg --compare-versions "$dhcpcd_version" lt "1:10.5.2-2"; then

            echo -e "[ ${YELLOW}WARNING${NC} ] dhcpcd -T skipped (broken dhcpcd version: $dhcpcd_version)."
        else
            # check if the dhcpcd configuration is correct
            if ! sudo dhcpcd -T -f "$TMP_DIR/dhcpcd.conf" >/dev/null 2>&1; then
                echo -e "[ ${RED}FAIL${NC} ] dhcpcd config syntax is invalid! check $TMP_DIR/dhcpcd.conf" >&2
                exit 1
            else
                echo -e "[ ${GREEN}OK${NC}   ] dhcpcd config syntax is valid."
            fi
        fi

        sudo cp "$TMP_DIR/dhcpcd.conf" "/etc/dhcpcd.conf"

        # guard against NetworkManager if it survived the install
        if systemctl list-unit-files NetworkManager.service --no-legend 2>/dev/null \
            | grep -q '^NetworkManager.service'; then

            if systemctl is-active --quiet NetworkManager.service; then
                echo "disabling NetworkManager to prevent interface conflicts..."
                sudo systemctl stop NetworkManager.service
            fi

            if ! systemctl is-enabled NetworkManager.service 2>/dev/null | grep -q '^masked'; then
                sudo systemctl disable NetworkManager.service
                sudo systemctl mask NetworkManager.service
            fi
        fi

        sudo systemctl enable dhcpcd.service
        sudo systemctl restart dhcpcd.service
        echo "dhcpcd installation complete."
    fi

    return 0
}

## configure / reactivate systemd-resolved (undo retirement by handleDnsmasq)
## not in use in favor of dnsmasq
function handleSystemdResolved() {
    echo
    echo "********************"
    echo "* systemd-resolved *"
    echo "********************"

    local targetDir="/etc/systemd/resolved.conf.d"
    local targetFile="$targetDir/90-resolved.conf"
    local correctSymlink="/run/systemd/resolve/resolv.conf"

    # configure systemd-resolved if RECONFIG is true OR the drop-in file is missing
    if [[ "$RECONFIG" == 'true' ]] || [[ ! -f "$targetFile" ]]; then
        echo "configuring systemd-resolved drop-in..."

        sudo mkdir -p "$targetDir"
        sed "s|LANSUFFIX|$lanSuffix|g" "$CONFIG_DIR/systemd-resolved/90-resolved.master.conf" > "$TMP_DIR/90-resolved.conf"
        sudo cp "$TMP_DIR/90-resolved.conf" "$targetFile"

        # is systemd-resolved.service running?
        if ! systemctl is-active --quiet systemd-resolved.service; then
            echo "reactivating systemd-resolved..."

            sudo systemctl unmask systemd-resolved.service
            sudo systemctl enable systemd-resolved.service
        fi

        # fix the /etc/resolv.conf symbolic link in case it is broken
        if [[ "$(readlink /etc/resolv.conf)" != "$correctSymlink" ]]; then
            echo "replacing /etc/resolv.conf symlink..."

            sudo rm -f "/etc/resolv.conf"
            sudo ln -sf "$correctSymlink" "/etc/resolv.conf"
        fi

        # after disabling the StubListener, we must restart the service
        echo "restarting systemd-resolved to apply DNS changes..."
        sudo systemctl restart systemd-resolved.service

    else
        echo "systemd-resolved drop-in is already in place."
    fi

    return 0
}

# helper: check if module is builtin or loadable
has_flow_mod() {
    local mod="$1"
    local builtinFile="$2"
    grep -q "$mod" "$builtinFile" || sudo modinfo "$mod" >/dev/null 2>&1
}

## install nftables firewall
## exits scriot if the nftables configuration file is invalid
function handleNftables() {
    echo
    echo "************"
    echo "* nftables *"
    echo "************"

    # Ubuntu autostarts nftables → mask before install
    # Debian/Sparky/Devuan do NOT support masked installs
    local mask_nftables="false"
    if [[ "$DISTRO" == "ubuntu" ]]; then
        mask_nftables="true"
    fi

    # install nftables with correct masking behavior
    installPackage 'nftables' "$mask_nftables"
    local installStatus=$?

    # configure if:
    # - nftables not running OR
    # - installStatus is 2 (newly installed) OR
    # - RECONFIG is true
    if [[ "$RECONFIG" == 'true' ]] || [[ $installStatus -eq 2 ]] || \
        ! systemctl is-active --quiet nftables.service; then

        echo "configuring nftables..."

        # check if kernel support for flowtables is present
        # array of critical config symbols
        local symbols=(
            "CONFIG_NF_FLOW_TABLE"        # base engine
            "CONFIG_NF_FLOW_TABLE_INET"   # specific support for the inet family
            "CONFIG_NFT_FLOW_OFFLOAD"     # "bridge" between nftables and kernel's flowtable engine
        )

        local symbols_found=0
        local kConfig="/boot/config-$(uname -r)"
        local flowtable_support=false
        local nft_master

        for symbol in "${symbols[@]}"; do
            # check current kernel config file
            if grep -Eq "^${symbol}=(y|m)" "$kConfig"; then
                echo -e "[ ${GREEN}OK${NC}   ] $symbol"
                ((symbols_found++))
            else
                echo -e "[ ${YELLOW}WARNING${NC} ] $symbol: not enabled"
            fi
        done

        # configure flowtables only if support is present
        if (( symbols_found != ${#symbols[@]} )); then
            echo -e "[ ${YELLOW}WARNING${NC} ] flowtable kernel config incomplete." >&2
            flowtable_support=false
        else
            echo -e "[ ${GREEN}OK${NC}   ] flowtable support is present (kernel config)."
            flowtable_support=true
        fi

        # check if flowtable support is built-in or available as a module
        echo "checking flowtable support..."
        local builtinFile="/lib/modules/$(uname -r)/modules.builtin"

        if $flowtable_support && \
            has_flow_mod nf_flow_table "$builtinFile" && \
            has_flow_mod nf_flow_table_inet "$builtinFile"; then

            echo "flowtable support detected."

            # nf_flow_table builtin?
            if grep -q "nf_flow_table" "$builtinFile"; then
                echo "flowtable is built into the kernel; no modules to load."
                # ensure no old/conflicting config exists
                sudo rm -f "/etc/modules-load.d/nftables-flowtable.conf"
            else
                # if it's a module, ensure it's set to load on boot
                echo "loading flowtable modules..."
                sudo install -m 644 "$CONFIG_DIR/nftables/nftables-flowtable.conf" \
                    "/etc/modules-load.d/nftables-flowtable.conf"
                sudo modprobe -q nf_flow_table
                sudo modprobe -q nf_flow_table_inet
            fi

            nft_master="nftables-flowtables"

        else
            echo -e "[ ${YELLOW}WARNING${NC} ] flowtable support unavailable." >&2
            echo "falling back to non-flowtable nftables configuration."

            nft_master="nftables-noflowtables"
        fi

        # process nftables master configuration
        sed -e "s|IFWAN|$ifWan|g" \
            -e "s|IFLAN|$ifLan|g" \
            -e "s|LANIPV6ADDRESS|$ifLanIpv6Address|g" \
            "$CONFIG_DIR/nftables/$nft_master.master.conf" > "$TMP_DIR/nftables.conf"

        local nftables_version="$(dpkg-query -W -f='${Version}' nftables 2>/dev/null || echo '')"

        # blacklist all nftables 1.0.9 builds for syntax testing
        # known segfaults: LP #2142552 (netlink udata), nftables bugs #1731, #1763
        if [ -n "$nftables_version" ] && [[ "$nftables_version" == 1.0.9* ]]; then
            echo -e "[ ${YELLOW}WARNING${NC} ] broken nftables version: $nftables_version detected."
            echo -e "[ ${YELLOW}WARNING${NC} ] installing nftables from ubuntu resolute. please wait..."

            # add the ubuntu resolute repository
            sudo add-apt-repository "deb http://archive.ubuntu.com/ubuntu resolute main universe"
            sudo apt update

            # install nftables from resolute
            if ! sudo apt install -y -t resolute nftables; then
                sudo add-apt-repository --remove "deb http://archive.ubuntu.com/ubuntu resolute main universe"
                sudo apt update

                echo -e "[ ${RED}FAIL${NC} ] failed to install nftables from ubuntu resolute!" >&2
                exit 1
            else
                echo -e "[ ${GREEN}OK${NC}   ] nftables $(sudo nft --version | awk '{print $2}') installed."
            fi

            # remove the ubuntu resolute repository again
            sudo add-apt-repository --remove "deb http://archive.ubuntu.com/ubuntu resolute main universe"
            sudo apt update
        fi

        # safety check: test syntax before applying
        if ! sudo nft -nn -c -f "$TMP_DIR/nftables.conf"; then
            echo -e "[ ${RED}FAIL${NC} ] nftables config syntax is invalid! check $TMP_DIR/nftables.conf" >&2
            exit 1
        else
            echo -e "[ ${GREEN}OK${NC}   ] nftables config syntax is valid."
        fi

        # ensure UFW is not interfering
        if systemctl is-active --quiet ufw.service || systemctl is-enabled --quiet ufw.service; then
            echo "disabling and masking UFW..."
            sudo systemctl disable --now ufw.service
            sudo systemctl mask ufw.service
        fi

        sudo cp "$TMP_DIR/nftables.conf" "/etc/nftables.conf"

        sudo systemctl enable nftables.service
        sudo systemctl restart nftables.service
        echo "nftables configuration complete."
    fi

    return 0
}

## install chrony
function handleChrony() {
    echo
    echo "**********"
    echo "* chrony *"
    echo "**********"

    # Ubuntu autostarts chrony → mask before install
    # Debian/Sparky/Devuan do NOT support masked installs
    local mask_chrony="false"
    if [[ "$DISTRO" == "ubuntu" ]]; then
        mask_chrony="true"
    fi

    # install chrony if not present with correct masking behavior
    # returns 0 if already installed, 2 if newly installed
    installPackage 'chrony' "$mask_chrony"
    local installStatus=$?

    # configuration logic
    # we configure if: RECONFIG is true OR it's a new install OR the custom chrony config is missing
    if [[ "$RECONFIG" == 'true' ]] || [[ $installStatus -eq 2 ]] || \
        [[ ! -f "/etc/chrony/conf.d/lan-access-ntp.conf" ]]; then
        echo "configuring chrony..."

        # update NTP sources
        sudo mkdir -p "/etc/chrony/sources.d"
        sudo cp "$CONFIG_DIR/chrony/regional-pool-ntp.sources" "/etc/chrony/sources.d/regional-pool-ntp.sources"

        # update LAN access configuration
        sudo mkdir -p "/etc/chrony/conf.d"

        # replace ip addresses in the master config
        sed -e "s|LANIPV4ADDRESS|$ifLanIpv4Address|g" \
            -e "s|LANIPV6ADDRESS|$ifLanIpv6Address|g" \
            "$CONFIG_DIR/chrony/lan-access-ntp.master.conf" > "$TMP_DIR/lan-access-ntp.conf"

        sudo cp "$TMP_DIR/lan-access-ntp.conf" "/etc/chrony/conf.d/lan-access-ntp.conf"

        # validate chrony configuration
        # chrony also validates the NTP sources, which need to and have been copied previously

        # make sure the service is really stopped (this is REQUIRED)
        sudo systemctl stop chrony.service

        if ! sudo chronyd -p -f "/etc/chrony/conf.d/lan-access-ntp.conf" >/dev/null; then
            echo -e "[ ${RED}FAIL${NC} ] chrony config syntax is invalid! check $TMP_DIR/lan-access-ntp.conf" >&2
            exit 1
        else
            echo -e "[ ${GREEN}OK${NC}   ] chrony config syntax is valid."
        fi

        # restart chrony
        echo "starting chrony..."
        sudo systemctl enable chrony.service
        sudo systemctl restart chrony.service

        # FAIL-SAFE CHECK: only disable timesyncd if chrony is actually working
        if systemctl is-active --quiet chrony.service; then
            if systemctl is-active --quiet systemd-timesyncd || systemctl is-enabled --quiet systemd-timesyncd; then
                echo "chrony is active. disabled systemd-timesyncd..."
                sudo systemctl disable --now systemd-timesyncd
                sudo systemctl mask systemd-timesyncd
            fi
        else
            echo -e "[ ${YELLOW}WARNING${NC} ] chrony failed to start. leaving systemd-timesyncd active as fallback." >&2
        fi

        echo "chrony configured successfully."
    fi

    return 0
}

## test kernel parameter config files
testSysctldConfig() {
    local file="$1"
    if ! sudo sysctl -p "$file" --dry-run >/dev/null; then
        echo -e "[ ${RED}FAIL${NC} ] invalid sysctl configuration file: $file" >&2
        exit 1
    else
        echo -e "[ ${GREEN}OK${NC}   ] $file"
    fi
}

## copy kernel parameter configuration files
handleSysctld() {
    echo
    echo "***********"
    echo "* sysctld *"
    echo "***********"
    echo "configuring kernel for 40G routing and Web/QUIC performance..."

    local conntrackInit='false'
    local sysctldChanged='false'

    # handle conntrack early‑load files (two files, same logic)
    local -A conntrackFiles=(
        ["/etc/modprobe.d/conntrack.conf"]="$CONFIG_DIR/sysctld/conntrack.conf"
        ["/etc/modules-load.d/nf_conntrack.conf"]="$CONFIG_DIR/sysctld/nf_conntrack.conf"
    )

    for target in "${!conntrackFiles[@]}"; do
        local src="${conntrackFiles[$target]}"
        if [[ "$RECONFIG" == 'true' || ! -f "$target" ]]; then
            echo "copying $(basename "$target")..."
            sudo cp "$src" "$target"
            conntrackInit='true'
        else
            echo "$(basename "$target") exists already."
        fi
    done

    if [[ "$conntrackInit" == 'true' ]]; then
        echo "updating initramfs to include nf_conntrack configuration..."
        if sudo update-initramfs -u -k all; then
            echo "success: boot image updated."
        else
            echo -e "[ ${RED}FAIL${NC} ] initramfs update failed! check disk space in /boot!" >&2
            exit 1
        fi
    fi

    # explicitly ensure nf_conntrack is loaded into the active kernel session
    # checking /proc/sys/net/netfilter/nf_conntrack_max guarantees the conntrack sysctl leaf exists
    if [[ ! -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        echo "loading nf_conntrack module into running kernel..."
        if ! sudo modprobe nf_conntrack; then
            echo -e "[ ${RED:-}FAIL${NC:-} ] failed to load nf_conntrack kernel module!" >&2
            exit 1
        fi

        # verify the sysctl leaf exists after modprobe
        if [[ ! -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
            echo -e "[ ${RED:-}FAIL${NC:-} ] nf_conntrack loaded but /proc sysctl leaf is missing (container/namespace restriction?)" >&2
            exit 1
        fi
    fi

    # handle sysctl.d files (generic loop)
    local -A sysctlFiles=(
        ["$SYSCTLD_NET_CONFIG"]="$CONFIG_DIR/sysctld/$SYSCTLD_NET_CONFIG"
        ["$SYSCTLD_TCPUDP_CONFIG"]="$CONFIG_DIR/sysctld/$SYSCTLD_TCPUDP_CONFIG"
        ["$SYSCTLD_MEMIO_CONFIG"]="$CONFIG_DIR/sysctld/$SYSCTLD_MEMIO_CONFIG"
    )

    # special case: WAN IPv6 file is templated
    local wanTmp="$TMP_DIR/$SYSCTLD_WANIPV6_CONFIG"
    if [[ "$RECONFIG" == 'true' || ! -f "/etc/sysctl.d/$SYSCTLD_WANIPV6_CONFIG" ]]; then
        echo "generating $SYSCTLD_WANIPV6_CONFIG for interface $ifWan..."
        sed "s|IFWAN|$ifWan|g" \
            "$CONFIG_DIR/sysctld/$SYSCTLD_WANIPV6_MASTER_CONFIG" > "$wanTmp"
        testSysctldConfig "$wanTmp"
        sudo cp "$wanTmp" "/etc/sysctl.d/$SYSCTLD_WANIPV6_CONFIG"
        sysctldChanged='true'
    else
        echo "$SYSCTLD_WANIPV6_CONFIG exists already."
    fi

    # generic sysctl.d file handling
    for name in "${!sysctlFiles[@]}"; do
        local src="${sysctlFiles[$name]}"
        local dst="/etc/sysctl.d/$name"

        if [[ "$RECONFIG" == 'true' || ! -f "$dst" ]]; then
            echo "copying $name..."
            testSysctldConfig "$src"
            sudo cp "$src" "$dst"
            sysctldChanged='true'
        else
            echo "$name exists already."
        fi
    done

    # apply sysctl changes and verify persistence
    if [[ "$sysctldChanged" == 'true' || "$conntrackInit" == 'true' ]]; then
        echo "restarting systemd-sysctl.service to apply kernel parameters..."
        if ! sudo systemctl restart systemd-sysctl.service; then
            echo -e "[ ${RED}FAIL${NC} ] failed to restart systemd-sysctl.service!" >&2
            exit 1
        fi
    fi

    return 0
}

## optional: shape outgoing internet traffic
function handleNetqos() {
    echo
    echo "**********"
    echo "* netqos *"
    echo "**********"

    local trafficOut
    local connInput
    local overhead
    local govInput
    local governor
    local cakeservices

    echo "internet upload speed in Mbps (1-10000)?"
    while read -p "enter speed: " trafficOut; do
        if [[ "$trafficOut" =~ ^[0-9]+$ && "$trafficOut" -ge 1 && "$trafficOut" -le 10000 ]]; then
            break
        else
            echo "invalid input. please enter a number between 1 and 10000:" >&2
        fi
    done
    # convert mbit to kbit
    trafficOut=$(( trafficOut * 1000 ))

    echo "internet connection type (cable, dsl, fiber)?"
    while read -p "enter c, d or f: " connInput; do
        connInput="${connInput,,}"
        case "$connInput" in
            c)
                # DOCSIS framing
                overhead='overhead 18 docsis'
                break
                ;;
            d)
                # VDSL2/PTM usually needs more (44 is a safe bet for PPPoE+VLAN)
                overhead='overhead 44 ptm'
                break
                ;;
            f)
                # Fiber is usually 18 (Ethernet) or 26 (Ethernet + VLAN + PPPoE)
                # We'll use 18 as a clean baseline for FTTH.
                overhead='overhead 18'
                break
                ;;
            *)
                echo "invalid input. please enter c, d or f:" >&2
                ;;
        esac
    done

    echo "use global or per-queue governor (use global for now)?"
    while read -p "enter g or q: " govInput; do
        govInput="${govInput,,}"
        case "$govInput" in
            g)
                governor='global'
                cakeservices='netqos.service'
                break
                ;;
            q)
                governor='mq'
                cakeservices='netqos.service cake-governor.service'
                break
                ;;
            *)
                echo "invalid input. please enter g or q:" >&2
                ;;
        esac
    done

    echo "preparing netqos + cake-governor service integration..."

    # ensure /usr/local/sbin exists
    sudo mkdir -p "/usr/local/sbin"

    for name in 'netqos' 'cake-governor'; do
        out="$TMP_DIR/$name.sh"

        # render template
        sed -e "s|IFWAN|$ifWan|g" \
            -e "s|MAXUPLINKSPEED|$trafficOut|g" \
            -e "s|OVRHD|$overhead|g" \
            -e "s|TCMODE|$governor|g" \
            "$CONFIG_DIR/netqos/$name.master.sh" > "$out"
        # install
        sudo install -m 755 "$out" "/usr/local/sbin/$name.sh"
    done

    # uninstall cake-governor.service if it is not used
    if [[ "$governor" == 'global' && -f '/etc/systemd/system/cake-governor.service' ]]; then
        sudo systemctl disable --now cake-governor.service
        sudo rm "/etc/systemd/system/cake-governor.service"
    fi

    # prepare netqos.service
    sed -e "s|IFWAN|$ifWan|g" \
        "$CONFIG_DIR/netqos/netqos.master.service" > "$TMP_DIR/netqos.service"
    sudo install -m 644 "$TMP_DIR/netqos.service" "/etc/systemd/system/netqos.service"

    # prepare cake-governor.service (only needed in mq mode)
    if [[ "$governor" = 'mq' ]]; then
        sudo install -m 644 "$CONFIG_DIR/netqos/cake-governor.service" "/etc/systemd/system/cake-governor.service"
    fi

    # prepare UDEV netqos.rules
    sed -e "s|IFWAN|$ifWan|g" \
        "$CONFIG_DIR/netqos/90-netqos.master.rules" > "$TMP_DIR/90-netqos.rules"
    sudo install -m 644 "$TMP_DIR/90-netqos.rules" "/etc/udev/rules.d/90-netqos.rules"

    # reload udev rules
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=net

    # handle service state and reload
    sudo systemctl daemon-reload

    # NOTE: $cakeservices is left unquoted deliberately to allow multiple parameters
    for service in $cakeservices; do
        sudo systemctl enable "$service"
        sudo systemctl restart "$service"

        if systemctl is-active --quiet "$service"; then
            echo -e "[ ${GREEN}OK${NC}   ] $service is running."
        else
            echo -e "[ ${RED}FAIL${NC} ] $service failed to start!" >&2
            systemctl status "$service" --no-pager
            exit 1
        fi
    done

    echo "WAN interface: $ifWan"
    echo "netqos mode: $governor"
    echo "upload speed:  ${trafficOut}kbit"
    echo "overhead:    $overhead"

    return 0
}

## optional: set up dDNS client from source
function handleDdclient() {
    echo
    echo "************"
    echo "* ddclient *"
    echo "************"

    local archiveName=$(basename "$DDCLIENT_URL")
    local ddclientDir="$TMP_DIR/ddclient"
    local buildDir="$ddclientDir/$DDCLIENT_GZIP_FOLDER"

    # clean uninstall
    # we run this if RECONFIG is true, AND if we find an existing binary/service
    if [[ "$RECONFIG" == 'true' ]] && systemctl list-unit-files ddclient.service --no-legend 2>/dev/null \
        | grep -q '^ddclient.service'; then

        echo "purging ddclient..."

        # stop and disable service
        sudo systemctl disable --now ddclient.service

        # kill any lingering Perl daemon processes
        sudo killall ddclient 2>/dev/null

        # manually remove all files created by 'make install'
        # this covers binaries, configs, and systemd units
        # remove binaries and systemd units
        sudo rm -f "/usr/bin/ddclient"
        sudo rm -f "/usr/sbin/ddclient"
        sudo rm -f "/usr/local/bin/ddclient"
        sudo rm -f "/etc/systemd/system/ddclient.service"
        sudo rm -rf "/etc/systemd/system/ddclient.service.d"
        sudo rm -f "/lib/systemd/system/ddclient.service"
        sudo rm -f "/usr/lib/systemd/system/ddclient.service"

        # purge configuration and IP state cache
        sudo rm -rf "/etc/ddclient"
        sudo rm -rf "/var/cache/ddclient"
        sudo rm -rf "/var/run/ddclient"
        sudo rm -f "/var/run/ddclient.pid"

        # reload systemd to confirm the service is gone from memory
        sudo systemctl daemon-reload
        echo "purge complete."
    fi

    # installation logic
    # check if binary is missing or service is not present
    if ! command -v ddclient &>/dev/null || ! systemctl list-unit-files ddclient.service --no-legend 2>/dev/null \
        | grep -q '^ddclient.service'; then

        echo "starting fresh source build and installation of ddclient..."

        # modern dependencies for 4.0+ (HTTP::Daemon and JSON support)
        for pkg in 'perl' 'curl' 'libio-socket-ssl-perl' 'libjson-pp-perl'; \
            do installPackage "$pkg" 'false'; done

        # download
        downloadPackage "ddclient" "$DDCLIENT_URL"

        # always clear and re-extract build dir to ensure a clean 'make'
        rm -rf "$buildDir"
        tar -xzf "$ddclientDir/$archiveName" -C "$ddclientDir/"

        # build and install
        if ! (
            cd "$buildDir" || exit 1
            ./configure --prefix='/usr' --sysconfdir='/etc' --localstatedir='/var' >/dev/null 2>&1
            make -s && sudo make -s install >/dev/null 2>&1
        ); then
            echo -e "[ ${RED}FAIL${NC} ] ddclient build or installation failed!" >&2
            exit 1
        fi

        # service file deployment
        if [[ -f "$buildDir/sample-etc_systemd.service" ]]; then
            sudo cp "$buildDir/sample-etc_systemd.service" "/etc/systemd/system/ddclient.service"
        elif [[ -f "$buildDir/sample-etc_systemd.service.in" ]]; then
            sudo cp "$buildDir/sample-etc_systemd.service.in" "/etc/systemd/system/ddclient.service"
            sudo sed -i 's|@prefix@|/usr|g' "/etc/systemd/system/ddclient.service"
        fi

        # deploy config
        sudo mkdir -p "/etc/ddclient"
        sudo cp "$CONFIG_DIR/ddclient/ddclient.conf" "/etc/ddclient/ddclient.conf"
        sudo chown root:root "/etc/ddclient/ddclient.conf"
        sudo chmod 600 "/etc/ddclient/ddclient.conf"

        # apply systemd override (ExecStartPre network-connected.sh)
        sed "s|IFWAN|$ifWan|g" "$CONFIG_DIR/ddclient/ddclient-override.master.conf" > "$TMP_DIR/ddclient-override.conf"
        local override_dir="/etc/systemd/system/ddclient.service.d"
        sudo mkdir -p "$override_dir"
        sudo install -m 644 "$TMP_DIR/ddclient-override.conf" "$override_dir/override.conf"

        # finalize
        sudo systemctl daemon-reload
        sudo systemctl enable --now ddclient.service
        echo -e "[ ${GREEN}OK${NC}   ] ddclient successfully installed and started."
    else
        echo "ddclient is already present. skipping installation."
    fi

    return 0
}

## optional: set up LDAP server
function handleSlapd() {
    echo
    echo "*********"
    echo "* slapd *"
    echo "*********"

    local base_dn="o=phonebook,dc=router,dc=lan"

    # uninstall (if RECONFIG is true)
    if [[ "$RECONFIG" == 'true' ]] && systemctl list-unit-files slapd.service --no-legend 2>/dev/null \
        | grep -q '^slapd.service'; then

        echo "reconfiguration triggered. purging slapd..."

        # stop the service
        sudo systemctl stop slapd

        # tell debconf to forget slapd settings properly
        sudo debconf-communicate slapd <<< "PURGE" >/dev/null

        # perform the purge (this removes binaries and systemd units)
        sudo apt-get purge -y slapd >/dev/null

        # clean up the data directories
        # note: /etc/ldap is often shared; be sure you want the whole folder gone
        sudo rm -rf /var/lib/ldap /etc/ldap/slapd.d
    fi

    # installation (standard)
    if ! systemctl list-unit-files slapd.service --no-legend 2>/dev/null \
        | grep -q '^slapd.service'; then

        echo "installing slapd..."

        installPackage 'ldap-utils' 'false'
        installPackage 'slapd' 'false'

        # wait for the LDAP ldapi socket
        local timeout=0
        local max_wait=15
        local socket_path="/run/slapd/ldapi"

        echo "waiting for slapd to initialize..."
        while [[ ! -S "$socket_path" ]]; do
            if (( timeout >= max_wait )); then
                echo -e "[ ${RED}FAIL${NC} ] slapd did not create socket at $socket_path after ${max_wait}s!" >&2
                # check if the service actually failed to help with debugging
                systemctl status slapd --no-pager
                exit 1
            fi

            # check if the process died while we were waiting
            if ! systemctl is-active --quiet slapd && (( timeout > 2 )); then
                echo -e "[ ${RED}FAIL${NC} ] slapd service stopped unexpectedly during startup!" >&2
                exit 1
            fi

            printf "waiting for slapd to initialize... (%ds)\n" "$timeout"

            sleep 1
            ((timeout++))
        done

        echo -e "[ ${GREEN}OK${NC}   ] slapd is ready (ldapi socket found)."
    fi

    # fix permissions - ensure the openldap user owns the newly created data
    local ldap_dirs=("/var/lib/ldap/phonebook" "/etc/ldap/slapd.d")

    for dir in "${ldap_dirs[@]}"; do
        sudo install -d -m 700 -o openldap -g openldap "$dir"
    done

    # database addition and data import
    local ldap_info
    ldap_info=$(sudo ldapsearch -Q -Y EXTERNAL -H "ldapi:///" \
        -b "cn=config" "(olcSuffix=$base_dn)" olcDatabase -LLL 2>/dev/null)

    if [[ -z "$ldap_info" ]]; then
        echo "phonebook suffix not found. creating database..."

        # apply the configuration online
        sudo ldapmodify -Q -Y EXTERNAL -H "ldapi:///" -f "$CONFIG_DIR/slapd/$SLAPD_MODIFY_DB" \
            || { echo -e "[ ${RED}FAIL${NC} ] failed to apply $SLAPD_MODIFY_DB!" >&2; exit 1; }

        # sudo ldapadd -Q -Y EXTERNAL -H "ldapi:///" -f "$CONFIG_DIR/slapd/$SLAPD_CREATE_DB" \
        #    || { echo -e "[ ${RED}FAIL${NC} ] failed to apply $SLAPD_CREATE_DB!" >&2; exit 1; }

        # extract DB ID - this captures the number inside the curly braces {}
        local slapDbId
        slapDbId=$(sudo ldapsearch -Q -Y EXTERNAL -H "ldapi:///" \
            -b "cn=config" "(olcSuffix=$base_dn)" olcDatabase -LLL | sed -n 's/^dn: olcDatabase={\([0-9]\+\)}.*/\1/p')

        if [[ -z "$slapDbId" ]]; then
            echo -e "[ ${RED}FAIL${NC} ] database ID detection failed!" >&2
            exit 1
        fi

        echo -e "[ ${GREEN}OK${NC}   ] database configuration complete."

        # stop slapd to perform offline 'slapadd'
        echo "stopping slapd for bulk import (DB ID: $slapDbId)..."
        sudo systemctl stop slapd

        # double check service is actually dead (slapadd will corrupt the DB if slapd is running)
        if ! systemctl is-active --quiet slapd; then
            sudo slapadd -l "$CONFIG_DIR/slapd/$SLAPD_INIT_DB" -n "$slapDbId" || \
                { echo -e "[ ${RED}FAIL${NC} ] slapadd failed! check if $SLAPD_INIT_DB is valid!" >&2; exit 1; }
            sudo systemctl start slapd
            echo -e "[ ${GREEN}OK${NC}   ] phonebook database initialized successfully."
        else
            echo -e "[ ${RED}FAIL${NC} ] could not stop slapd. offline import aborted to prevent corruption." >&2
            exit 1
        fi
    else
        echo "phonebook database already exists ($base_dn)."
    fi

    return 0
}

### main

# check passed parameter
if (( $# > 1 )); then
    echo "only the -reconfig option can be passed."
    exit 1
fi

# handle Arguments
RECONFIG='false'
if [[ $# -eq 1 ]]; then
    case "$1" in
        -reconfig|--reconfig|reconfig) RECONFIG=true ;;
        *) echo "unknown parameter: $1. usage: $0 [-reconfig]"; exit 1 ;;
    esac
fi

## check for preconditions
if systemd-notify --booted; then
    echo -e "[ ${GREEN}OK${NC}   ] systemd is active."
else
    echo -e "[ ${RED}FAIL${NC} ] systemd is not active!" >&2
fi

DISTRO="$(detectDistro)"

echo

# explain what this script does
cat << EOF
this script adds router functionality to your debian-/ubuntu- based system:
- routing & connection sharing
- firewall (nftables) & traffic shaping (tc)
- dns (dnsmasq + dnscrypt-proxy)
- dhcp (dhcpcd) & ntp (chrony)
- optional: qos, ddclient, ldap and custom hosts
EOF

echo
echo "detected distro base: $DISTRO"

# ask user to proceed
echo -n "do you want to continue (Y/n)? "
[[ $(getYesNoResponse 'y') == 'n' ]] && exit 1

## ask user for basic data

# guess WAN: Find the interface with the default gateway
guessWan=$(ip route show default | awk '{print $5}' | head -n1)

# guess LAN: find LAN (physical, up, not WAN, not virtual)
guessLan=""
# regex to exclude virtual/management interfaces
exclude_pattern='^(lo|docker|br-|veth|virt|w6p|tun|tap)'

for ifacePath in /sys/class/net/*; do
    iface=${ifacePath##*/}

    # skip unwanted interfaces
    [[ "$iface" =~ $exclude_pattern ]] && continue
    [[ "$iface" == "$guessWan" ]] && continue

    # store the first valid one as a fallback
    [[ -z "$guessLan" ]] && guessLan="$iface"

    # prioritize interfaces that are 'up'
    if [[ "$(<"/sys/class/net/$iface/operstate")" == "up" ]]; then
        guessLan="$iface"
        break
    fi
done

# WAN interface name
while true; do
    read -p "name of wan interface (suggested: $guessWan): " ifWan
    ifWan=${ifWan:-$guessWan}
    [[ -d "/sys/class/net/$ifWan" ]] && break || echo "interface '$ifWan' not found."
done

# LAN interface name
while true; do
    read -p "name of lan interface (suggested: $guessLan): " ifLan
    ifLan=${ifLan:-$guessLan}
    if [[ ! -d "/sys/class/net/$ifLan" ]]; then
        echo "interface '$ifLan' not found. try again."
    elif [[ "$ifLan" == "$ifWan" ]]; then
        echo "wan and lan interfaces cannot be the same. try again."
    else
        break;
    fi
done

# LAN Address Configuration
ifLanAddrConf="$CONFIG_DIR/$IF_LAN_ADDRESSES"
ifLanAddressesValid='true'
lanSuffix="$LAN_SUFFIX"

if [[ -f "$ifLanAddrConf" ]]; then
    # read values (strip whitespace around '=')
    ifLanIpv6Address=$(sed -rn 's/^iflan-ipv6-address\s*=\s*([^# ]+).*/\1/p' "$ifLanAddrConf")
    ifLanIpv4Address=$(sed -rn 's/^iflan-ipv4-address\s*=\s*([^# ]+).*/\1/p' "$ifLanAddrConf")
    ifLanIpv4Cidr=$(sed -rn 's/^iflan-ipv4-cidr\s*=\s*([^# ]+).*/\1/p' "$ifLanAddrConf")
    tmpSuffix=$(sed -rn 's/^lan-suffix\s*=\s*([^# ]+).*/\1/p' "$ifLanAddrConf")
    [[ -n "$tmpSuffix" ]] && lanSuffix="$tmpSuffix"

    # validate IPv6: must not be empty AND must start with fdXX (ULA prefix)
    if [[ -z "$ifLanIpv6Address" || ! "$ifLanIpv6Address" =~ ^fd[0-9a-fA-F]{2} ]]; then
        ifLanAddressesValid='false'
    fi

    # validate IPv4: must be in RFC 1918 private ranges
    if [[ -z "$ifLanIpv4Address" || ! "$ifLanIpv4Address" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
        ifLanAddressesValid='false'
    fi

    # validate CIDR (make sure DHCP has a decent pool to assign)
    if ! [[ "$ifLanIpv4Cidr" =~ ^[0-9]+$ ]] || (( ifLanIpv4Cidr < 8 )) || (( ifLanIpv4Cidr > 24 )); then
        ifLanAddressesValid='false'
    fi
else
    ifLanAddressesValid='false'
fi

if [[ "$ifLanAddressesValid" == 'false' ]]; then
    echo -e "${YELLOW}WARNING:${NC} missing or invalid lan config in $ifLanAddrConf. using (generated) defaults."
    ifLanIpv6Address=$(printf "fd%02x:%04x:%04x::1" "$((RANDOM & 0xff))" "$((RANDOM & 0xffff))" "$((RANDOM & 0xffff))")
    ifLanIpv4Address="$PRIVATE_IPV4_LAN_ADDRESS"
    ifLanIpv4Cidr="$PRIVATE_IPV4_LAN_CIDR"
fi

echo -e "\nfinal lan configuration:\n  ipv6: $ifLanIpv6Address/64\n  ipv4: $ifLanIpv4Address/$ifLanIpv4Cidr\n"
echo -e "  lan suffix: $lanSuffix\n"

## install required components
echo "installing essential packages..."
# TODO; in-comment the following line
# sudo apt update
for pkg in wget tar make build-essential; do installPackage "$pkg" 'false'; done

# create folder to setup configuration files
mkdir -p "$TMP_DIR"

# prepare network-connected.sh, get-ip6-from-ifwan.sh scripts
# these are used with dnsmasq (network-connected.sh) and
# ddclient (network-connected.sh, get-ip-from-ifwan.sh)
# but can also suit a more generic context
echo
ddscripts=(
    "network-connected.sh"
    "get-ip6-from-ifwan.sh"
)

for ddscript in "${ddscripts[@]}"; do
    target="/usr/local/bin/$ddscript"
    master="../lib/${ddscript%.sh}.master.sh"
    tmp="$TMP_DIR/$ddscript"

    if [[ "$RECONFIG" == "true" ]] || [[ ! -f "$target" ]]; then
        echo "installing script: $ddscript"

        # check sed result before installing script
        if sed "s|IFWAN|$ifWan|g" "$master" > "$tmp"; then
            sudo install -m 755 "$tmp" "$target"
        else
            echo -e "[ ${RED}FAIL${NC} ] failed to process template for $ddscript" >&2
            exit 1
        fi
    fi
done

### FOR TESTING FUNCTIONS
# handleSystemdResolved
# exit 0
### END FOR TESTING FUNCTIONS

# copy kernel parameter configuration files
handleSysctld

# install nftables firewall
handleNftables

# install dhcpcd
handleDhcpcd

# install dnscrypt-proxy
handleDnscryptProxy

# configure systemd-resolved
# this service is disabled by handleDnsmasq,
# so it is out-commented here
# handleSystemdResolved

# install dnsmasq
handleDnsmasq

# install / configure chrony
handleChrony

## install optional components
echo
echo -n "replace system hosts file (y/N)? "
[[ $(getYesNoResponse 'n') == 'y' ]] && { sudo cp "$CONFIG_DIR/hosts" "/etc/hosts"; echo "hosts replaced."; }

echo -n "shape outgoing traffic (Y/n)? "
[[ $(getYesNoResponse 'y') == 'y' ]] && handleNetqos

echo -n "set up dynamic dns client (y/N)? "
[[ $(getYesNoResponse 'n') == 'y' ]] && handleDdclient

echo -n "set up ldap server (y/N)? "
[[ $(getYesNoResponse 'n') == 'y' ]] && handleSlapd

echo
echo "router setup complete. please reboot."

exit 0
