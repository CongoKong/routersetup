#!/bin/bash
### script to reimport SLAPD_INIT_DB without reinstalling slapd
###
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

# stop script if a variable is used before being defined
set -u

# global variables
CONFIG_DIR='../config'

# slapd variables
SLAPD_INIT_DB='initldap.ldif'

# define target db dn
base_dn="o=phonebook,dc=router,dc=lan"

# locate db id and directory
ldap_info=$(sudo ldapsearch -Q -Y EXTERNAL -H "ldapi:///" \
    -o ldif-wrap=no \
    -b "cn=config" "(olcSuffix=$base_dn)" olcDatabase olcDbDirectory -LLL)

slapDbId=$(echo "$ldap_info" | grep -iP "^dn:\s*olcDatabase=" | head -n 1 | grep -oP '\{\K\d+(?=\})')
db_path=$(echo "$ldap_info" | grep -oiP '^olcDbDirectory:\s*\K.+' | head -n 1 | tr -d '\r')

if [[ -z "$slapDbId" || -z "$db_path" || "$db_path" == "/" ]] || ! sudo test -d "$db_path"; then
    echo "error: could not find ldap database or path for $base_dn!" >&2
    exit 1
fi

# shutdown slapd and wipe db
echo "stopping slapd..."
sudo systemctl stop 'slapd.service'

echo "wiping target: olcDatabase={$slapDbId} at $db_path for suffix $base_dn"
# use find to bypass shell expansion issues with sudo
sudo find "${db_path:?}" -mindepth 1 -delete

# verification checks (handling "ghost" processes or locks, permission failures, etc.)
if ! sudo test -d "$db_path"; then
     echo "error: directory $db_path does not exist!" >&2
     exit 1
fi

if [ "$(sudo ls -A "$db_path")" ]; then
     echo "error: directory $db_path is not empty! aborting to prevent corruption." >&2
     exit 1
fi

if sudo lsof +D "$db_path" 2>/dev/null | grep -q .; then
    echo "error: some process still has files open in $db_path!" >&2
    exit 1
fi

echo "verification: $db_path is clean. proceeding with import."

# db bulk import
echo "importing $SLAPD_INIT_DB into database id $slapDbId."
if sudo slapadd -n "$slapDbId" -l "$CONFIG_DIR/slapd/$SLAPD_INIT_DB"; then
    echo "check: slapadd completed successfully."
else
    echo "error: slapadd failed with exit code $?. import aborted!" >&2
    exit 1
fi

# reset permissions
sudo chown -R openldap:openldap "$db_path"

# restart and verify service
sudo systemctl start 'slapd.service'

if systemctl is-active --quiet 'slapd.service'; then
    echo "success: phonebook database reimported and slapd.service is running."
else
    echo "error: slapd failed to start after import! check journalctl -u slapd."
    exit 1
fi

exit 0
