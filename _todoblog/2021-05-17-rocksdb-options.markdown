---
layout: post
title: RocksDB的一些参数
date: 2021-05-17 20:42
categories:
  - RocksDB
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
- optimize_filter_for_hits：对于底层一直命中的场景，即不存在NotFound的查询，底层需要一直IO，filter可以不要，底层SST中不需要filter信息，节约内存与外存空间；而对于NotFound较多的场景，关闭该参数，减少对最底层的IO。

