# 1fa.sh
Temporarily disables SSH two-factor authentication (2FA) for given account.

**Work in progress**

## Installation
```bash
curl https://raw.githubusercontent.com/unkelpehr/1fa.sh/refs/heads/main/1fa.sh -o 1fa.sh
chmod u+x 1fa.sh
```

## Usage

```bash
# Allow 1FA for current user inbound from current SSH client address.
# Environmental variables must be preserved (-E) for the script to grab the address.
sudo -E ./1fa.sh

# Allow 1FA for current user inbound from specific subnet
sudo ./1fa.sh -a 10.1.2.0/24

# Allow 1FA for user bobby inbound from specific subnet
sudo ./1fa.sh -bobby -a 10.1.2.0/24
```

## Example output
```
bobby@secureserver:~$ sudo -E ./1fa.sh -d

$${\color{red}READ AND UNDERSTAND}$$	
This script temporarily disables 2FA authentication for the specified account by:

1. Creating file: /etc/ssh/sshd_config.d/tmp_disabled_2fa_for_bobby.conf
      Match User bobby Address 10.1.3.143
         PasswordAuthentication yes
         AuthenticationMethods password
2. Renaming: /home/bobby/.google_authenticator
   To:       /home/bobby/.google_authenticator_tmp_disabled
3. Restarts service SSHD*
4. Restores these changes after 30 seconds**
5. Restarts service SSHD*

* if the configuration passed validation (sshd -t)
** or immediately on successful connection from bobby, whatever comes first

IT SHOULD:
1. Not effect other users
2. Restore all changes if anything goes wrong
3. Work :)

YOU SHOULD:
1. Not close this terminal before verifying that you can open a new connection
2. Have a plan of what do in the unlikely event that you do get locked out from ssh:ing into this machine
3. Have knowledge of how to manually fix things if anything in the description above did screw things up

You can disable this warning by passing option --ni, -no-interaction

Do you understand and want to continue (y/yes)?: yes

Arguments:
username......... bobby
ip_addr.......... 10.1.3.143
ga_path.......... /home/bobby/.google_authenticator
sshd_conf_path... /etc/ssh/sshd_config.d/tmp_disabled_2fa_for_bobby.conf
mode............. disable

Disabling 2fa for user bobby ...
Scheduling job 411 at Thu Apr  3 10:22:00 2025: OK
Suffixing  /home/bobby/.google_authenticator: OK
Creating   /etc/ssh/sshd_config.d/tmp_disabled_2fa_for_bobby.conf: OK
Validating /etc/ssh/sshd_config: OK
Restarting sshd: OK

Message from bobby@secureserver (as root) on pts/5 at 10:20 ...
Two-Factor Authentication (2FA) has been temporarily disabled for your account.
EOF
Waiting for bobby to connect... time ran out

Restoring 2fa for user bobby ...
Restoring  /home/bobby/.google_authenticator_tmp_disabled: OK
Restoring  /etc/ssh/sshd_config.d/tmp_disabled_2fa_for_bobby.conf: OK
Validating /etc/ssh/sshd_config: OK
Restarting sshd: OK

Message from bobby@secureserver (as root) on pts/5 at 10:20 ...
Two-Factor Authentication (2FA) has been restored for your account.
EOF
Deschedule job 411 at Thu Apr  3 10:22:00 2025: OK

Script exited successfully
bobby@secureserver:~$
```

## ToDo
* Automated tests
* Allow run --help as root
