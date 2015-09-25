---
layout: post
title: 分布式杂谈
date: 2018-11-06 11:25
header-img: "img/head.jpg"
categories: 
  - DBMS
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
计算机系统的运行时由位于相同或不同空间上的进程集合构成，进程之间通过收发信息来通信。如果一个系统中**消息传递延迟相对于事件间隔不可忽略，**就可称之为**分布式系统**——《Time, Clocks, and the Ordering of Events in a Distributed System》。

当单机系统的发展遭遇摩尔定律的限制时，将数据（磁盘或者内存）或计算任务（CPU）进行拆分就是**分布式存储**或**分布式计算**系统。对于无状态的任务，可以简单的将单机并行，变成多机并行；但是如果将数据进行了拆分，那么就需要考虑数据的可用性、容错性和一致性。本文针对数据的分布式存储场景，梳理一下当前自己所了解的大概，如下是简单梳理了一个的脑图。

![image-20191221122232898](/image/dist-db/1217-distribute-data.png)

如果将分布式的逻辑下方到存储层，常常会遇到分布式环境下四个问题：消息丢失，连接失败，整站挂掉和网络分割。

在设计系统时，个人认为需要考虑三个方面：

1. Data Partition：数据的切分方式；可以垂直切分（vertical），比如将一个宽表的部分列，拆分为子表；也可以水平切分（horizontal），将较大的业务表按照一个或多个`distributed_id`进行分割。这样需要在业务代码中对数据进行路由。
2. Data Replica：为了保证数据的可用性，并提高读写并发度；通常会做多个数据副本，那么这些副本上的数据，需要保证数据一致，则需要考虑复制协议（Replica Control），可分为以下几种：
   + Primary Copy Replica Control，这是最常见的一种，即，**一主多从**的方式；可以进行读写分离，但是只有一个节点可写。
   + Read One/Write All Replica Control，在这种方式中，业务可以从最优的一个节点读取，但是写入的时候，需要在所有节点写入；这适合**读远大于写**的场景。
   + Quorum Consensus Replica Control，读写通过**多数派决策**，保证数据的一致性；
   + Group Replication，组复制，每个节点都可以写，但是需要处理**数据冲突**的情况。
+ Consensus algorithm，在修改时，就在replica cluster中**达成一致**。
  
3. Transaction ACID，分布式环境中修改多个节点上的数据时，为了保证整体数据的正确性，可引入分布式事务；那么，在分布式环境下，同样需要满足事务的ACID四个特性。

   + Atomic：通过**两阶段提交**，保证在所有节点上要么全成功，要么全失败。

   + Consistency：**数据一致性协议**确保了数据副本在每个操作的全局一致性；从而确保整体上的所有操作的一致性。

   + Isolation：单机环境下可以通过锁或者多版本的方式对事务进行隔离；同样的，分布式环境中也可以采用这两种思路。那么就需要考虑全局**分布式事务锁**的管理和生成**全局单调递增的数据版本号**的两个问题。

     注意，这里的锁主要是指可见的事务锁；另外还有和单机中的latch(rwlock/mutex)概念类似的**分布式读写锁**。

     > 全局隔离级别不等于所有节点的本地隔离级别；但是，有如下理论：
     >
     >  Theorem: If all sites use a strict two-phase locking protocol and the transaction manager uses a two-phase commit protocol, transactions are globally serializable in commit order.

+ Durability：和单机环境类似，保证事务持久性，可通过全局Write-Ahead-Log日志解决。

基于以上概述，在分布式带来了弹性，也带来了很多新的问题；比较关键的有几点：

1. 解决时序问题的分布式时钟；
2. 解决数据互斥访问的分布式锁
3. 解决操作（日志记录）一致性问题的共识算法
4. 解决整体数据正确性问题的分布式事务。

下面，本文针对对这几个方面做一个笼统的介绍，希望对刚开始了解分布式环境的同学有所帮助。

# 分布式时钟

无法确定分布式环境中的不同服务的事件先后顺序，是造成分布式环境问题的根源所在。那么，首先需要能够确定事务的先后顺序（transaction ordering），常用的解决方式就是加一个时间戳。

