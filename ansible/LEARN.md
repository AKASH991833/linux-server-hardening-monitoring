# Ansible from zero

Ansible reads an inventory (which hosts) and a playbook (which tasks). A role groups reusable tasks. Run from your laptop/control node with ansible-core installed; managed hosts need Python 3 and Bash.

1. Copy inventory.example.ini, add only servers you own, keep console access.
2. Run `ansible-playbook -i inventory.ini site.yml --list-hosts`.
3. Run without hk_apply first: it installs the tool and prints an audit, but does not harden.
4. Review hk_fix_ids. Then use `-e hk_apply=true`. Serial 2 limits simultaneous hosts.
5. Run again. Idempotent means changed=0 on the second run, not "it happened to exit zero".

The default subset avoids password-login disable and firewall changes. This is a selected hardening role, not a full CIS role. SSH Match/Include policy still needs human review. Normal mode is the supported preview; Ansible --check cannot audit files on a first-ever install. Do not run first-install --check as proof of a safe apply.

`PATH=$HOME/.local/bin:$PATH ./ansible/test.sh` applies to an isolated fixture rootfs and checks a second converge. CI also runs a live Ubuntu VM role test. Container tests do not prove systemd restart behavior. Transactions are kept in hk_state_dir: `HK_STATE=/var/lib/hk /opt/hk/hk tx list`, then `sudo HK_STATE=/var/lib/hk /opt/hk/hk rollback ID`. Rollback is an explicit operator decision, never automatic fleet-wide.

Exercise: add a second lab host; change a selected fixture setting; explain why only one host reports changed. Do not use production first.
