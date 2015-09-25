---
layout: post
title: Docker环境配置实践
date: 2018-07-04 16:22
header-img: "img/head.jpg"
categories: 
  - docker
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}

## 安装docker

> centos7上安装docker

### 先决条件

```
OS: 
	centos 7
centos extras repo:
	yum repolist | grep extras
```

### 删除旧的

```bash
sudo yum remove docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-selinux \
                  docker-engine-selinux \
                  docker-engine
                  
cd /var/lib/docker/ && removeit
```

### 手动安装

```bash
wget https://download.docker.com/linux/centos/7/x86_64/stable/Packages/docker-ce-18.03.1.ce-1.el7.centos.x86_64.rpm

sudo yum install -y ftp://ftp.icm.edu.pl/vol/rzm3/linux-centos-vault/7.3.1611/extras/x86_64/Packages/container-selinux-2.9-4.el7.noarch.rpm

sudo yum install -y /home/liuyangming/docker-ce-18.03.1.ce-1.el7.centos.x86_64.rpm

sudo systemctl start docker
```

### test

```bash
sudo docker run hello-world
```

## 构建app——container

> docker构建的app，从上到下分为三层：
>
> - Stack
> - Services
> - Container

### dockerfile

dockerfile定义了container内部的环境，比如网络接口映射，将什么文件导入这个container中，等。

在一个空目录下，创建一个Dockerfile，定义了你的app的资源与环境。

```bash
$ cat Dockerfile
# Use an official Python runtime as a parent image
FROM python:2.7-slim

# Set the working directory to /app
WORKDIR /app

# Copy the current directory contents into the container at /app
ADD . /app

# Install any needed packages specified in requirements.txt
RUN pip install --trusted-host pypi.python.org -r requirements.txt

# Make port 80 available to the world outside this container
EXPOSE 80

# Define environment variable
ENV NAME World

# Run app.py when the container launches
CMD ["python", "app.py"]
$ pwd
/root/dockertest
```

### 编写app

在同一个目录下，创建app.py和requirements.txt文件，基于`ADD . /app`，这些文件会构建到container中，并会基于`EXPOSE 80`，暴露出80端口。

```python
# $ cat app.py
from flask import Flask
from redis import Redis, RedisError
import os
import socket

# Connect to Redis
redis = Redis(host="redis", db=0, socket_connect_timeout=2, socket_timeout=2)

app = Flask(__name__)

@app.route("/")
def hello():
    try:
        visits = redis.incr("counter")
    except RedisError:
        visits = "<i>cannot connect to Redis, counter disabled</i>"

    html = "<h3>Hello {name}!</h3>" \
           "<b>Hostname:</b> {hostname}<br/>" \
           "<b>Visits:</b> {visits}"
    return html.format(name=os.getenv("NAME", "world"), hostname=socket.gethostname(), visits=visits)

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=80)
```

```bash
$ cat requirements.txt
Flask
Redis
```

### 构建app

```bash
cd /root/dockertest/
docker build -t friendlyhello .
docker image ls
```

### 运行app

```bash
docker run -p 4000:80 friendlyhello
curl http://localhost:4000

# or run as daemon
$ docker run -d -p 4000:80 friendlyhello
28ab3a9aa5e5b9d1a12684c82034638beb67672698ff0165494895201eded9d2

# 注意相同的前缀
$ curl http://localhost:4000
<h3>Hello World!</h3><b>Hostname:</b> 28ab3a9aa5e5<br/><b>Visits:</b> <i>cannot connect to Redis, counter disabled</i>

$ docker container ls
CONTAINER ID        IMAGE               COMMAND             CREATED              STATUS              PORTS                  NAMES
28ab3a9aa5e5        friendlyhello       "python app.py"     About a minute ago   Up About a minute   0.0.0.0:4000->80/tcp   zealous_easley

docker container stop 28ab3a9aa5e5
```

### 共享app镜像

```
$ docker login
Login with your Docker ID to push and pull images from Docker Hub. If you don't have a Docker ID, head over to https://hub.docker.com to create one.
Username: layamon
Password:
Login Succeeded

docker tag friendlyhello layamon/get-started:part2

$ docker tag friendlyhello layamon/get-started:part2
$ docker image ls
REPOSITORY             TAG                 IMAGE ID            CREATED             SIZE
friendlyhello          latest              6cc659428c8e        15 minutes ago      132MB
layamon/get-started   part2               6cc659428c8e        15 minutes ago      132MB
...

docker push layamon/get-started:part2
```

然后可以在另一个机器上，直接拉取这个镜像，并运行

```bash
docker run -p 4000:80 layamon/get-started:part2
# docker run -p 4000:80 username/repository:tag
```

