#!/bin/sh

# Allow non-POSIX-standard "local" keyword. It's relatively easy to convert the script in the future if necessary.
# shellcheck disable=SC3043

# These are resolved and validated in main()
username=
ip_addr=
ga_path=
sshd_conf_path=

## Script options
window=30

# Number of minutes before the emergency 'at' job will restore the changes.
# 'at' jobs are persistent across reboots.
at_countdown=2 

#---
## DESC: Set to 1 if the user has pressed ctrl+c. Used when we're waiting for the user to connect.
#---
script_aborted=0

#---
## DESC: Trap for ctrl+c
#---
trap ctrl_c INT; ctrl_c() {
    script_aborted=1
}

#---
## DESC: Helper functions for formatting text
#---
ansi()      { printf "\e[%sm%s\e[0m" "$1" "$(echo "$@" | cut -d' ' -f2-)"; }
reset()     { ansi 0 "$@"; }
bold()      { ansi 1 "$@"; }
dim()       { ansi 2 "$@"; }
italic()    { ansi 3 "$@"; }
underline() { ansi 4 "$@"; }
red()       { ansi 31 "$@"; }
yel()       { ansi 33 "$@"; }
mag()       { ansi 35 "$@"; }
cyan()      { ansi 36 "$@"; }
green()     { ansi 92 "$@"; }

#---
## DESC: Broadcasts a message to the user on all ttys
## ARGS: $1 (required) Message
#---
broadcast () {
    find /dev/pts -mindepth 1 -maxdepth 1 -type c -user "$username" -print | while read -r tty; do
        echo "$@" | write "$username" "$tty"
    done
}

#---
## DESC: A simple helper function for printing formatted and more descriptive actions to tty.
## ARGS: $1 (required) Type of action (restarting, deleting, flipping etc)
##       $2 (required) Target of action
## EXAM:
##  try Restarting SSHD # Restarting SSHD:
##  catch 0 # OK
##  catch 1 # ?
#---
try () {
    printf "%s %s\e[91m " "$(yel "$1")" "$(italic "$2:")"
}; catch () {
    printf "%s" "$(reset "")"

    if re "$1" "^[0-9]+$" && [ "$1" -eq 0 ]; then
        printf "%s\n" "$(green OK)"
    elif [ -z "$1" ]; then
        printf "%s\n" "$(green OK)"
    else
        printf "%s\n" "$(red "${1:-"ERROR"}")"
    fi
}

#---
## DESC: Helper function for regex matching
## ARGS: $1 string to match against
##       $2 pattern
#---
re () {
    echo "$1" | grep -Eq "$2"
}

#---
## DESC: Disables .google_authenticator
## OUTS: 0 if we could disable the ga config (will return > 0 if it already is disabled)
#---
ga_path_disable () {
    local code=
    local ga_from="$ga_path"
    local ga_dest="${ga_path}_tmp_disabled"

    try "Suffixing " "$ga_from"
    mv "$ga_from" "$ga_dest"
    code=$?
    catch $code
    return $code
}

#---
## DESC: Restores .google_authenticator
## OUTS: 0 if we could restore the ga config (will return > 0 if it weren't disabled to begin with)
#---
ga_path_restore () {
    local code=
    local ga_from="${ga_path}_tmp_disabled"
    local ga_dest="$ga_path"

    try "Restoring " "$ga_from"
    mv "$ga_from" "$ga_dest"
    code=$?
    catch $code
    return $code
}

