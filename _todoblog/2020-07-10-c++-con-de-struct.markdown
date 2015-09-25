---
layout: post
title: ctor&dtor in C++
date: 2020-07-10 13:31
categories:
  - C++
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}

rule3/5/0

https://en.cppreference.com/w/cpp/language/rule_of_three



![image-20201028091836207](/image/modern-c++/move-forward.png)

# 右值引用(C++11)

在C++11标准中吗，添加了新的构造函数类型——移动构造函数；其参数为一个**右值引用**类型，如下：

```cpp
class BigObj1 {
public:
  BigObj1(BigObj1 && b1):
  c(b1.c)
  {
    b1.c = nullptr;
  }
  
  int* c;
}
```

而什么是右值呢？值类型的分为左值和右值，广泛被认可的说法是**可以取地址的、有名字**的就是左值；**不能取地址、没有名字**的就是右值。

![image-20200210101826672](/image/cpp-memo/20200210-c++11value.png)

> 关于左值和右值具体的判断很难归纳，就算归纳了也需要大量的解释。

由于右值通常没有名字，在C++11中，通过**右值引用**（加一个别名）来找到他的存在；区别于常规引用（左值引用），用`&&`来标识，如下：

```c++
T && a = returnRvalue();
```

右值引用和左值引用都属于引用，只是一个别名，其不拥有绑定对象的内存，不存在拷贝的开销；只不过一个具名对象的别名，一个时匿名对象的别名。

> 值得注意的是，右值引用是C++11标准的；在C++98中，左值引用无法引用右值的，而**常量左值引用**是一个万能的引用类型，如下编译是没有问题的，但是之后该变量只能是只读的。
>
> ```cpp
> const T & a = returnRvalue();
> ```
>
> 这样在C++98中，通常我们使用常量引用类型作为函数参数，可以避免函数传递右值时的析构构造代价，如下：
>
> ```cpp
> void func(const T & a){
> 	// do something
> }
> func(returnRvalue());
> ```

使用右值引用的一个好处是将本将要消亡（返回值在函数结束后，过了自己的生命期，这就是一种**亡值**）的变量重获新生，并且相比于`T a = returnRvalue();`，少了重新析构与构造的代价，如下直接使用右值引用作为参数：

```c++
void func(T && a){
	// do something
}
func(returnRvalue());
```

## std::move

该函数可认为是一个强制类型转换（`static_cast<T&&>()`），将左值转换为右值。move结合移动构造函数可以应用在即将消亡的大对象的移动中，如下：

```c++
class ResouceManager {
public:
  ResourceManager(ResourceManager && r):
  b1(std::move(r.b1)),
  b2(std::move(r.b2))
  {
    // ...
  }
  BigObj1 b1;
  BigObj2 b2;
}

ResouceManager gettemp() {
  ResouceManger tmp;
  // ...
  return tmp;
}

int main() {
  ResourceManager r(gettemp());
}
```

在gettemp返回时，本来即将消亡了ResourceManager通过ResourceManager的移动构造函数转移给了新的ResourceManager对象，而原ResourceManager中的成员变量通过std::move强制转换为右值引用，同样通过相应的移动构造函数进行了移动。

> NOTE: 在程序中，如果我们确定某个对象将要放弃其拥有的资源，通过`std::move`将其变成右值，从而可以调用移动构造函数进行资源转移。

**这样通过std::move保证了移动语义向成员变量的传递**；因此，在编写类的移动构造函数时，注意使用std::move来转换资源类型的成员变量，比如堆内存，文件句柄等。

在C++11中，会有默认的拷贝构造函数和移动构造函数，如果需要自己实现的话，拷贝构造函数和移动构造函数必须要一起提供，否则就只有一种语义。

> 一般来说，很少有类只有一种语义，而智能指针里的`unique_ptr`确实就只有一种语义，由于其没有拷贝的语义，导致之前不能将unique_ptr放到vector中，因为vector扩展的时候需要拷贝其中的对象。
>
> 而C++11有了移动语义，那么vector可以直接使用移动的方式扩展，这时就可以将unique_ptr放在vector中了，大大方便的编程。

另外，为保证移动的过程中不会因为抛出异常而中断，可在移动构造上加一个`noexcept`关键字，并使用std::move_if_noexcept，当有except时，降级为拷贝构造函数，这是一种牺牲性能保证安全的做法。

> 关于返回值，值得注意的是，编译器会默认进行返回值的优化（Return Value Optimization）：
>
> 优化的方式就是直接在callee需要返回的temp var直接使用caller func的栈中的对象，那么就不用拷贝了；但是要注意在某些case下RVO是用不了的，比如caller无法确定callee要返回哪个temp。
>
> ```cpp
> -fno-elide-constructors
>  The C++ standard allows an implementation to omit creating a
>  temporary which is only used to initialize another object of the
>  same type.  Specifying this option disables that optimization, and
>  forces G++ to call the copy constructor in all cases.
> ```

## **std::forward**

用在函数模板中，实现转发语义。具体实现上和move类似，起个不同的名字用在不同的场景中，方便以后扩展。

> **引用折叠**
>
> 在C++11中，引入了一个右值引用，那么在传递参数的时候，会面临引用重叠的问题，比如以下例子在c++98中无法编译通过：
>
> ```c++
> typedef const int T;
> typedef T& TR;
> TR& v = 1; // compiling error
> ```
>
> 在c++11中，通过引入了引用折叠规则，避免这个问题；总结来说，当引用重叠时，只要其中有左值引用，那么优先转换为左值引用

在函数模板的推导中，如果实参为左值引用，那么就推导为一个左值引用参数的函数；如果实参是右值引用，那么就转发为一个右值引用的函数。因此，对于一个转发函数模板，我们将参数定义为右值引用类型，这样左值和右值传递都没有问题。