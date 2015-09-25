---
layout: post
title: 初识PostgreSQL的分区表
date: 2018-05-29 15:13
header-img: "img/head.jpg"
categories: 
    - PostgreSQL
---

* TOC
{:toc}

# Table Partition 

将一个逻辑的大表，分割成物理的小表。从而获得几点优势：

1. 提高查询性能，特别是对于某些只落在某一段区间的查询；分块可以减少索引的大小，从而可以全部放在内存中；
2. 当查询访问某一块的大部分数据时，原来需要随机访问的，现在可以seq scan；避免随机扫描
3. 块操作（加载或者删除）都可以直接对partition操作（`ALTER TABLE DETACH PARTITION`或者直接 DROP TABLE）进行处理，避免了vacuum的负载；
4. 冷热数据分离存储

Partition对于比较大的表才有效，一般经验就是表大小超过了物理内存大小；PostgreSQL提供了内置的支持：

+ Range Partitioning

  根据定义好的一个或多个列，来Partition；Partition的key的取值range没有重叠

+ List Partitioning

  明确指定好了哪些key出现在某些Partition中；

如果上述两种满足不了你的Partition需求，你可以使用表继承或UNION ALL VIEW来实现；一些别方法提供了灵活性，但是没有内建的性能优势；

### 声明Partitioning

> 以下文中，分区表指的是逻辑表，分区指的是物理分区子表

PostgreSQL提供了Partition的方法，包括一个**partitioning method**和**partition key**（列的集合或者一个表达式）；

基于Partition key的值，所有的行被路由到底层的表中；每个Partition通过**partition bounds** 限制的一个数据子集；对于现在支持的两种分片方式，每个partition被赋予一个key的区间，或者一个key的集合；

Partitions可以有和其他Partition不同的，自己的indexes，constraints或者default values；

不能将一个普通表转成分区表，反之亦然；但是可以将一个普通表或者分区表添加到分区表中；或者删除一个分区表的分区，使之成为一个普通表；`ATTACH PARTITION`或 `DETACH PARTITION`

分区表和其对应的分区不能使用PostgreSQL中的继承，因为其本身就是基于继承实现的；有几点需要注意：

+ 分区表上的CHECK和NOT NULL约束，被所有的分区继承；分区表的CHECK中不能创建NO INHERIT约束
+ 当分区表没有分区的时候可以使用ONLY 来加减分区表上的约束；有分区的时候，可以在分区上加减约束；并且由于分区表没有数据，所以truncate only也会失败；
+ 分区中不能有分区表里没有的列，包括任何oid列；
+ 如果分区表中有NOT NULL约束，不能删掉分区中的NOT NULL约束

Partition也可以是外部表，但是这种用法有些限制，比如数据insert的时候不能路由到外部表中

##### Example

冰淇淋厂，监控销量和温度的关系的表，只保留三年的数据，每个月删除老月份的数据

1. 创建measurement表

   分区表指定partition key和Partition method

   ```sql
   CREATE TABLE measurement (
       city_id         int not null,
       logdate         date not null,
       peaktemp        int,
       unitsales       int
   ) PARTITION BY RANGE (logdate);
   ```


2. 创建分区

   ```sql
   CREATE TABLE measurement_y2006m02 PARTITION OF measurement
       FOR VALUES FROM ('2006-02-01') TO ('2006-03-01');

   CREATE TABLE measurement_y2006m03 PARTITION OF measurement
       FOR VALUES FROM ('2006-03-01') TO ('2006-04-01');

   ...
   CREATE TABLE measurement_y2007m11 PARTITION OF measurement
       FOR VALUES FROM ('2007-11-01') TO ('2007-12-01');

   CREATE TABLE measurement_y2007m12 PARTITION OF measurement
       FOR VALUES FROM ('2007-12-01') TO ('2008-01-01')
       TABLESPACE fasttablespace;

   CREATE TABLE measurement_y2008m01 PARTITION OF measurement
       FOR VALUES FROM ('2008-01-01') TO ('2008-02-01')
       WITH (parallel_workers = 4)
       TABLESPACE fasttablespace;
   ```

   每个分区的分明必须有边界，并且边界是和分区表的Partition key和Partition method对应的，且不重叠也不遗漏；并且可以在分区上再次创建分区：

   ```sql
   CREATE TABLE measurement_y2006m02 PARTITION OF measurement
       FOR VALUES FROM ('2006-02-01') TO ('2006-03-01')
       PARTITION BY RANGE (peaktemp);
   ```

3. 在每个分区的key列上创建索引

   ```sql
   CREATE INDEX ON measurement_y2006m02 (logdate);
   CREATE INDEX ON measurement_y2006m03 (logdate);
   ...
   CREATE INDEX ON measurement_y2007m11 (logdate);
   CREATE INDEX ON measurement_y2007m12 (logdate);
   CREATE INDEX ON measurement_y2008m01 (logdate);
   ```

4. 确保配置项`constraint_exclusion`是on或者partition的，要不然query不能有效的优化

如上，我们创建了一个基于每个月的分区表，聪明的人会写一个脚本自动生成DDL；

