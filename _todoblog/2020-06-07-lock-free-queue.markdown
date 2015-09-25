---
layout: post
title: 
date: 2020-06-07 14:49
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
```c++
enqueue(x):
	new_p = node(x);
	new_p->next = nullptr;

	lock()
	tail->next = new_p;
	tail = tail->next;
	unlock()

dequeue():
	if (head->next == nullptr):
		return "empty code"
  lock();
	head = head->next;
	unlock();
```









lock-free的描述对象是function，如果一个数据结构的所有操作都是lock-free的，那么该datastructure也称为lock-free；

+ non-blocking：spinlock 是non-blocking，但是不是lock-free；因为spinlock不会使线程suspend；
+ waiting-free：waiting-free是lock-free，并且对于任何执行线程，该函数都可以在有限步骤内完成（即，不存在位置的retry次数）；相比之下，non-blocking的函数只能保证至少一个（获得spinlock的）线程，在有限步骤内完成。







CAS

> we can change val only if we know its current value
>
> Return value：true if the underlying atomic value was successfully changed, false otherwise.



dummp head node

https://www.justsoftwaresolutions.co.uk/threading/non_blocking_lock_free_and_wait_free.html