在单机中，可直接以本机时间作为标识，而分布式环境中，可以将时间戳做成一个服务，其他节点来这个节点进行请求（TiDB）；

另外，通过消息传递进行时钟同步，产生一个全局的逻辑时间戳。在《Time, Clocks, and the Ordering of Events in a Distributed System》论文中，详细阐述了通过节点间的消息传递，实现逻辑时钟的实现协议，这里暂不做详细阐述。有兴趣可以参阅一下这个论文，实现的方式是通过定义了节点间时间同步的一个协议，生成逻辑时间，获得了事件的一个全序关系。这分布式逻辑时间可作为数据版本号来使用；可以参考CockroachDB。

另外，还可以使用满足一定条件的物理时钟，目前采用这种方式的只是Google Spanner。

# 分布式锁

第二个问题就是分布式环境中，各个服务之间的操作同步；单机中可以通过**mutex**或**semaphore**进行同步，类似的在分布式环境中也有类似概念，但是复杂点，这里为了和事务锁进行区分，称其distributed rwlock。实现方式分为乐观锁和悲观锁两种，如下图：

![image-20191220160125996](/image/dist-db/1217-dist-lock.png)

这里主要讨论悲观锁。由于锁超时的机制存在（且必须存在锁超时的机制，否则一个挂掉的owner会一直不释放锁），我们不能保证持有锁并执行自己任务所花的时间一定小于锁超时的时间，那么有可能在owner不知情的情况下，lockmanager将锁释放的情况；这样就会产生异常，比如lost update。因此，不能对执行时间有任何假设，从而expiration time就很难确定。

![Unsafe access to a resource protected by a distributed lock](/image/dist-db/1217-unsafe-lock.png)

解决这个问题一个很巧妙的方式就是lock manager在每次分配锁时，会分配一个**单调递增**的fence token，这样存储层会判断fence token的大小，拒绝小于存储记录的fence token的更新请求。

![Using fencing tokens to make resource access safe](/image/dist-db/1217-fencing-tokens.png)

这样，就解决了expiration time带来的问题，但是如何生成全局递增的fence token呢？感觉很简单哈？

![image-20191220152131591](/image/dist-db/1217-incre-counter.png)

简单的方式就是直接利用一个单点数据库来生成，可以给这个单点加一个standby保证可用性，但是需要在两者的强一致和性能之前权衡；然后也可以使用前一节的分布式逻辑时间戳（可见在分布式环境下这个全局递增的时间戳太有用了）。

另外的方案就是基于下一节提到的共识（consensus）算法来解决这个问题。

## 分布式一致性

在各个节点的数据的一致性，通过consensus算法保证，常用的有raft，paxos。raft的详细介绍，参见本站的另一篇blog。这里简单介绍一下CAP理论。

### CAP theorem

单机数据库通过本地事务来保证数据一致性。分布式系统的一致性是保证整个系统的各处的状态是相同的。对于无状态的分布式系统，系统间的协调几乎没有必要了；但是对于像数据库这种有状态的，为了对外表现的是一个整体，就需要在C/A/P之间权衡了（Principles of Distributed Computing ——Eric Brewer）。

+ （强）*Consensus(mutual consistency)*：确保客户端链接上每个分布式节点node，都是看到**相同的且最新的**数据；并且能够成功的写入。这种一致性是一种强的序列化的一致性，可按照一致性的强弱分为三个级别：
  + – Strong:对于提交的数据， 所有副本总是有相同的值。
  + – Weak: 所有副本最终会达到一致，但是当前不一定一致。
  + – Quorum: 对于提交的数据， 大多数的副本是有相同的值。
+ （高）*Availability*：**每个**有效节点都能在**合理的时间**内响应读写请求；
+ *Partition Tolerant*：由于网络隔离或机器故障，将系统分割后，系统能够继续保持服务并且保持一致性；当分割恢复后，能够优雅的恢复回来。

> 这里的**CA**和ACID中的**CA**是两码事。A就不用说了，一个是可用性，一个是原子性。
>
> ACID中的C是Consistency，强调的是连贯性，前后一致。
>
> CAP中的C是Consensus，强調的是共识，各个节点之间是否达成一致意见。

