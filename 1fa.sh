#!/bin/bash
#
# This script disables google-authenticator 2fa authentication by:
#   
# 1. Writing to: /etc/ssh/sshd_config.d/tmp_disabled_2fa_for_[USERNAME].conf
#    Match User [USERNAME] Address [USER_IP_ADDR]
#        PasswordAuthentication yes
#        AuthenticationMethods password
#
# 2. Renaming: /home/[USERNAME]/.google_authenticator
#    To:       /home/[USERNAME]/.google_authenticator_tmp_disabled
#
# It then reenables 2fa by reverting these changes.
#

# These are resolved and validated in main()
username=
ip_addr=
ga_path=
sshd_conf_path=

# Options
window=10

# So we can restore the changes on SIGINT/CTRL_C
script_aborted=0

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT

# shellcheck disable=SC2317
function ctrl_c() {
    script_aborted=1
}

# Broadcasts a message to the user on all ttys
function broadcast () {
    find /dev/pts -mindepth 1 -maxdepth 1 -type c -user "$username" -print | while read -r tty; do
        echo -e "$@" | write "$username" "$tty"
    done
}

function try () {
    echo -en "\e[33m$1\e[0m \e[3m$2\e[0m: \e[91m"
}

function catch () {
    echo -en "\e[0m"

    if (( $1==0 )) then
        echo -e "\e[92mOK\e[0m "
    fi
}

# Disables .google_authenticator
function ga_path_disable {
    local code=
    local ga_from=$ga_path
    local ga_dest="${ga_path}_tmp_disabled"

    try "Suffixing " "$ga_from"
    mv "$ga_from" "$ga_dest"
    code=$?
    catch $code
    return $code
}

# Restores .google_authenticator
function ga_path_restore {
    local code=
    local ga_from="${ga_path}_tmp_disabled"
    local ga_dest=$ga_path

    try "Restoring " "$ga_from"
    mv "$ga_from" "$ga_dest"
    code=$?
    catch $code
    return $code
}

# Writing the sshd configuration
function sshd_conf_create {
    local code=
    try "Creating  " "$sshd_conf_path"
    cat >"$sshd_conf_path" <<EOL
    Match User $username Address $ip_addr
        PasswordAuthentication yes
        AuthenticationMethods password
EOL
    code=$?
    catch $code
    return $code
}

# Restores the sshd configuration
function sshd_conf_restore {
    local code=
    try "Restoring " "$sshd_conf_path"
    rm "$sshd_conf_path"
    code=$?
    catch $code
    return $code
}

# Reloades the sshd configuration
function sshd_conf_reload () {
    local code=
    
    try "Validating" "/etc/ssh/sshd_config"
    sshd -t;
    code=$?
    catch $code
    
    if [ $code -eq 0 ]; then
        try "Restarting" "sshd"
        systemctl restart sshd
        code=$?
        catch $code
    fi

    return $code
}

function is_disabled () {
    local ga_from="${ga_path}_tmp_disabled"

    if [ ! -f "$sshd_conf_path" ] && [ ! -f "$ga_from" ]; then
        return 1
    fi
}

function restore_2fa () {
    echo ""
    echo "Restoring 2fa for user $username ..."

    if ! is_disabled; then 
        echo -e "\e[91mError: \033[K\e[0m2FA hasn't been deactivated for this account."
        exit 1
    fi

    local hasErrors=0

    if ! ga_path_restore; then
        hasErrors=1
    fi

    if ! sshd_conf_restore; then
        hasErrors=1
    fi

    if ! sshd_conf_reload; then
        hasErrors=1
    fi

    if (( hasErrors )) || is_disabled; then
        broadcast \
            " WARNING: Something went wrong while restoring 2FA for your account.\n"\
            "Make sure you can still connect to the server before closing this connection."
    else 
        broadcast "Two-Factor Authentication (2FA) has been restored for your account."
    fi

    return $hasErrors
}

function disable_2fa () {
    local emerg_restore

    echo ""
    echo "Disabling 2fa for user $username ..."

    emerg_restore=$(at now + 1 minutes 2>&1 <<< "./test --disable=${username}" | grep -Eo "^job [0-9]+" | cut -c 5-)

    echo "Scheduled emergency restoration of sshd configuration with job id $emerg_restore at now + 1 minutes. "

    if ! ga_path_disable; then
        ga_path_restore
        exit 1
    fi

    if ! sshd_conf_create; then
        sshd_conf_restore
        exit 1
    fi

    if ! sshd_conf_reload; then
        ga_path_restore
        sshd_conf_restore
        exit 1
    fi
    
    broadcast "Two-Factor Authentication (2FA) has been temporarily disabled for your account."

    if start_countdown; then
        echo -e "\n\e[92mScript exited successfully\e[0m "
        
        at -r "$emerg_restore" 2>&1
    else
        echo -e "\e[91mAn unhandled exception has occurred. Wait for the \e[0m"
    fi
}

