---
layout: post
title: 
date: 2021-07-31 12:26
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}

## Allocator

在空间利用率和请求吞吐之间进行权衡；基于系统内存对齐以及管理方便的背景，allocator通常有一个minimun block size，这会带来internal Fragment；但空间浪费更多的来自Externel Fragment。malloc返回给用户的内存是block的data部分，block的header部分保存了一些flag与长度信息；比如要求是8bytes对齐，那么内存地址的低3bit已知全0，可以用来存一些flag（e.g. isallocated?）。一个allocator具体实现通常需要考虑以下方面：

- Free List format：Allocator自己管理一些可用的空间块，当user请求内存的时候，可以直接满足而不需要发起syscall陷入kernel；管理free list的方式有多种。
- block format ：malloc返回给用户的是block的data区域，还有一些block的元信息需要保存
  - Boundary tag：通过加一个block footer，解决合并时候当前块无法得知位于前方的块的信息的问题；也可以通过在当前block header的flag区域，借用一个bit表示 prev block 是否allocated，这样只有prev block是free的时候，才需要footer。
- placa/split/coalescing free block：如何找到一个free block，以及找到后如何分配，分配后如何收回。
  - Placement policy：first fit都是找到的第一个满足的块，就分配出去，这样大的free block都在后面， 对于大块的分配响应时间高；Next fit是first fit的拓展，分配速度更快但是空间利用率不高；best fit空间利用率高，速度取决于freelist的组织形式。
  - split free block：当free block大于需要的空间时，是否切分？
  - Coalescing Free Blocks：合并相邻的free block，此时权衡合并的时机。