#---
## DESC: Writes the temporary sshd configuration
## OUTS: 0 if the file could be written
#---
sshd_conf_create () {
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


#---
## DESC: Restores the sshd configuration
## OUTS: 0 if we could restore the sshd config (will return > 0 if it weren't disabled to begin with)
#---
sshd_conf_restore () {
    local code=
    try "Restoring " "$sshd_conf_path"
    rm "$sshd_conf_path"
    code=$?
    catch $code
    return $code
}

#---
## DESC: Reloades the sshd configuration
## OUTS: 0 if the sshd service could successfully restarted.
#---
sshd_conf_reload () {
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

#---
## DESC: Check if 2fa has been disabled for current user
## OUTS: 1 if account is disabled
#---
is_disabled () {
    local ga_from="${ga_path}_tmp_disabled"

    # Check if any temporary files exists
    if [ ! -f "$sshd_conf_path" ] || [ ! -f "$ga_from" ]; then
        return 1
    fi
    
    return 0
}

#---
## DESC: Restores 2fa
## OUTS: 0 if everything went OK (could restore)
#---
restore_2fa () {
    echo ""
    printf "%s\n" "$(cyan Restoring 2fa for user "$username" ...)"

    if ! is_disabled; then 
        printf "%s 2FA hasn't been deactivated for this account.\n" "$(red Error: )"
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

    if [ ${hasErrors} -eq 1 ] || is_disabled; then
        broadcast \
            " WARNING: Something went wrong while restoring 2FA for your account.\n"\
            "Make sure you can still connect to the server before closing this connection."
    else 
        broadcast "Two-Factor Authentication (2FA) has been restored for your account."
    fi

    return $hasErrors
}

#---
## DESC: Disables 2fa
## OUTS: 0 if everything went OK (could disable)
#---
disable_2fa () {
    local at
    local job
    local job_id

    echo
    printf "%s\n" "$(cyan Disabling 2fa for user "$username" ...)"

    at=$(printf "./test --disable=%s" "$username" | at now + $at_countdown minutes 2>&1)
    job=$(echo "$at" | grep -E "^job ")
    job_id=$(echo "$job" | grep -Eo "^job [0-9]+" | cut -c 5-)

    try "Scheduling" "$job"

    if re "$job_id" "^[0-9]+$"; then
        catch 0
    else
        catch 1

        printf "\nCould not schedule the just-in-case restoration job. No changes has been made. \`at\` output:\n"
        printf "%s\n" "$at"
        exit 1
    fi

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
        try "Deschedule" "$job"
        at=$(at -r "$job_id" 2>&1)

        if [ -n "$at" ]; then
            catch "$at"
            
            printf "\n%s\n" "$(red Could not remove scheduled JIC-job.) We could however restore all changes so it shouldn't matter."
            printf "%s\n" "But the scheduled job is a lifeline that should work if something unexpected happens, e.g. a reboot during script execution."
        else
            catch 0
            
            printf "\n%s\n" "Script exited $(italic successfully)"
        fi

        
    else
        printf "\e[91mAn unhandled exception has occurred. Wait for the \e[0m\n"
    fi
}

#---
## DESC: Temporarily disables 2fa
## OUTS: 0 if everything went OK (could disable, could restore)
#---
start_countdown () {
    local file=/var/log/auth.log
    local pattern="^.*logind\[[0-9]+\]: New session [0-9]+ of user ${username}\.$"
    local line_count
    local time_stop
    local time_left
    local prefix="Waiting for $username to connect..."
    local grepRes

    line_count="$(wc -l $file | awk '{ print $1}')"

    time_stop=$(($(date +%s)+window))

    stty -echo # disable user input

    while true; do
        time_left=$((time_stop-$(date +%s)))
        
        printf "%s\033[K\033[0K\r" "$prefix $time_left"

        # Check for connection from user
        tail -n "+$line_count" "$file" | grep -qE "$pattern"
        grepRes=$?
        
        if [ $grepRes -eq 0 ]; then
            printf "%s \e[92muser %s connected 👍\033[K\e[0m\n" "$prefix" "$username"
            break
        fi

        if [ "$time_left" -lt 1 ]; then
            printf "%s \e[91mtime ran out\033[K\e[0m\n" "$prefix"
            break
        fi

        if [ "$script_aborted" -ne 0 ]; then
            printf "%s \e[91maborted\033[K\e[0m\n" "$prefix"
            break
        fi
        
        sleep 1
    done

    stty echo # enable user input
    
    restore_2fa
}

#---
## DESC: Prints --help
## ARGS: $1 (optional) Error message
#---
print_args_help () {
    if [ "$1" ]; then
        printf >&2 "\e[91mError:\033[K\e[0m\n"
        printf "  %s\n" "$*"
        echo ""
    fi

    cat >&2 <<EOF
Usage:
    $0 [-h] [-u <user> -a <ip>] [-r <user>] [-d]

Temporarily disables two-factor authenticator (2FA) for given account.

Options:
    -h, --help               Prints this message
    -d, --disable   <user>   Disables 2FA for given user
    -r, --restore   <user>   Enables (restores) 2FA for given user
    -a, --addr      <cidr>   CIDR address/masklen format
    -d, --dry                Prints the resolved arguments and exits script
    -ni, --no-interaction    Disables the warning prompt
    
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

#---
## DESC: Prints resolved script arguments
#---
print_args () {
    printf "username%s %s\n"       "$(dim .........)"     "$username"
    printf "ip_addr%s %s\n"        "$(dim ..........)"    "$ip_addr"
    printf "ga_path%s %s\n"        "$(dim ..........)"    "$ga_path"
    printf "sshd_conf_path%s %s\n" "$(dim ...)"           "$sshd_conf_path"
    printf "mode%s %s\n"           "$(dim .............)" "$mode"
}

#---
## DESC: Checks if given package is installed
## ARGS: $1 (required) package name
## OUTS: 0 if package is installed
#---
has_package () {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -cq "ok installed"
}

#---
## DESC: Assert that given package is installed. If not, exit script and display --help.
## ARGS: $1 (required) Package name
##       $2 (required) Link to manpage
#---
assert_package () {
    local package_name="$1"
    local package_link="$2"

    if ! has_package "$package_name"; then
        print_args_help "This script requires package '$package_name' to be installed ($package_link)"
    fi
}


#---
## DESC: 
##  Script entrypoint.
##  Parses the arguments, check requirements (running as root / env) and executes the currect subflow. 
## ARGS: $1 (required) Value
#---
main () {
    local mode=
    local continue=0

    local opt_user=
    local opt_addr=
    local opt_dry=0
    local opt_no_interaction=0

    if [ "$(id -u)" -ne 0 ]; then
        print_args_help "This script must be run as root"
    fi

    assert_package at https://manpages.debian.org/bookworm/at/at.1.en.html
    assert_package libpam-google-authenticator https://manpages.debian.org/bookworm/libpam-google-authenticator/pam_google_authenticator.8.en.html

    # Resolve arguments
    while test $# -gt 0; do
        case "$1" in
            '-h' | '--help')
                print_args_help
                ;;

            '-d' | '--disable' | '-r' | '--restore')
                if [ -n "$mode" ]; then
                    print_args_help "You have already opted for a mode."
                fi

                if re "$1" "^(-d|--di)+.*"; then
                    mode=disable
                else
                    mode=restore
                fi

                shift

                # handle optional value (i.e. ./1fa.sh -d -a 192.168.1.54)
                if [ $# -gt 0 ] && [ "$(printf '%c' "$1")" != '-' ]; then
                    opt_user=$1
                    shift
                fi
                ;;

            '-a' | '--addr')
                shift

                if [ -z "$1" ]; then
                    print_args_help "Address may not be empty"
                fi
                
                opt_addr="$1"

                shift
                ;;

            '-öö' | '--dry')
                opt_dry=1
                shift
                ;;

            '-ni' | '--no-interaction')
                opt_no_interaction=1
                shift
                ;;

            *)
                print_args_help "Unrecognized argument: $1"
        esac
    done

    # Use supplied args or fall back on defaults
    username="${opt_user:-$SUDO_USER}"
    ip_addr="${opt_addr:-$(echo "$SSH_CLIENT" | awk '{ print $1}')}"
    ga_path="/home/${username}/.google_authenticator"
    sshd_conf_path=/etc/ssh/sshd_config.d/tmp_disabled_2fa_for_${username}.conf

    # Check that we got a username and that the user exists
    if [ -z "${username}" ]; then
        print_args_help "Could not resolve username"
    else
        if ! id "$username" >/dev/null 2>&1; then
            print_args_help "User $username does not exist"
        fi
    fi

    # Check that we got an address
    if [ -z "${ip_addr}" ]; then
        print_args_help "Could not resolve ip address of this connection. Have you "
    fi

    # Check that we got an operation we understand
    if [ ! "$mode" = "restore" ] && [ ! "$mode" = "disable" ]; then
        print_args_help "Invalid mode \"$mode\". Mode can only be \"restore\" or \"enable\""
    fi
    
    if [ $opt_no_interaction -eq 1 ]; then
        continue=yes    
    else
        echo "$(red READ AND UNDERSTAND) "
        echo "This script temporarily disables 2FA authentication for the specified account by:"
        echo ""
        echo "1. Creating file: $(italic /etc/ssh/sshd_config.d/tmp_disabled_2fa_for_"$username".conf)"
        echo "      $(dim "$(italic Match User "$username" Address "$ip_addr")")"
        echo "         $(dim "$(italic  PasswordAuthentication yes)")"
        echo "         $(dim "$(italic  AuthenticationMethods password)")"
        echo "2. Renaming: $(italic /home/"$username"/.google_authenticator)"
        echo "   To:       $(italic /home/"$username"/.google_authenticator"$(yel _tmp_disabled)")"
        echo "3. Restarts service SSHD*"
        echo "4. Restores these changes after $(yel $window) seconds**"
        echo "5. Restarts service SSHD*"
        echo
        echo "* $(italic if the configuration passed validation \(sshd -t\)) "
        echo "** $(italic or immediately on successful connection from "$username", whatever comes first) "
        echo

        echo "$(cyan IT SHOULD:) "
        echo "1. Not effect other users"
        echo "2. Restore all changes if anything goes wrong"
        echo "3. Work :)"
        echo

        echo "$(cyan YOU SHOULD:) "
        echo "1. Not close this terminal before verifying that you can open a new connection"
        echo "2. Have a plan of what do in the unlikely event that you do get locked out from ssh:ing into this machine"
        echo "3. Have knowledge of how to manually fix things if anything in the description above did screw things up"
        echo
        echo "You can disable this warning by passing option $(italic --ni, -no-interaction)"
        echo

        printf "Do you understand and want to continue (y/yes)?: " >&2
        read -r continue
        echo
    fi;

    case $continue in
        y|Y|yes)
            echo "$(cyan Arguments:) "
            print_args
        
            if [ $opt_dry -eq 1 ]; then
                printf "\n--dry goodbye\n"
                exit 0
            fi

            if [ "$mode" = "restore" ]; then
                restore_2fa
            elif [ "$mode" = "disable" ]; then
                disable_2fa
            fi
        ;;
        
        *)
            echo 'Script exited'
        ;;
    esac
}

main "$@"


# last line