##### Partition 维护

一般来说，分区表一开始创建的分区都不是静态的，后面就会删掉老的分区，创建新的分区；比如：

```sql
DROP TABLE measurement_y2006m02;
```

上面的操作会在分区表上请求`ACCESS EXCLUSIVE` 锁；另一种方式更好，在分区表上移除了这个分区，但是仍然可以访问这个表，可以留下时间，来将这些数据做一个备份：

```sql
ALTER TABLE measurement DETACH PARTITION measurement_y2006m02;
```

同样可以创建一个新的分区

```sql
CREATE TABLE measurement_y2008m02 PARTITION OF measurement
    FOR VALUES FROM ('2008-02-01') TO ('2008-03-01')
    TABLESPACE fasttablespace;
```

可以创建一个表，后期再加到分区表中，作为一个分区：

```sql
CREATE TABLE measurement_y2008m02
  (LIKE measurement INCLUDING DEFAULTS INCLUDING CONSTRAINTS)
  TABLESPACE fasttablespace;

ALTER TABLE measurement_y2008m02 ADD CONSTRAINT y2008m02
   CHECK ( logdate >= DATE '2008-02-01' AND logdate < DATE '2008-03-01' );

\copy measurement_y2008m02 from 'measurement_y2008m02'
-- possibly some other data preparation work

ALTER TABLE measurement ATTACH PARTITION measurement_y2008m02
    FOR VALUES FROM ('2008-02-01') TO ('2008-03-01' );
```

在执行 ATTACH PARTITION 之前，先创建好约束；否则添加的时候，分区表要检查约束，需要获取ACCESS EXCLUSIVE锁；

##### Partition 限制

+ 不能同时在多个分区上创建同样的索引，只能一个个来，这也意味着不能同时创建Partition；
+ 分区表不支持主键，也不支持引用外键；
+ 分区表上使用ON CONFLICT会报错，因为分区表不支持unique 约束
+ 导致行迁移的更新操作会失败，因为新的row会违反分区约束
+ 行触发器必须在单个分区表上定义

### 基于继承的方式实现分区表

内建的分区表对于大部分情况都是适用的，有些情况可能更灵活的方法适用；基于继承的方式有一些别人没有的功能：

+ 分区可以有除了父表之外的列
+ 允许多继承
+ 除了range和list的分区方式，还有一些用户自定义的方式（但是这些方式里，可能不能很好的优化）


+ 比起一般的继承方式实现分区表，原生的分区表在一些操作上需要获得更高的锁；比如添加删除一个分区需要分区表上的ACCESS EXCLUSIVE锁，而一般的继承方式只需要SHARE UPDATE EXCLUSIVE锁；

##### example

1. 定义master表：

   ```
   和之前一样，注意除非全部分区都要，否则不要定义约束；也没有必要创建任何索引
   ```

2. 定义child表，和普通表一样：

   ```sql
   CREATE TABLE measurement_y2006m02 () INHERITS (measurement);
   CREATE TABLE measurement_y2006m03 () INHERITS (measurement);
   ...
   CREATE TABLE measurement_y2007m11 () INHERITS (measurement);
   CREATE TABLE measurement_y2007m12 () INHERITS (measurement);
   CREATE TABLE measurement_y2008m01 () INHERITS (measurement);
   ```

3. 定义child表上的没有重叠的check约束

   比如这样：

   ```sql
   CHECK ( x = 1 )
   CHECK ( county IN ( 'Oxfordshire', 'Buckinghamshire', 'Warwickshire' ))
   CHECK ( outletID >= 100 AND outletID < 200 )
   ```

   综合2、3，如下：

   ```sql
   CREATE TABLE measurement_y2006m02 (
       CHECK ( logdate >= DATE '2006-02-01' AND logdate < DATE '2006-03-01' )
   ) INHERITS (measurement);

   CREATE TABLE measurement_y2006m03 (
       CHECK ( logdate >= DATE '2006-03-01' AND logdate < DATE '2006-04-01' )
   ) INHERITS (measurement);

   ...
   CREATE TABLE measurement_y2007m11 (
       CHECK ( logdate >= DATE '2007-11-01' AND logdate < DATE '2007-12-01' )
   ) INHERITS (measurement);

   CREATE TABLE measurement_y2007m12 (
       CHECK ( logdate >= DATE '2007-12-01' AND logdate < DATE '2008-01-01' )
   ) INHERITS (measurement);

   CREATE TABLE measurement_y2008m01 (
       CHECK ( logdate >= DATE '2008-01-01' AND logdate < DATE '2008-02-01' )
   ) INHERITS (measurement);
   ```

4. 对于每个分区创建你想创建的index

   ```sql
   CREATE INDEX measurement_y2006m02_logdate ON measurement_y2006m02 (logdate);
   CREATE INDEX measurement_y2006m03_logdate ON measurement_y2006m03 (logdate);
   CREATE INDEX measurement_y2007m11_logdate ON measurement_y2007m11 (logdate);
   CREATE INDEX measurement_y2007m12_logdate ON measurement_y2007m12 (logdate);
   CREATE INDEX measurement_y2008m01_logdate ON measurement_y2008m01 (logdate);
   ```

