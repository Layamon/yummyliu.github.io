---
layout: post
title: Python内存布局
date: 2018-03-15 09:08
header-img: "img/head.jpg"
categories: 
  - Python
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
# Python简介

在Python的[参考手册](https://docs.python.org/3/reference/index.html)里定义了Python的具体语法；但是，Python是一个解释型语言；具体执行的时候需要解释器来解析成可执行代码。默认的解释器是CPython。

> 可执行代码，这里可以是机器代码也可以是另一个虚拟机的字节码；比如Python语言的具体实现由CPython、Jpython、IronPython、PythonNet；以及PyPy。

> 本文以3.7版本为例

## 对象

我们都知道C不是一个Object-oriented的语言，但是Python中**一切都是对象**，包括int和str。因此，在CPython的实现中，有一个结构称为`PyObject`，它被其他所有CPython对象使用，是所有对象的祖宗，其中只有两个信息：

- **ob_refcnt:** 引用计数，用在垃圾回收中。
- **ob_type:** 指向实际类型描述的指针，比如dict或者int的类型描述。

在每个对象中，都有自己的allocator和deallocator，分别用来申请和回收内存。对于解释器的内存的共享，CPython采用GIL来进行控制：当访问共享资源的时候，会将整个解释器锁住。

> Global Interpreter Lock

## 垃圾回收

每个对象都有自己的引用计数，当引用计数为0时，那么该对象就可以被回收。

```python
Python 3.7.2 (default, Feb 12 2019, 08:16:38)
[Clang 10.0.0 (clang-1000.11.45.5)] on darwin
Type "help", "copyright", "credits" or "license" for more information.
>>> import sys
>>> n=[1,2,3]
>>> n1=n
>>> sys.getrefcount(n)
3
```

如上例子中，我们可以通过`getrefcount`查看每个对象的引用计数；这是是3：声明变量时初始为1；赋值+1;传参+1。当引用计数为0时，就会调用deallocator的free函数将空间释放，其他对象就可以重用了。

# CPython内存管理

基于OS的虚拟内存映射(VMM)之上，python解释器进程申请了一整块空间；其中一部分是解释器自用的内存；另一部分就是给Object用的，这部分分为两部分：

+ Object-specific allocator：每个对象内部的分配器；
+ Python's Object allocator：Python的全局对象分配器

为了处理多次小数据量的申请，CPython对其进行了优化；另外，也尝试**延迟分配**（在内存真正使用的时候才真正的分配）。

而对于CPython中的内存，分为三个级别，从小到大分别是Block、Pool、Arena，上级包含多个下级

+ block，每个Block都是一些固定大小的块，按照固定的size进行分配，比如2kb，4kb，...。

+ pool，每个Pool中都包含同一大小的块。
+ Arena，包含多个Pool；维护多个poolList

