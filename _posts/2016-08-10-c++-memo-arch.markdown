---
layout: post
title: C++内存管理
date: 2016-08-10 15:58
header-img: "img/head.jpg"
categories: 
    - C++
typora-root-url: ../../layamon.github.io
---

* TOC
{:toc}
# Linux内存管理

*对于Linux内核来说*，物理内存通过page结构进行管理，可以按page级别分配物理内存；也可以通过kmalloc分配指定长度的连续的物理内存；但一般内核常用的数据结构通过内核对象高速缓存，为每种常用的结构体对象构建了对应的kmem_cache。每个kmem_cache包含若干个slab，每个slab中装着相应的object；当slab没有可用object时，通过kmalloc申请内存，这套机制就叫Slab，内核态管理物理内存的一种机制。内核也可以通过vmalloc按照虚拟内存进行申请，这和用户空间的动态分配类似；而本文主要阐述了C++进程的用户态内存管理，这里不做展开。

> 关于[slab/slub/slob](https://cs.stackexchange.com/questions/45159/can-someone-explain-this-diagram-about-slab-allocation)：slab allocation is a very flexible framework which can be tuned for the needs of different kinds of data. It doesn't compete with paging, but complements it.

*对于CPU来说*，其是基于virtual address运行程序，在CPU侧有个专门的MMU单元（硬件），MMU基于进程的PageTable将虚拟地址（线性地址）转换为物理地址，从而访问真实的数据。在用户态，Linux为每个Process提供了自己的virtual address（linear address）空间，体现在进程描述符中的内存描述符（**mm_struct**）中；mm_struct描述了一个虚拟地址空间的所有信息，当fork一个新进程时，如果指定了CLONE_VM标记，那么新进程和老进程共享同一个mm_struct，这个新进程就是用户线程（对于内核线程的进程描述符中，mm_struct为NULL，同样可见内核这里都是直接操作物理内存）。

> MMU处理单元的缓存叫TLB；如果进程的页更大，页面访问更加有局部性，能够有有效提高TLB hit，提高整体性能。

*对于每个进程来说*，进程地址空间中的每个virtual page在Page Table都有一个entry，通过valid flag标记是否有对应的物理page。当进程需要访问page时，如果该page table entry（pte）是valid（Page Hit），那么MMU就得到相应的physical page（又叫 page frame）；而如果pte是invalid（Page Fault），MMU触发一个**page fault exception**，由对应的handler来处理，得到物理page，最后将虚拟页与物理页的映射放在自己的page table中。

> 并不是每个虚拟页都有自己的物理页，VSZ为该进程的虚拟地址空间的使用量；RSS（Resident set size）表示process具体物理内存占用。

*关于Page Fault*，有两种类型：major（需要从back storage获取page），minor（比如virtual memory需要真实物理页时），触发page fault的原因如下：

<img src="/image/linux-mem/page-fault-reason.png" alt="image-20210727113759729" style="zoom: 33%;" />

可见并不是每个虚拟page都是对应物理内存页，物理页的分配是用户进程通过触发PageFault进行处理的。比如	当fork发生后，parent和child的pte都变成read only（相应的entry标记位write protected）；当某个进程需要write时，发生minor page fault，通过do_wp_page()进行处理。

而在每个进程的的虚拟内存空间中又是怎么布局的呢？

## Process Memory Layout

如下可执行程序：

```c
#include <stdio.h> 
int main(void) 
{ 
	return 0; 
}
```

对于一个可执行文件本身分为三部分：text/data/bss；当代码运行起来，这三部分就是进程的虚拟地址空间的全局区域，位于低地址；

<img src="/image/cpp-memo/linuxFlexibleAddressSpaceLayout.png" alt="Flexible Process Address Space Layout In Linux" style="zoom: 67%;" />

运行时的动态申请的内存heap地址由下向上变大；stack是向下增长，在stack之上是kernel space；实际上[heap，stack的起始地址是随机的](https://manybutfinite.com/post/anatomy-of-a-program-in-memory/)，因为一旦地址固定，容易被被不法人员利用；另外在Free部分，会包含mmap的地址空间，起始地址同样是随机的。

我们可也通过pmap -p PID（/proc/pid/maps）可以看到运行时进程的内存布局，可以看到该进程虚拟地址空间中的每一段虚拟内存区（VMA），比如可也看到动态链接库被加载到某一段空间中。在用户态，我们可通过mmap创建一段VMA，我们常用的malloc就是基于mmap的方式动态分配内存（当然在glibc中，也有通过sbrk的方式动态分配内存）；C++代码中对动态分配内存的管理是个难缠的话题，铺垫了这么多终于到了主题；C++的内存管理是C++程序员的必修课，永远不敢说熟悉C++😢，这里是笔者简单的总结，日后还会一直完善这个章节

# C++内存管理简述

## RAII

**"RAII: Resource Acquisition Is Initialization"**，这时OOD中的一个约定，意思是资源的获取与释放应该和对象的生命周期绑定，资源不限于内存资源，包括file handles, mutexes, database connections, transactions等。这样确保资源不会泄露，最常见的资源就是内存。

我们分配内存后要判断，内存是否分配成功，失败就结束该程序；其次要注意**野指针/悬垂指针问题（Wild pointer/Dangling pointer）**：指针没有初始化，或者指针free后，没有置NULL。如下一个简单的例子。

``` c
typedef char CStr[100];
...
void foo()
{
  ...
  char* a_string = new CStr;
  ...
  delete a_string;
  return;
}
```

```cpp
void my_func()
{
    int* valuePtr = new int(15);
    int x = 45;
    // ...
    if (x == 45)
        return;   // here we have a memory leak, valuePtr is not deleted
    // ...
    delete valuePtr;
}
 
int main()
{
}
```

当`delete a_string`的时候,就会发生内存泄露，最终内存耗尽（memory exhausted）；

在C++11中，提供了智能指针，其就是基于RAII的思想实现的。

> Smart pointers are used to make sure that an object is deleted if it is no longer used (referenced).

智能指针位于<memory>头文件中，从某种意义上来说，不是一个真的指针，但是重载了 `->` `*` `->*`指针运算符，这使得其表现的像个内建的指针，有以下几种类型：`auto_ptr`, `shared_ptr`,` weak_ptr`,`unique_ptr`。后三个是c++11支持的，第一个已经被弃用了,相应的在boost中也有智能指针，不过现在c++11已经支持了就不用了，比如`boost:scoped_ptr` 类似于 `std:unique_ptr`。

## Smart Pointer

### **unique_ptr**

> 前身是c++98中的auto_ptr，但是这个auto_ptr有很多问题

可用在有限作用域（restricted scope）中动态分配的对象资源。不可复制（copy），但是可以转移（move），转移之后原来的指针无效。

`unique_ptr`很强大，比起使用new创建一个对象，我们可以直接make_unique创建；之后不需要主动delete，当过了生命周期后，在unique_ptr的析构中自动delete目标对象（RAII)。

```cpp
auto a = std::make_unique<MyClass>(); // C++14
auto b = std::unique_ptr<MyClass>(new MyClass());
std::unique_ptr<MyClass> c(new MyClass());
```

那么make_unique有什么优点呢：

+ 首先就是简洁

+ make_unique是异常安全的，如下例，如果第一个new成功了，第二个new失败；那么还没来得及调用unique_ptr的构造，出现异常，新分配的内存泄漏了

  > ```cpp
  > MyFunction(std::unique_ptr<MyClass>(new MyClass()),
  >            std::unique_ptr<MyClass>(new MyClass()));
  > ```

我这这里释放对象通常是指释放内存，然后有些对象有自己的释放逻辑，比如文件句柄，这是可以定义自己的release函数：

```cpp
FILE* file = fopen("...", "r");
auto FILE_releaser = [](FILE* f) { fclose(f); };
std::unique_ptr<FILE, decltype(FILE_releaser)> file_ptr(file, FILE_releaser);
```

最后，使用unique_ptr时，注意不要把一个对象赋给了两个unique_ptr；

### **shared_ptr**

[参考](https://shaharmike.com/cpp/shared-ptr/)

可以复制，维护一个引用计数，当最后一个引用该对象的引用退出，那么才销毁；通常用在私有（private）的类成员变量上，外部通过成员函数获取该成员的引用，如下：

```cpp
#include <memory>
 
class Foo
{
	public void doSomething();
};
 
class Bar
{
private:
	std::shared_ptr<Foo> pFoo;
public:
	Bar()
	{
		pFoo = std::shared_ptr<Foo>(new Foo());
	}
 
	std::shared_ptr<Foo> getFoo()
	{
		return pFoo;
	}
};
```

但是可能带来的问题是 : 

1. 悬垂引用（dangling reference）

``` cpp
// Create the smart pointer on the heap
MyObjectPtr* pp = new MyObjectPtr(new MyObject())
// Hmm, we forgot to destroy the smart pointer,
// because of that, the object is never destroyed!
```

2. 循环引用（circular reference）

``` cpp
struct Owner {
   boost::shared_ptr<Owner> other;
};

boost::shared_ptr<Owner> p1 (new Owner());
boost::shared_ptr<Owner> p2 (new Owner());
p1->other = p2; // p1 references p2
p2->other = p1; // p2 references p1
```

https://stackoverflow.com/questions/18301511/stdshared-ptr-initialization-make-sharedfoo-vs-shared-ptrtnew-foo

### **weak_ptr**

配合`shared_ptr`使用，可避免循环引用的问题。`weak_ptr`不拥有对象，当其需要访问对象时，必须先临时转换成`shared_ptr`，然后再访问，如下例：

```cpp
#include <iostream>
#include <memory>
 
std::weak_ptr<int> gw;
 
void observe()
{
    std::cout << "use_count == " << gw.use_count() << ": ";
    if (auto spt = gw.lock()) {
     // Has to be copied into a shared_ptr before usage
      std::cout << *spt << "\n";
    }
    else {
        std::cout << "gw is expired\n";
    }
}
 
int main()
{
    {
        auto sp = std::make_shared<int>(42);
				gw = sp;
 
				observe();
    }
 
    observe();
}
```

每一个shared_ptr对象内部，拥有两个指针ref_ptr与res_ptr，一个指向引用计数对象，一个指向实际的资源。在shared_ptr的拷贝构造等需要创造出其他拥有相同资源的shared_ptr对象时，会首先增加引用计数，然后将ref_ptr与res_ptr赋值给新对象。发生析构时，减小引用计数，查看是否为0，如果是，则释放res_ptr与ref_ptr。
weak_ptr的引入，我认为是智能指针概念的一个补全。一个裸指针有两种类型：

+ 管理资源的句柄（**拥有对象**），举个🌰，一般我们创建一个对象，在使用完之后销毁，那这个指针是拥有那个对象的，指针的作用域就是这个对象的生命周期，这个指针就是用来管理资源的句柄。
+ 指向一个资源的指针（**不拥有对象**），举个🌰，我们在使用观察者（observer）模式时，被监测对象经常会持有所有observer的指针，以便在有更新时去通知他们，但是他并不拥有那些对象，这类指针就是指向一个资源的指针。

在引入smart_ptr之前，资源的创建与释放都是调用者来做决定，所以一个指针是哪一类，完全由程序员自己控制。但是智能指针引入之后，这个概念就凸显出来。试想，在上述例子中，我们不会容许一个observer对象因为他是某一个对象的观察者就无法被释放。weak_ptr就是第二类指针的实现，他不拥有资源，当需要时，他可以通过lock获得资源的短期使用权。

因此，`weak_ptr`是对裸指针的使用中的不拥有对象的这类场景进行模拟，当需要访问的时候借助升级为shared_ptr并lock进行访问；举个🌰，在连接超时释放的场景中([http://kernelmaker.github.io/TimingWheel])，用一个固定大小的数据维护最近N秒的连接，其中数组元素都是shared_ptr，在连接对象`Conn`中维护了weak_ptr（这里的场景就是不拥有对象，而只是观察对象的状态）；当有了新的请求，那么需要移动Conn的槽位，那么，首先将weak_ptr升级为一个shared_ptr，然后放到相应槽位中；这样在释放旧连接时，如果之前发生过拷贝，那么相应shared_ptr释放的时候，不会释放真正的连接对象。

## 内存检查工具

- 静态检查：目前了解的有两种主要的[Address Sanitizer和Valgrind](https://stackoverflow.com/questions/47251533/memory-address-sanitizer-vs-valgrind)。
- 内存监控：jemalloc的jeprof