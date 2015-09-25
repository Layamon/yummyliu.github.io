---
layout: post
title: 
date: 2021-02-24 15:47
categories:
  -
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

- SpinLock：基于原子变量
- Ticket SpinLock：保证公平，不出现Starvation；
- Queue SpinLock：保证公平与Cache 友好。



SpinLock占用CPU资源，对于大Job使用Semaphore同步；

- Mutex：先Spin，后可基于MCSLOCK.SpinLock，最后Sleep。
- RW Mutex：
  - SeqLock：Rw Mutex会出现Writer饿死的情况，如果Writer很少，可以乐观控制，即，Writer可以随时抢占更新；但是Reader在最后会通过SequenceNumber检查期间数据是否被改变。