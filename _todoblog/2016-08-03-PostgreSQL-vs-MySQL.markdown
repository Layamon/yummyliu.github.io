---
layout: post
title: (译)PostgreSQL vs MySQL
subtitle: When considering which database to use for your business, don’t make the mistake of thinking that all open source RDBMS are the same!
date: 2016-08-03 20:54
header-img: "img/head.jpg"
categories: 
  - Database
  - PostgreSQL
  - MySQL
---

PostgreSQL和MySQL之间有很大的不同，在评估过两者不同，并做好权衡后决定，才是明智的；这里提供了一个两者之间经常被评估的特性：

+ Open Source
+ ACID合规性
+ SQL合规性
+ Replication
+ Performance
+ Security
+ Cloud Hosting
+ Community Support
+ Concurrency Support
+ NoSQL/JSON Suport
+ Materialized Views & Temporary Tables
+ GeoSpatial Data Support
+ Programming Languages Support
+ Extensible Type System

尽管两者有很多相同的地方，也有很多相当不同的地方。我们尽力提供一个公平并且准确的两者之间的比较，但是最后，需要你基于你的应用场景来评估，决定哪个更加适合你的情况；

明显我们支持PostgreSQL，但是也有有一些情况下，MySQL更加适合。

##### Open Source

开源软件有自己独有的优势——低成本，灵活性，自由，安全并且负责任的，这在一些软件解决方案中有卓越的优势。开源软件是免费获得的，并且可以修改并重新分发；开源软件有很长的生命周期并且永远在技术的前沿。被全世界范围内的组织和个人支持者创建和支持，很多人以和开源合作和志愿为生。

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL被PostgreSQL全球开发组织开发，其中包括多个公司和个人。它是免费并且开源的软件。PostgreSQL基于PostgreSQL协议发布，和BSD和MIT协议很像。 | MySQL基于GNU发布了源代码，以及各种专有协议。现在被Oracle拥有，并提供了多个付费的版本。 |

##### ACID Compliance

ACID是数据库事务的基本特性。ACID合规保证了，在系统失败甚至单个事务中执行多次更改时，没有数据损失和误操作；

| PostgreSQL                                                 | MySQL                                                |
| ---------------------------------------------------------- | ---------------------------------------------------- |
| PostgreSQL是完全支持ACID特性，并且确保所有的要求是符合的； | MySQL只有使用InnoDB和NDB集群存储引擎的时候才是支持的 |

##### SQL Compliance

SQL Compliance是数据库必须遵守和实现的标准，来执行结构化查询。当公司想在多个数据库系统上集成工作，这是很重要的；遵循SQL标准，使得数据库迁移变得容易的多；

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL是一个符合更多的SQL规范。与SQL规范的一致性在PostgreSQL文档的Appendix D中，如果有偏差在Reference中找到；*PostgreSQL支持SQL：2011大部分的的特性，核心部分的179个强制要求，支持160个。并且当前任何dbms没有完全支持sql：2011* | MySQL的某些版本是部分支持（比如不支持CHECK约束）*该产品的一个主要目标是不断完善来符合sql规范，但是没有满意的性能和可靠性。我们不介意在SQL中添加额外的扩展汇或者支持非SQL的特性来提升用户可用性* |

##### Replication

数据库复制是从一个节点往另一个节点上频繁的数据拷贝，这样所有的用户可以共享相同的信息。结果就是一个分布的数据库，这样用户可以访问和他相关的数据而不影响其他人；

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL支持Master-Standby复制，并且引入了强力的优化，使得更快的wal传输处理，这样PostgreSQL中有个几乎实时的热备；<br /><br />PostgreSQL支持的复制：一对一；一对多；热备/流复制；双向复制；逻辑流复制；级联复制。 | MySQL支持Master-Standby复制<br /><br />MySQL中支持的复制类型：一对一；一对多；一个master对应一个standby，这个standby对应一个或者多个；回环复制（ A to B to C and back to A）;Master to Master； |

##### Performance

性能能够基于一些潜在的场景测试出来，因为这个特定的用户需求和应用环境相关；

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL广泛用在一些大型系统中，读写速度很关键并且数据需要保证有效的。另外，PostgreSQL支持一些只在商业系统（比如Oracle，SQL server）中存在性能优化，比如地理信息查询和没有读锁的并发，等等；<br /><br />整体来说，PostgreSQL性能在需要复杂查询时表现好；<br /><br />PostgreSQL在OLTP/OLAP系统中表现不错，这些系统要求读写速度和一定的数据分析需求<br /><br />PostgreSQL在BI应用中表现良好，但是更加要求较大读写速度的数仓和数据分析应用； | MySQL在基于web的应用中应用广泛，这些应用中只是需要一个数据库来处理数据存取的事务。在高负载和复杂查询中性能欠佳；<br /><br />在只读的OLTP/OLAP应用中表现良好<br />MySQL+InnoDB在OLTP中有较高的读写速度。整理来说，MySQL适合高并发的场景；<br /><br />MySQL在BI应用中是可用的并且表现良好，因为BI应用是只读的。 |

