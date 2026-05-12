# NFS Server Setup for Docker Registry Storage

## Overview

| Item | Details |
|------|---------|
| **NFS Server** | `192.168.18.52` (INBACRNRDL0101) |
| **NFS Client** | `192.168.18.53` (INBACRNRDL0102) |
| **Server OS** | Rocky Linux 9.7 (Blue Onyx) |
| **Client OS** | Rocky Linux 9.6 (Blue Onyx) |
| **Backing Storage** | LVM volume `rl_inbacrnrdl0101-home` (818.6G) mounted at `/home` |
| **Export Path** | `/home/nfs-registry` |
| **Client Mount Point** | `/mnt/nfs-registry` |
| **Purpose** | Persistent storage for Docker registry data |

---

## Step-by-Step Procedure

### Part 1 — NFS Server Setup (192.168.18.52)

#### Step 1: Connect to the NFS Server

```bash
ssh root@192.168.18.52
```

#### Step 2: Verify Prerequisites

`nfs-utils` and `rpcbind` are required. On Rocky Linux 9.x they are typically pre-installed.

```bash
rpm -q nfs-utils rpcbind
```

If not installed:

```bash
dnf install -y nfs-utils rpcbind
```

#### Step 3: Verify the Backing Filesystem

Confirm the `/home` LVM volume has sufficient space:

```bash
df -h /home
lsblk /dev/mapper/rl_inbacrnrdl0101-home
```

Expected output shows ~819G total with ~813G available.

#### Step 4: Create the NFS Export Directory

```bash
mkdir -p /home/nfs-registry
chmod 755 /home/nfs-registry
```

#### Step 5: Configure SELinux for NFS Export

Since SELinux is in `Enforcing` mode, the export directory must be labeled correctly:

```bash
setsebool -P nfs_export_all_rw 1
setsebool -P nfs_export_all_ro 1
semanage fcontext -a -t nfs_t '/home/nfs-registry(/.*)?'
restorecon -Rv /home/nfs-registry
```

Verify the label:

```bash
ls -Zd /home/nfs-registry
# Expected: unconfined_u:object_r:nfs_t:s0 /home/nfs-registry
```

#### Step 6: Configure `/etc/exports`

Restrict access to only `192.168.18.53`:

```bash
echo '/home/nfs-registry 192.168.18.53(rw,sync,no_subtree_check,no_root_squash)' > /etc/exports
```

Export options explained:

| Option | Purpose |
|--------|---------|
| `rw` | Read-write access |
| `sync` | Write data to disk before replying (data safety) |
| `no_subtree_check` | Disables subtree checking for reliability |
| `no_root_squash` | Allows root on the client to have root privileges on the share (needed for Docker registry) |

#### Step 7: Enable and Start NFS Services

```bash
systemctl enable --now rpcbind nfs-server
exportfs -arv
```

Verify the export is active:

```bash
exportfs -v
```

Expected output:

```
/home/nfs-registry
        192.168.18.53(sync,wdelay,hide,no_subtree_check,sec=sys,rw,secure,no_root_squash,no_all_squash)
```

#### Step 8: Configure Firewall

Open the required NFS services through `firewalld`:

```bash
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload
```

Verify:

```bash
firewall-cmd --list-services
# Should include: mountd nfs rpc-bind
```

---

### Part 2 — NFS Client Setup (192.168.18.53)

#### Step 9: Connect to the NFS Client

```bash
ssh root@192.168.18.53
```

#### Step 10: Verify NFS Utilities Are Installed

```bash
rpm -q nfs-utils
```

If not installed:

```bash
dnf install -y nfs-utils
```

#### Step 11: Verify the NFS Export Is Visible

```bash
showmount -e 192.168.18.52
```

Expected output:

```
Export list for 192.168.18.52:
/home/nfs-registry 192.168.18.53
```

#### Step 12: Create Mount Point and Mount the Share

```bash
mkdir -p /mnt/nfs-registry
mount -t nfs 192.168.18.52:/home/nfs-registry /mnt/nfs-registry
```

Verify:

```bash
df -h /mnt/nfs-registry
```

Expected output:

```
Filesystem                        Size  Used Avail Use% Mounted on
192.168.18.52:/home/nfs-registry  819G  5.8G  813G   1% /mnt/nfs-registry
```

#### Step 13: Add Persistent Mount Entry in `/etc/fstab`

```bash
echo '192.168.18.52:/home/nfs-registry /mnt/nfs-registry nfs defaults,_netdev 0 0' >> /etc/fstab
```

The `_netdev` option ensures the mount waits for network availability during boot.

#### Step 14: Test Read/Write Access

```bash
echo 'nfs-test-write' > /mnt/nfs-registry/test.txt
cat /mnt/nfs-registry/test.txt
rm -f /mnt/nfs-registry/test.txt
```

#### Step 15: Create Docker Registry Data Directory

```bash
mkdir -p /mnt/nfs-registry/docker-registry
```

---

### Part 3 — Using the NFS Share with a Docker Registry

To run a Docker registry that stores images on the NFS mount, use the following on `192.168.18.53`:

```bash
docker run -d \
  --name registry \
  --restart=always \
  -p 5000:5000 \
  -v /mnt/nfs-registry/docker-registry:/var/lib/registry \
  registry:2
```

This maps the NFS-backed directory as the registry's storage backend.

---

## Verification Summary

| Check | Command | Expected Result |
|-------|---------|-----------------|
| NFS server running | `systemctl is-active nfs-server` (on .52) | `active` |
| Export configured | `exportfs -v` (on .52) | Shows `/home/nfs-registry` for `192.168.18.53` |
| Firewall open | `firewall-cmd --list-services` (on .52) | Includes `nfs`, `rpc-bind`, `mountd` |
| Mount active | `df -h /mnt/nfs-registry` (on .53) | Shows NFS mount with ~819G |
| Persistent mount | `grep nfs-registry /etc/fstab` (on .53) | Entry present |
| Read/write works | Write and read test file (on .53) | Success |

---

## Troubleshooting

- **Mount hangs**: Check firewall on server (`firewall-cmd --list-services`) and network connectivity (`ping 192.168.18.52`).
- **Permission denied**: Verify SELinux labels (`ls -Zd /home/nfs-registry`) and export options in `/etc/exports`.
- **Mount not surviving reboot**: Verify `/etc/fstab` entry on client includes `_netdev` option.
- **showmount fails**: Ensure `rpcbind` and `nfs-server` are running on the server.

---

*Procedure executed on: February 27, 2026*