由于CAP三者不能同时满足，从而有状态的分布式系统就分为了三种类型：

+ CP：当系统出现网络分区时，这时牺牲了可用性，保障整体一致性和分区容忍性。
+ AP：当系统出现网络分区时，这时牺牲了一致性，保证性能可用性和分区容忍性。
+ CA：如果单机的DB算一个分布式系统，那么就算一个CA的系统。但是，网络分布式系统中，由于node之间是通过网络进行通信的，网络分割是常有的事。分布式系统中一定要处理P这个问题，因此很少有分布式的CA系统。

所以，分布式系统一般就是在考虑在产生网络分区时，我们应该优先保证**强一致性**还是**完美的可用性**。尽管不能两全，但是我们尽量两方面都做到尽量好。

对于AP系统，比如一些NoSQL的分布式存储系统，这种系统可以通过raft等一致性协议对多个读写操作的顺序进行协调，保证每个节点上的数据操作顺序是相同的，那么就能做到**最终一致性**。而对于CP系统，比如一些NewSQL的分布式数据库，更加关注的是一致性，通常也会引入**分布式事务**确保数据的正确性。

### 一致性模型

> 1. More formally, we say that a consistency model is the **set of all allowed histories of operations**.
> 2.  operations **take time**，what time should we use? invocation time? completion time? 
> 3. operation take effect **atomically** at some point between is invocation and completion.

- Linearizability：线性一致性，operations一个个的原子的变更状态。

- Sequential consistency：顺序一致性，比Linearizabililty放松要求，同一个Process的operations保持顺序，但是不同Process的operations的顺序就是undefined；比如，一个Process发起若干个请求，这些请求都在queue中排队，等其他Process消费，这样同一个Process中的由queue保持顺序。

- Causal consistency：因果一致性，人为定义某个operations的dependences，只有等Dependences都执行完，才能执行当前这个operation。

