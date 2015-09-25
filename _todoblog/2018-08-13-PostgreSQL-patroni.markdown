---
layout: post
title: Patroni部署
date: 2018-08-13 11:04
header-img: "img/head.jpg"
categories:
  - PostgreSQL
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
## 部署Patroni

### 机器与角色

| IP          | role    |
| ----------- | ------- |
| 10.189.6.28 | pgsql   |
| 10.189.3.46 | pgsql   |
| 10.189.1.45 | pgsql   |
| 10.189.0.40 | haproxy |
| 10.189.0.40 | etcd    |

### etcd

> 10.189.0.40

#### etcd安装

```bash
$ etcd --version
etcd Version: 3.3.0+git
Git SHA: 17de9bd
Go Version: go1.11.4
Go OS/Arch: linux/amd64
```

#### etcd配置

```yaml
# This is the configuration file for the etcd server.
# Human-readable name for this member.
name: 'patroni'
data-dir: /var/lib/etcd/data
wal-dir: /var/lib/etcd/wal

# Number of committed transactions to trigger a snapshot to disk.
snapshot-count: 10000
# Time (in milliseconds) of a heartbeat interval.
heartbeat-interval: 100
# Time (in milliseconds) for an election to timeout.
election-timeout: 1000
# Raise alarms when backend size exceeds the given quota. 0 means use the
# default quota.
quota-backend-bytes: 0
# Maximum number of snapshot files to retain (0 is unlimited).
max-snapshots: 5
# Maximum number of wal files to retain (0 is unlimited).
max-wals: 5

# List of comma separated URLs to listen on for peer traffic.
listen-peer-urls: http://10.189.0.40:7001
# List of comma separated URLs to listen on for client traffic.
listen-client-urls: http://localhost:4001,http://10.189.0.40:4001
# List of this member's peer URLs to advertise to the rest of the cluster.
# The URLs needed to be a comma-separated list.
initial-advertise-peer-urls: http://localhost:2380
# List of this member's client URLs to advertise to the public.
# The URLs needed to be a comma-separated list.
advertise-client-urls: http://10.189.0.40:4001

# Discovery URL used to bootstrap the cluster.
discovery:
# Valid values include 'exit', 'proxy'
discovery-fallback: 'proxy'
# Initial cluster token for the etcd cluster during bootstrap.
initial-cluster-token: 'etcd-cluster'
# Initial cluster state ('new' or 'existing').
initial-cluster-state: 'new'
```

#### 启动etcd

`etcd --config-file /etc/etcd/etcd.conf`

### haproxy

> 10.189.0.40

#### haproxy安装

haproxy主要是在master发生failover后，用来调整新的指向。

考虑到如果我们能够通过内部API来调整master.db.tt的指向，那么可能haproxy并不需要；这样在整个架构中也少了一个单独的ha节点。

```
yum install haproxy -y
```

#### haproxy配置

> /etc/haproxy/haproxy.cfg

```cfg
global
    maxconn 100

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen postgres
    bind *:5000
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server postgresql_10.189.6.28_5432 10.189.6.28:5432 maxconn 100 check port 8008
    server postgresql_10.189.3.46_5432 10.189.3.46:5432 maxconn 100 check port 8008
    server postgresql_10.189.1.45_5432 10.189.1.45:5432 maxconn 100 check port 8008
```

#### 启动haproxy

```
systemctl restart haproxy
```

### DB机器

#### 安装patroni

```bash
pip install patroni[etcd]
```

#### 配置patroni

> /etc/patroni.yml

##### 节点1

