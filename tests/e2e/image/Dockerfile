# Test-only image: Rocky Linux 9 with systemd as PID 1, sshd, sudo, cron, python3.
# Stands in for a RHEL 9 VM in the end-to-end test (tests/e2e/run.sh).
FROM rockylinux/rockylinux:9
RUN dnf -y install systemd systemd-sysv openssh-server openssh-clients sudo cronie \
        python3 iproute procps-ng hostname glibc-langpack-en which tar gzip findutils \
    && dnf clean all \
    && systemctl enable sshd crond \
    && systemctl mask systemd-logind.service getty.target console-getty.service \
    && rm -f /etc/machine-id && touch /etc/machine-id \
    && printf 'Defaults !pam_acct_mgmt\n' > /etc/sudoers.d/00-e2e && chmod 0440 /etc/sudoers.d/00-e2e \
    && sed -i '0,/^account/s//account    sufficient   pam_permit.so\naccount/' /etc/pam.d/sshd
# ^ Docker Desktop's AppArmor blocks unix_chkpwd (PAM account check) inside the container,
#   which breaks sudo and sshd logins; test image only.
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
