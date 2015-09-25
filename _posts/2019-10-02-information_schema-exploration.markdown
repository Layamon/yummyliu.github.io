---
layout: post
title: MySQL5.7——TABLE_SHARE简析
date: 2019-10-02 16:44
categories:
  - MySQL
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
InnoDB不等于MySQL，其只是一个事务性存储引擎。在plugin storage之上，还有关键的SQL层，其中包含connection pool、parser、optimizor、access control以及table define cache等结构，本文主要讨论上层的table define cache，简称tdc。

# Table Define Cache

```cpp
HASH table_def_cache;
static TABLE_SHARE *oldest_unused_share, end_of_unused_share;
```

table_def_cache是一个`(dbname/tablename, TABLE_SHARE*)`的HASH表。`dbname/tablename`+frm后缀是某张表的frm路径；另外，TABLE_SHARE在全局维护了一个双向链表，如下，TABLE_SHARE可看做是双向链表中的一个节点。

```cpp
struct TABLE_SHARE
{
	...
  TABLE_SHARE *next, **prev;            /* Link to unused shares */
  /**
    Array of table_cache_instances pointers to elements of table caches
    respresenting this table in each of Table_cache instances.
    Allocated along with the share itself in alloc_table_share().
    Each element of the array is protected by Table_cache::m_lock in the
    corresponding Table_cache. False sharing should not be a problem in
    this case as elements of this array are supposed to be updated rarely.
  */
  Table_cache_element **cache_element;
	...
  ulong   version;
	...
  uint ref_count;                       /* How many TABLE objects uses this */
	...
}
```

每打开一个表实例，就创建对应的TABLE_SHARE，其中的内容就是frm文件的内容。当用户进行DDL时，则会重新创建一个新的frm文件，其中会调用`close_frm`，`close_frm`中会调用`release_table_share`，将表的TABLE_SHARE从**哈希表（table_def_cache）**和**双向链表（oldest_unused_share）**中删除。

> TABLE_SHARE除了存放了frm的信息外，还维护了一些额外的状态，比如ref_count和version等。
>
> 有时候一些操作如close table会调用release_table_share，来减少表对应的TABLE_SHARE的引用计数，如果引用计数为0了，但是版本没发生变化，则将其放入到双向链表尾部，并且不会将其从**table_def_cache**中删除。下次，如果在使用该表，则无需磁盘上读取。

`TABLE_SHARE`是全局共享的数据定义模板，在每个查询线程中有自己的`TABLE_LIST`(`*thd->lex->select_lex->get_table_list()->table->s`)，这是线程本地Table_cache，其还是从TABLE_SHARE中取出的信息，相当于TABLE_SHARE的引用，TABLE_SHARE维护一个`ref_count`。这些Table_cache在使用完不会丢弃，而是放回TABLE_SHARE的实例池（Table_cache_elements）中，会进行重用。如下图表示了各个结构之间的关系。

![image-20200310182109947](/image/table-share/1203-TDC.png)

下图中是COM_QUERY类型的调用栈，线程在查找表定义时，首先从本地的table_cache，即`SELECT_LEX->TABLE_LIST->TABLE`，取出表定义信息；没找到从全局`TABLE_SHARE`中取；如果`TABLE_SHARE`还是没有就从frm中取，这主要就是涉及到线程本地的`SELECT_LEX`结构和全局的`TABLE_SHARE`结构之间的信息交互。



![image-20191205113513580](/image/table-share/1203-sql.png)

所有`TABLE_SHARE`中的`Table_cache_element`都通过Table_cache_manager组织起来，为了避免取table_cache时的锁竞争，MySQL通过*table_open_cache_instances*将table_cache进行了分块，如下代码。

```cpp
class Table_cache_element
{
  ...
  friend class Table_cache;
  friend class Table_cache_manager;
  friend class Table_cache_iterator;
};
class Table_cache_manager {
  /** Get instance of table cache to be used by particular connection. */
  Table_cache* get_cache(THD *thd)
  {
    return &m_table_cache[thd->thread_id() % table_cache_instances];
  }
  ...
}
```

综上，tdc就是frm文件的缓存，这是用户不可见的，但是用户可以通过参数`table_open_cache`定义了所有线程可打开的表的总量，通过监控参数`Opened_tables`可以看到历史上打开过的表数量，`Open_tables`表示当前打开的表数量。如果发生性能的抖动可以观察这些参数是否合适。

另外，表的信息是放在系统库——Information_schema中，下面简单介绍下information_schema。

# information_schema

在系统初始化后，`show databases`命令可以看到4个数据库，但是数据目录中只有三个performance_schema/sys/mysql，却没有information_schema；这是因为informationa_schema是MySQL的一个只读的系统视图，而不是一个专门的库；

Information_schema可以看做是MySQL的catalog（PostgreSQL的[catalog](https://www.postgresql.org/docs/11/catalogs.html)），其中有数据库、表、列各个维度的信息。其都是只读的表，用户本身无法进行update/delete/insert。并且information_schema是通过类似存储引擎扩展的方式，实现的一种新扩展接口——`MYSQL_INFORMATION_SCHEMA_PLUGIN`，从而添加新的系统视图。

> plugin有很多种，还有熟悉的MYSQL_STORAGE_ENGINE_PLUGIN；以及MYSQL_UDF_PLUGIN，MYSQL_FTPARSER_PLUGIN，MYSQL_AUDIT_PLUGIN等。
>
> 只要你想要在MySQL的系统表中添加一种新的元信息，那么就可以实现这个扩展即可。

在MySQL5.7中，information_schema中的表在底层存储中会放在不同的介质中，如下图，其在8.0之后，为了要准备支持事务性DDL，将元信息都放在InnoDB中，整体上逻辑更加清晰，性能更加优越些：

![img](/image/table-share/1203-overview_of_IS.png)

上面说了，TDC是frm的缓存，而information_schema就是TDC对外的呈现形式。我们其实可以在代码中通过`reload_acl_and_cache`加`REFRESH_TABLES`参数的方式对TDC进行刷新，因此也就能够更新information_schema中的系统视图。