function start_countdown () {
    local file=/var/log/auth.log
    local pattern="^.*logind\[[0-9]+\]: New session [0-9]+ of user ${username}\.$"
    local line_count
    local time_stop
    local time_left
    local prefix="\rWaiting for $username to connect..."

    line_count="$(wc -l $file | awk '{ print $1}')"

    time_stop=$(($(date +%s)+window))

    local success=0

    while true; do
        time_left=$((time_stop-$(date +%s)))
        
        echo -en "$prefix $time_left\033[K"

        # Check for connection from user
        success=!$(tail -n "+$line_count" "$file" | grep -qE "$pattern")$?

        if (( success )); then
            echo -e "$prefix \e[92muser $username connected 👍\033[K\e[0m"
            break
        fi

        if (( time_left < 1 )); then
            echo -e "$prefix \e[91mtime ran out\033[K\e[0m"
            break
        fi

        if (( script_aborted )); then
            echo -e "$prefix \e[91maborted\033[K\e[0m"
            break
        fi
        
        sleep 1
    done
    
    restore_2fa
}


function print_args_help () {
    if [ "$1" ]; then
        echo -e >&2 "\e[91mError:\033[K\e[0m"
        echo -e "  $*"
        echo ""
    fi

    cat >&2 <<EOF
Usage:
    $0 [-h] [-u <user> -a <ip>] [-r <user>] [-d]

Temporarily disables two-factor authenticator (2FA) for given account.

Options:
    -h, --help               Prints this message
    -u, --unsecure  <user>   Disables 2FA for given user
    -r, --restore   <user>   Enables (restores) 2FA for given user
    -a, --addr      <cidr>   CIDR address/masklen format
    -d, --dry                Prints the resolved arguments and exits script
    
Examples:
    $0 -u       # Disables 2FA for the current user and the current SSH client IP
    $0 -r bobby # Restores any changes made for bobbys account

    $0 -u bobby -a 10.1.1.4     # Let bobby connect from specific IP
    $0 -u bobby -a 10.1.1.0/24  # Let bobby connect from specific subnet
EOF

    if [ "$1" ]; then
        echo ""
        echo "Resolved options:"
        print_args

        exit 1
    fi
}

function args_verify-not-empty () {
    local value="$1"
    local varname="$2"

    if [ "$value" ]; then
        echo "$value"
    elif [ "$varname" ]; then
        print_args_help "$varname cannot handle an empty argument"
        exit 1
    else
        print_args_help \
            "The programmer forgot to include context, something was empty which shouldn't have been, but I can't tell you much more than that. Sorry :("
        exit 1
    fi
}

function print_args () {
    echo -e "username\e[2m.........\e[0m $username"
    echo -e "ip_addr\e[2m..........\e[0m $ip_addr"
    echo -e "ga_path\e[2m..........\e[0m $ga_path"
    echo -e "sshd_conf_path\e[2m...\e[0m $sshd_conf_path"
    echo -e "mode\e[2m.............\e[0m $mode"
}

function has_package () {
    dpkg-query -W -f='${Status}' $1 2>/dev/null | grep -cq "ok installed"
}

function main () {
    local mode="unknown"

    local opt_user=
    local opt_addr=
    local opt_dry=0

    if [[ $(/usr/bin/id -u) -ne 0 ]]; then
        print_args_help "This script must be run as root"
    fi

    if ! has_package "at"; then
        print_args_help \
        "This script requires package 'at\n" \
        " https://manpages.debian.org/testing/at/at.1.en.html"
    fi

    if ! has_package "libpam-google-authenticator"; then
        print_args_help \
        "This script requires package 'libpam-google-authenticator' to be installed\n" \
        " https://manpages.debian.org/testing/libpam-google-authenticator/pam_google_authenticator.8.en.html"
    fi

    while [ "$1" ]
    do
        case "$1" in
            '-h' | '--help')
                print_args_help
                exit 0
                ;;

            '-u' | '--unsecure')
                shift
                mode=disable
                opt_user=$1
                shift
                ;;
            '-r' | '--restore')
                shift
                mode=restore
                opt_user=$1
                shift
                ;;
            '-a' | '--addr')
                shift
                opt_addr=$(args_verify-not-empty "$1" addr)
                shift
                ;;
            '-d' | '--dry')
                shift
                opt_dry=1
                shift
                ;;
            *)
                print_args_help "Unrecognized argument: $1"
                exit 1
        esac
    done

    username="${opt_user:-$SUDO_USER}"
    ip_addr="${opt_addr:-$(echo "$SSH_CLIENT" | awk '{ print $1}')}"
    ga_path="/home/${username}/.google_authenticator"
    sshd_conf_path=/etc/ssh/sshd_config.d/tmp_disabled_2fa_for_${username}.conf

    if [ -z "${username}" ]; then
        print_args_help "Could not resolve username"
    else
        if ! id "$username" >/dev/null 2>&1; then
            print_args_help "User $username does not exist"
        fi
    fi

    if [ -z "${ip_addr}" ]; then
        print_args_help "Could not resolve ip address of this connection. Have you "
    fi

    if [ ! "$mode" == "restore" ] && [ ! "$mode" == "disable" ]; then
        print_args_help "Invalid mode \"$mode\". Mode can only be \"restore\" or \"enable\""
    fi
    
    echo Script starting
    print_args

    if (( opt_dry )); then
        echo -e "\n--dry goodbye"
        exit 0
    fi

    if [ "$mode" == "restore" ]; then
        restore_2fa
    elif [ "$mode" == "disable" ]; then
        disable_2fa
    fi
}

main "$@"


# last line
