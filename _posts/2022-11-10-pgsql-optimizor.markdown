---
layout: post
title: Postgres Planner 术语解释(ing)
date: 2022-11-10 15:28
categories:
  - PostgreSQL
typora-root-url: ../../layamon.github.io
---
PostgreSQL的planner在开源数据库中应该是代码结构相对清晰的，是个很好的学习Planner的参考资料；笔者经验也不多，这里暂时沉淀一下一些已有的了解；并不能完全说明白PgSQL的planner的方方面面，勉强算是个代码导读吧，有错误欢迎指正；应该会不定期更新，包括勘误以及增加更多的术语解释。

主要内容就是PgSQL的planner的一些术语的含义，然后介绍一下执行大致流程，了解这些术语在Planner中的位置。

# PgSQL Planner 术语

- **Rel**，在Planner类似表的提供多列数据的载体，不仅仅包括真实的Table，称为base rel；也包括join的结果，称为join rel；其他的Rel称为UpperRel。
- **RangeTable**，当前planner中的涉及的Rel；
- **Var**，对Rel的column的引用；
- **Qual**，`WHERE`语句最终解析成一个个bool expr，一般作为filter；也有的成为IndexCondition，还有成为Join-Qual；
  - Outer-join-delay-qual，表达式下推是常见的优化手段，但是由于outerjoin的性质，有些qual如果下推了，执行结果就有问题，那么就要推后作为join filter；
- **EquivalenceClass**（EC)，假如where条件中有Var_a = Var_b，那么Var_a和Var_b在当前plan中就是等价的，这两个Var就可以放在同一个EC中；基于EC的性质可以对表达式进行等价变换。
- **Path**，PgSQL中的每个Rel都对应多个Path，Planner需要在多个Path中，找到最优的Path；
  - `RelOptInfo`，Path的载体，即Rel。
  - *Restriction*，对Path上的结果进行过滤；
  - *PathKey*，当Path的结果有序的时候，通过PathKey得知按哪些column排序；
  - *Parametrized Path*，Path中的Restriction中有运行时才得知参数；这类Path的其中一个作用是针对于多表Join，join不管什么算法左右path都需要扫描全部的数据，只有innerpath为indexscan才能避免扫描全部的数据；如果多表join的最内层表是star-schema中的大表，那么大概率join-clause都是围绕这个大表来的，此时通过parameterized path将join-clause推到下层能够显著减少path的rowcount。
  - *Partial Path*，PgSQL的ParallelQuery是基于data-partition来的，当ScanPath可以并行的话，就返回一个PartialPath，并标记`parallel_aware=true`；PartialPath之上还可以加PartialPath，某个Node找不到PartialPath，这时就得加个Gather节点；PartialPath的Cost要算上Gather的代价，并且在一个单独的path_list中维护。
  - *Partitionwise Join*，多个分区表之间的equal-Join，如果Joinkey都是partition-key，那么父表的join可以下推到各个子表进行。
- **SubLink/SubSelect/SubPlan/SubQuery**，一般查询只有一个Select，当Select嵌套Select时，内部的Select就称为*subselect*，subselect位于expression中就称为*sublink*，位于rangetable中就称为*subquery*；不管sublink还是subquery，这都是在planner阶段的称谓；在executor阶段，称为*subplan*。

# PgSQL Planner 大致流程

Planner的目标就是找到最优的Planner，主要有两个策略，bottom-up和top-down；前者源自SystemR的经典策略，PlanTree从子节点逐步构建成整棵树，类似DP的策略；后者通常指的是cascade/volcano一类的planner，其从一个完整的tree不断变换出不同的tree，最终找到最优的那颗树，类似剪枝搜索的策略；PgSQL的经典planner属于前者。

在PgSQL中，Planner的入口就是`planner()`，大致的执行层级如下：

```c
plannner()
  - subquery_planner()
    - grouping_planner()
      - make_one_rel()
        - set_base_rel_pathlists()
        - make_rel_from_joinlist()
          - standard_join_search()
```

在PgSQL中，一个SQL可能对于多个subquery生成多个PlanTree；`subquery_planner`处理每个subquery，处理过程主要包含四个过程：

1. **Preprocess**      	
   - Early : 对Query做一些等价变换，大概包含以下的操作，之间有些先后依赖关系，会在特定的顺序下执行：
     - 简化：
       - 标量（scalar）表达式；
       - Join Tree
         - 根据`from_collapse_limit`，上拉子查询；
         - 降低Join的限制，比如根据某些条件将 left join 变成 inner join。
         - 将 `in/exist` 转换为 semi-join；
         - 识别出anti-join；
     - 展开
       - 简单的函数；
       - 简单的视图；
       - `union all`;
   - Later：在转换好的Query上，收集Planner需要的信息，并做一些初步的处理；
     - 将*where qual*尽量下推；
     - 确定*Var*需要在Tree中生命周期；
     - 构建 *equivalenceclass*；
     - 收集join order restriction；
     - 移除useless join；
2. **BaseRel/JoinRel Path**：处理`FROM`和`WHERE`子句，生成baserel和joinrel；BaseRel多个ScanPath，JoinRel对应多个JoinPath。
   + Scan虽然会找到cost最便宜的path，但是会考虑`OrderBy`语句，生成带PathKey的Path，或者考虑并行生成PartialPath。
   + JoinOrderSearching是Planner的核心操作，是最耗时的部分；在pg中，超过一定数量的表就不走DP了，直接fallback到”GEQO“的方式；通过交换子joinrel的顺序，找到最终的joinrelorder，但是有些情况下，不能交换，比如OuterJoin不能随意交换，通过`join_is_legel`判断。
   + 每个rel对于每个有用的SortOrder会保留一个cheapestpath。
   + 在构建BaseRel的Path以及JoinRel的Path的时候，会基于得到的EC集合，取得一个qual，尽管这个qual并不是用户一开始写的；这样，在探索jointree的时候，可能就会避免生成一个笛卡尔积的joinnode；以及，在scan的时候，会多出一些restriction；
3. **UpperRel Path**：处理Scan和Join之外的算子的Path，每种算子的Path都是放在`RelOptInfo`中，这里的Rel就是UpperRel。
4. **PostProcess**：Path转换为Executor的Plan，以及一些其他的整理工作，比如
   - 移除不需要的Node。
   - 标记`OUTER_VAR`或者`INNER_VAR`。
