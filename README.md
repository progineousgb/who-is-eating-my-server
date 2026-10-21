# who-is-eating-my-server

```sh
curl -fsSL https://raw.githubusercontent.com/progineousgb/who-is-eating-my-server/main/who-is-eating-my-server.sh | sudo bash
```

The server is slow and you want to know why, now. This takes a 2 second sample and tells you in plain words what is using the CPU, RAM, disk I/O, disk space and network, with the top offenders by process name and, where it can tell, the systemd service or Docker container they belong to. Read-only.

## Example output

Real run on a test VM while a `dd` was writing a 4 GB file in the background.

```
$ sudo ./who-is-eating-my-server.sh

who-is-eating-my-server 1.0.0  web-01, 8 CPU, up 55 minutes

== CPU ==
  Overall the CPU is 19% busy over the last 2s. Load average 2.32 / 3.05 / 1.83 on 8 CPU(s).
  Per process, 100% means one full CPU core.
   101.7%  dd (pid 59616)
     4.0%  node (pid 5000)
     2.5%  nginx (pid 1123)
     2.5%  php-fpm8.2 (pid 1410)
     1.5%  mariadbd (pid 905)

== Memory ==
  23% of RAM in use: 3.7 GB of 16 GB, 12 GB still available (cache counts as available).
  No swap configured.
     783 MB  node (pid 9781)
     383 MB  mariadbd (pid 905)
     380 MB  node (pid 5000)
     163 MB  php-fpm8.2 (pid 1410)
     127 MB  php-fpm8.2 (pid 1411)

== Disk I/O ==
  read    0.0 KB/s  write    1.2 GB/s  dd (pid 59616)
  read    107 MB/s  write    0.0 KB/s  mariadbd (pid 905)
  read    0.0 KB/s  write     33 KB/s  nginx (pid 1123)
  read    0.0 KB/s  write    1.0 KB/s  systemd-journal (pid 312)
  read    0.0 KB/s  write    1.0 KB/s  rsyslogd (pid 640)
  Processes were stalled waiting on I/O 0.18% of the time (last 10s).

== Disk space ==
  /                         50% used, 65 GB free of 127 GB (/dev/vdb)

  Largest directories under / (same filesystem, 3 levels deep):
      42 GB  /var
      18 GB  /var/lib/mysql
      11 GB  /home
      11 GB  /home/deploy
     5.9 GB  /var/www

== Network ==
  enp0s3       in    2.0 KB/s   out    2.0 KB/s
  33 established TCP connections.
  Processes with the most connections:
       8 conn  node (pid 5000)
       4 conn  nginx (pid 1123)
       4 conn  mariadbd (pid 905)
       3 conn  nginx (pid 1124)
       2 conn  sshd (pid 2210)
  Remote addresses with the most connections:
      18 conn  127.0.0.1
       8 conn  192.0.2.10
       3 conn  192.0.2.45
       2 conn  ::ffff:127.0.0.1
       1 conn  192.0.2.78

== In short ==
  CPU is 19% busy; the biggest user is dd (pid 59616) at 101.7% of one CPU.
  RAM is 23% used; the biggest user is node (pid 9781) with 783 MB.
  The root disk is 50% full.
  Nothing looks overloaded right now.

Sampled over 2s. Nothing was changed.
```

## What it looks at

- **CPU**: overall busy percentage over the sample, load average against CPU count, top processes by CPU in that window (from `/proc/<pid>/stat`, so it is a real delta, not the lifetime average `ps` shows).
- **Memory**: used and available RAM (cache counted as available), swap, top processes by RSS, and whether the kernel log shows the OOM killer has fired.
- **Disk I/O**: top processes by bytes read and written during the sample (`/proc/<pid>/io`), plus I/O pressure from `/proc/pressure/io` when the kernel has PSI.
- **Disk space**: usage per real filesystem, the largest directories under `/` (3 levels, one filesystem, capped at 60 seconds), and the size of the systemd journal.
- **Network**: traffic per interface during the sample, established TCP connections, which processes hold the most, and which remote addresses.
- **Owner**: each process is mapped through `/proc/<pid>/cgroup` to a `.service`, a Docker or Podman container, or a login session.

## Options

```
-n, --top N        offenders per section (default 5)
-s, --sample SEC   sampling window (default 2)
-p, --path DIR     where to look for large directories (default /)
--no-du            skip the directory scan
--no-color
-h, --help
-V, --version
```

## Limits

- It is a snapshot. A spike that ended a minute ago will not show up. For history use sysstat, netdata or similar.
- Without root, I/O and connection details only cover your own processes.
- Per-process network bandwidth is not measured, only connection counts. Bash alone cannot get it without tools like nethogs.
- Container names need the docker CLI on the same host. Otherwise the short container ID is shown.
- The `du` scan can be slow on large disks. Use `--no-du` or `--path`.

## Maintained by

Maintained by Pro Gineous, a domains, hosting and VPS provider: https://progineous.com

Issues and pull requests are welcome.

## License

MIT, see [LICENSE](LICENSE).