```yaml
scope: postgres-ha
namespace: /db/
name: hatestdb-pg10-node1

restapi:
    listen: 0.0.0.0:8008
    connect_address: 10.189.6.28:8008

etcd:
    host: 10.189.0.40:4001

bootstrap:
    dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
            use_pg_rewind: true
            use_slots: true
            parameters:
                wal_level: logical
                hot_standby: "on"
                wal_keep_segments: 8
                max_wal_senders: 5
                max_replication_slots: 5
                checkpoint_timeout: 30

    initdb:
    - encoding: UTF8
    - data-checksums

    pg_hba:
    - host all dba all md5
    - host replication replication all md5

    users:
        dba:
            password: dba
            options:
                - createrole
                - createdb
        replication:
            password: replication
            options:
                - replication

postgresql:
    listen: 0.0.0.0:5432
    connect_address: 10.189.6.28:5432
    data_dir: /export/postgresql/hatest_10/data
    authentication:
        replication:
            username: replication
            password: replication
        superuser:
            username: dba
            password: dba
    parameters:
        unix_socket_directories: '/var/run/postgresql, /tmp'
```

##### 节点2

```yaml
scope: postgres-ha
namespace: /db/
name: hatestdb-pg10-node2

restapi:
    listen: 0.0.0.0:8008
    connect_address: 10.189.3.46:8008

etcd:
    host: 10.189.0.40:4001

bootstrap:
    dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
            use_pg_rewind: true
            use_slots: true
            parameters:
                wal_level: logical
                hot_standby: "on"
                wal_keep_segments: 8
                max_wal_senders: 5
                max_replication_slots: 5
                checkpoint_timeout: 30

    initdb:
    - encoding: UTF8
    - data-checksums

    pg_hba:
    - host all dba all md5
    - host replication replication all md5

    users:
        dba:
            password: dba
            options:
                - createrole
                - createdb
        replication:
            password: replication
            options:
                - replication

postgresql:
    listen: 0.0.0.0:5432
    connect_address: 10.189.3.46:5432
    data_dir: /export/postgresql/hatest_10/data
    authentication:
        replication:
            username: replication
            password: replication
        superuser:
            username: dba
            password: dba
    parameters:
        unix_socket_directories: '/var/run/postgresql, /tmp'
```

##### 节点3

```yaml
scope: postgres-ha
namespace: /db/
name: hatestdb-pg10-node3

restapi:
    listen: 0.0.0.0:8008
    connect_address: 10.189.1.45:8008

etcd:
    host: 10.189.0.40:4001

bootstrap:
    dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
            use_pg_rewind: true
            use_slots: true
            parameters:
                wal_level: logical
                hot_standby: "on"
                wal_keep_segments: 8
                max_wal_senders: 5
                max_replication_slots: 5
                checkpoint_timeout: 30

    initdb:
    - encoding: UTF8
    - data-checksums

    pg_hba:
    - host all dba all md5
    - host replication replication all md5

    users:
        dba:
            password: dba
            options:
                - createrole
                - createdb
        replication:
            password: replication
            options:
                - replication

postgresql:
    listen: 0.0.0.0:5432
    connect_address: 10.189.1.45:5432
    data_dir: /export/postgresql/hatest_10/data
    authentication:
        replication:
            username: replication
            password: replication
        superuser:
            username: dba
            password: dba
    parameters:
        unix_socket_directories: '/var/run/postgresql, /tmp'
```

### 启动PostgreSQL-HA 集群

在三个几点上启动patroni

```
/usr/local/bin/patroni /etc/patroni.yml
```

#### etcd member

```bash
]$ etcdctl --endpoints=10.189.0.40:4001 member list
8e9e05c52164694d, started, patroni, http://localhost:2380, http://10.189.0.40:4001
```

#### PostgreSQL master HA

![image-20190304130010393](/../dba/team/yangming/image/image-20190304130010393.png)

## 部署问题

- etcd版本；yum默认是2.0；这里是编译安装的最新的3；由于测试ha，这里etcd是单节点。

- patroni重启整个集群，注意在etcd中删除相关的资源；

  ```bash
  patronictl remove postgres-ha
  ```

- `Error: 'Can not find suitable configuration of distributed configuration store`



### 参考文献

https://www.pgcon.org/2013/schedule/attachments/279_PostgreSQL_9_and_Linux_HA.pdf





