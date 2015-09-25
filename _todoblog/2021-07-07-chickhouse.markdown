---
layout: post
title: 
date: 2021-07-07 11:24
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
# ClickHouse

ideas:

1. brute force read & smaller read faster query
2. cpu boost & apply more cpu , get more parallel

arch:

1. sharding & parallel
   - multi master & eventually consistency
2. column storage & vectorized  query exe
   - sparse index, every grunle has an index entry
   - skip indexes knock out unnecessary io

feature:

1. big table group by agg
2. **codecs to reduce column input of compression**
3. mat view
4. sampling to get "goog enough" result

limitation:

1. join
2. no optimizer
3. multi-master repl build on zookeeper, instead of it own raft; such as kaffa move from zk to it own buildin-raft .