##### Security

数据库安全性包括一系列的措施，来保护和确保一个数据库或者dbms，防止违规操作，恶意攻击威胁。确保数据库环境安全，包括大量的流程，工具和方法论，这是一个广泛的话题；

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL中有角色和继承的角色，来维护权限。PostgreSQL有本地的SSL认证支持。并且支持行级别的安全性；<br /><br />除了这些，PostgreSQL提供了内建的强化组件——SE-PostgreSQL，提供基于SELinux安全策略的·访问控制； | MySQL基于访问控制列表（ACLs）来实现连接，查询以及其他用户操作的安全性。也有支持SSL认证的连接 |

##### Cloud Hosting

随着越来越多的企业上云，找到支持自身数据库的云提供商变得越来越重要。云托管可以使服务更加灵活，允许动态扩容缩容；减少高峰期间的宕机时间。

| PostgreSQL                                        | MySQL                                             |
| ------------------------------------------------- | ------------------------------------------------- |
| 支持所有的云提供商，包括Amazon Google Microsoft等 | 支持所有的云提供商，包括Amazon Google Microsoft等 |

##### Community Support

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL有一个强大且活跃的社区，持续优化当前的特性；并且他的贡献者，基于最近的技术特性和安全性，不断确保这是**most advaced database**； | MySQL有一个庞大的贡献者，特别是在Oracle收购后，他们主要关注维护现有特性，并偶尔出现一个新特性； |

##### Concurrency Support

并发意味着多个用户同时访问数据。这是开发一个多用户系统的核心特性之一，因为他确保多用户访问的可用性并且数据库可以在多个不同的地方同时访问；

| PostgreSQL                                                 | MySQL                         |
| ---------------------------------------------------------- | ----------------------------- |
| PostgreSQL基于自身的MVCC实现支持并发，这实现了高级别的并发 | MySQL只有在InnoDB中有MVCC支持 |

##### NoSQL Features/JSON Support

NoSQL和JSON现在很流行，并且NoSQL数据库变得很常见；JSON是一个简单的数据类型，支持编程人员在不同系统中存储和传输数据集，列表和键值对；

| PostgreSQL                                                   | MySQL                                                        |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| PostgreSQL支持JSON和其他NoSQL特性，比如本地XML支持和HSTORE来支持键值对。并且支持对JSON类型的数据建索引。 | MySQL有JSON数据类型，但是没有其他NoSQL特性，也不支持对json类型建索引。 |

##### Materialized Views/Temporary Tables

物化视图是数据库的一个对象，存储了查询结果，能够在需要的时候更新。可以认为是数据库中的一个‘cache’。

临时表存储的数据，当session结束后就不需要保存了。和物化视图的不同是后者能够定期更新数据，在这种情况下效率更高；

| PostgreSQL           | MySQL                      |
| -------------------- | -------------------------- |
| 支持物化视图和临时表 | 只支持临时表不支持物化视图 |

##### Geospatial Data Support

地理数据是数据库中存储的数据点，并提供相应的分析功能。这是实际中能够用地理信息表示的数字类型的对象；

| PostgreSQL                                                   | MySQL            |
| ------------------------------------------------------------ | ---------------- |
| 通过PostGIS插件支持地理数据。有专用的地理数据类型和函数，可以在数据库层直接使用，这对于编程和分析十分方便； | 内建地理数据支持 |

##### Programming Languages Support

编程语言的支持，可以使更多的开发者使用他们擅长的语言来执行任务；由于server端支持广泛的编程语言，开发者可以基于不同的背景，可以决定将逻辑发到client端，还是server端，更多的赋能开发者。

| PostgreSQL                                                   | MySQL                      |
| ------------------------------------------------------------ | -------------------------- |
| C/C++, Java, JavaScript, .Net, R, Perl, Python, Ruby, Tcl 等；并且能够在单独的进程中执行用户代码（background worker） | 有一些支持，但是扩展性不行 |

##### Extensible Type System

支持扩展类型的数据库系统中，用户可以扩展数据库，比如添加一个数据类型，Function，operator，aggregate Function，index类型以及存储过程语言；

| PostgreSQL                                         | MySQL |
| -------------------------------------------------- | ----- |
| 有一些支持扩展的特性：添加新类型，新函数，新索引等 | No    |

[原文链接](https://www.2ndquadrant.com/en/postgresql/postgresql-vs-mysql/#SUMMARY)