5. master上创建触发器

   ```sql
    
   CREATE OR REPLACE FUNCTION measurement_insert_trigger()
   RETURNS TRIGGER AS $$
   BEGIN
       IF ( NEW.logdate >= DATE '2006-02-01' AND
            NEW.logdate < DATE '2006-03-01' ) THEN
           INSERT INTO measurement_y2006m02 VALUES (NEW.*);
       ELSIF ( NEW.logdate >= DATE '2006-03-01' AND
               NEW.logdate < DATE '2006-04-01' ) THEN
           INSERT INTO measurement_y2006m03 VALUES (NEW.*);
       ...
       ELSIF ( NEW.logdate >= DATE '2008-01-01' AND
               NEW.logdate < DATE '2008-02-01' ) THEN
           INSERT INTO measurement_y2008m01 VALUES (NEW.*);
       ELSE
           RAISE EXCEPTION 'Date out of range.  Fix the measurement_insert_trigger() function!';
       END IF;
       RETURN NULL;
   END;
   $$
   LANGUAGE plpgsql;
   ```


   CREATE TRIGGER insert_measurement_trigger
       BEFORE INSERT ON measurement
       FOR EACH ROW EXECUTE PROCEDURE measurement_insert_trigger();
       
​      

   CREATE RULE measurement_insert_y2006m02 AS
   ON INSERT TO measurement WHERE
       ( logdate >= DATE '2006-02-01' AND logdate < DATE '2006-03-01' )
   DO INSTEAD
       INSERT INTO measurement_y2006m02 VALUES (NEW.*);
   ...
   CREATE RULE measurement_insert_y2008m01 AS
   ON INSERT TO measurement WHERE
       ( logdate >= DATE '2008-01-01' AND logdate < DATE '2008-02-01' )
   DO INSTEAD
       INSERT INTO measurement_y2008m01 VALUES (NEW.*);
   ```

6. 确保配置项constraint_exclusion不是disabled的

综上，我们可以看到创建一个分区表需要庞大的DDL操作。这个例子中，我们每个月需要创建一个新的Partition，因此写一个脚本自动创建DDL是很有必要的；

##### Partition维护

类似的有：

1. 删除分区

​```sql
DROP TABLE measurement_y2006m02;
ALTER TABLE measurement_y2006m02 NO INHERIT measurement;`
   ```

2. 添加分区

   ```sql
   CREATE TABLE measurement_y2008m02 (
       CHECK ( logdate >= DATE '2008-02-01' AND logdate < DATE '2008-03-01' )
   ) INHERITS (measurement);

   --- or

   CREATE TABLE measurement_y2008m02
     (LIKE measurement INCLUDING DEFAULTS INCLUDING CONSTRAINTS);
   ALTER TABLE measurement_y2008m02 ADD CONSTRAINT y2008m02
      CHECK ( logdate >= DATE '2008-02-01' AND logdate < DATE '2008-03-01' );
   \copy measurement_y2008m02 from 'measurement_y2008m02'
   -- possibly some other data preparation work
   ALTER TABLE measurement_y2008m02 INHERIT measurement;
   ```

3. 一些基于继承方式实现分区表的警告

   + 没有自动检查分区的check约束是不是互斥的；安全的方式是写一个脚本来创建或者修改相应的object，而不是手动执行
   + 对于update引起的行迁移，会出错；解决的方式只能是写一个合适的trigger来处理这类问题；
   + 手动vacuum或者Analyze的时候，一定要每个分区逐个执行，否则只是在master表上执行；
   + insert on conflict可能不会像预期的一样工作，因为on conflict是基于相应表上的unique 约束，而不是子表
   + trigger和rule被用来做路由，除非应用自己知道自己的分区；trigger比较难写，而且比起内建的分区方式还比较慢；

### Partitioning和Constraint Exclusion

```sql
set constraint_exclusion = on;
SELECT count(*) FROM measurement WHERE logdate >= DATE '2008-01-01';
```

没有打开这个参数，上述查询会扫描每个分区；打开了，那么planner会排除肯定不包含目标行的分区；constraint exclusion是由check驱动的，而不是由indexes驱动的；因此没有必要在key列上定义一个索引；是否定义索引取决于，你的查询在分区上是返回大部分元组还是小部分元组，如果是小部分，那么定义一个索引；

该配置的默认项是一个partition，这个值意味着查询碰到分区表才会使用这种优化；

一些使用该参数的警告：

+ 只有where语句中是常数时，constraint exclusion才会使用
+ 保持分区约束尽量简单，否则planner可能不理解；list的方式使用等值条件，range的方式用简单的区间；经验的方式是，分区约束只使用可以被用来做Btree索引的列，并且使用Btree索引中可用的操作符；
+ 在contraint exclusion检查是，master表上所有约束都被检查；这会导致planner生产查询计划比较慢；索引不要分太多的区，几百个就可以，几千个就算了；