- Serializable consistency：可串行化一致性，看起来需要保证可串行化，应该是一个很强的一致性约束；而可串行化并没有因果依赖的要求，可能打乱同一个Process的operations，在实际很难应用；

  >  Most databases which claim to provide serializability actually provide *strong serializability*, which has the same time bounds as linearizability. To complicate matters further, what most SQL databases term the SERIALIZABLE consistency level [actually means something weaker](http://www.bailis.org/papers/hat-hotos2013.pdf), like repeatable read, cursor stability, or snapshot isolation.

  。。。 。。。

<img src="/image/dist-db/1217-consistency-family-tree.png" alt="family-tree.jpg" style="zoom:50%;" />

# 分布式事务

对于本地事务来说，逻辑上是一个整体的一系列读写操作。 事务比较细致地可以区分为五种状态：

- active：正在执行某条语句
- partially commited：上一条语句执行成功
- commited：事务成功了
- failed：某条语句失败了
- aborted：事务失败了

那么，一个分布式事务可以看做是多个本地事务的按照某个协议的协同操作；同样，也存在如上几种状态，也要满足ACID特性；讨论的比较多的是，如何保证在多个节点之间操作的原子性。

## 原子提交协议

关于原子提交协议我们听得最多的就是2PC，PostgreSQL和MySQL的多机事务是采用两阶段提交的方式实现的，这种两阶段提交时阻塞的；OceanBase基于Paxos分布式一致性协议实现的无阻塞的两阶段提交，等等。这里就主要说一下这个原子性。

### 2PC

保证分布式事务的原子性，通常采用2PC协议。MySQL中也叫XA协议，这是X/Open提出的通用的分布式事务处理协议。

在2PC中一般有两个角色，一个全局协调者的TM(Transaction Manager)与多个本地存储服务的RM(ResourceManager)。2PC的两个阶段如下：

![image-20191221130609598](/image/dist-db/1217-2pc.png)

理想情况是：在voting阶段，如果RM节点返回了Yes；那么提交成功。否则，全部回滚。

如果某个RM节点在返回Yes之前挂了，那么TM可以感知到从而进行Rollback。如果在返回Yes之后挂了，那么此时这个全局事务同样标记为Commit；**当挂掉的RM节点重启恢复的时候，本地发现还有未提交的Prepared的全局事务，此时会重新查询TM中全局事务的状态，来决定对其进行Commit还是Rollback。**

> 在PostgreSQL和MySQL中都支持了XA协议的prepare等操作，需要注意在MySQL5.7之前的版本中，prepare操作不写binlog，因此如果MySQL5.6作为RM节点，宕机恢复时会有问题。
>
> 在MySQL内部的SQL层与存储层同样也是采用2PC的方式进行事务提交。

### 3PC

2PC的RM在返回Yes之后，处于阻塞的状态；如果此时TM挂了，那么系统就阻塞住了；Skeen和Stonebreaker 在1981年，提出了3PC的解决方案。相比于2PC，3PC是非阻塞的分布式事务原子提交协议，其将commit阶段分为两步，并引入了RM的超时处理，如下图（from Wikipedia）：

![image-20191224214606499](/image/dist-db/1217-3pc.png)

相比于2PC，3PC的节点可以对事务进行超时处理，避免了系统阻塞。另外，在2PC在commit阶段，如果TM和RM都挂了，并且该某个RM已经对事务进行了提交（**可以这么看，RM对事务commit状态的确认发生在了TM之前**）；那么，系统recover后，TM中事务是Prepared，而某个RM中却是commited，这造成了数据状态的不一致。

3PC的解决方案是将commit阶段分为两步：precommit/docommit；这样在precommit阶段，如果都返回成功了，那么TM中先将该事务可标记为提交了（可以看出，**3PC中TM先于RM确认事务commited状态**）；然后，通知各个节点真正做提交这个动作，即使此时TM和RM节点都挂了，那么recovery时RM可以通过TM中的状态，确定RM中事务是否应该提交；不会造成数据不一致的情况。

> 3PC其实对于网络分区以及异步通信的场景的recovery还是存在问题，有人又提出了E3PC的方案，有兴趣可以了解下。
>
> 另外，还有一种Paxos Commit，就是基于共识算法进行关于commit/aborted的决策；这样RM就作为consensus cluster的client进行请求即可，但是前提是RM都已经处于Prepared的状态了（达到Prepared状态就需要一轮通信，所以这也并不是很高效）。

## 并发控制

在多事务并行中，如果两个事务中的两个操作（这两个操作其中至少有一个是写）目标是同一个对象，那么会产生冲突。这里就要求并行调度保证事务前后的正确性，以及运行期间的隔离性。

在单机环境中，一般有三种方式进行并发控制：

+ MVCC：多版本并发控制。数据带上和事务标识相关的版本号。
+ S2PL：严格两阶段提交协议；比起2PL，S2PL直到事务结束才释放写锁。
+ OCC：乐观并发控制。在冲突较低的场景下，在事务结束才判断是否冲突，提高性能。整个事务就分为三个阶段：执行、确认、提交。在确认阶段有一些判断规则。

相应地，在分布式环境中有基于同样思想的并发控制：

+ Distributed 2PL：系统中有一个或若干个锁管理器节点，该节点负责全局的锁分配和冲突检测。

  > 分布式死锁检测
  >
  > + 中心点集中检测，如果有一个全局锁服务，可以在该服务中，做死锁检测。
  >
  > + 每个节点单独检测，需要同步其他节点的事务依赖序列。

+ Distributed MVCC：这里需要有一个全局唯一的自增ID（或时间戳）；在Google的spanner中物理的方式实现了一个全局时间戳。另外，还有使用混合逻辑时间戳（CockroachDB）。

+ Distributed OCC：和单机环境相同。但是在确认阶段有一些分布式环境中相应规则。

不过是哪种方法，都是为了进行多个全局事务的读写同步；在**每个分布式的事务内部**还是按照多阶段的方式提交。



Links:

[1. dist lock](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)

[2. consistency model](https://aphyr.com/posts/313-strong-consistency-models)

[3. consistency model](https://projects.ics.forth.gr/tech-reports/2013/2013.TR439_Survey_on_Consistency_Conditions.pdf)