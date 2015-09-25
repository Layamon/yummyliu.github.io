---
layout: post
title: Effective Modern C++ 小结
date: 2020-10-26 13:54
categories:
  - C++
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
Most Vexing Parse

*everything that can be interpreted as a declaration, will be interpreted as a declaration"* rather than *"everything that can be interpreted as a declaration, will be interpreted as a declaration, unless it's a single variable definition, in which case it's a variable definition"*.



Coding style is ultimately subjective, and it is highly unlikely that substantial performance benefits will come from it. But here's what I would say that you gain from liberal use of uniform initialization:

## Minimizes Redundant Typenames

Consider the following:

```cpp
vec3 GetValue()
{
  return vec3(x, y, z);
}
```

Why do I need to type `vec3` twice? Is there a point to that? The compiler knows good and well what the function returns. Why can't I just say, "call the constructor of what I return with these values and return it?" With uniform initialization, I can:

```cpp
vec3 GetValue()
{
  return {x, y, z};
}
```

Everything works.

Even better is for function arguments. Consider this:

```cpp
void DoSomething(const std::string &str);

DoSomething("A string.");
```

That works without having to type a typename, because `std::string` knows how to build itself from a `const char*` implicitly. That's great. But what if that string came from, say RapidXML. Or a Lua string. That is, let's say I actually know the length of the string up front. The `std::string` constructor that takes a `const char*` will have to take the length of the string if I just pass a `const char*`.

There is an overload that takes a length explicitly though. But to use it, I'd have to do this: `DoSomething(std::string(strValue, strLen))`. Why have the extra typename in there? The compiler knows what the type is. Just like with `auto`, we can avoid having extra typenames:

```cpp
DoSomething({strValue, strLen});
```

It just works. No typenames, no fuss, nothing. The compiler does its job, the code is shorter, and everyone's happy.

Granted, there are arguments to be made that the first version (`DoSomething(std::string(strValue, strLen))`) is more legible. That is, it's obvious what's going on and who's doing what. That is true, to an extent; understanding the uniform initialization-based code requires looking at the function prototype. This is the same reason why some say you should never pass parameters by non-const reference: so that you can see at the call site if a value is being modified.

But the same could be said for `auto`; knowing what you get from `auto v = GetSomething();` requires looking at the definition of `GetSomething`. But that hasn't stopped `auto` from being used with near reckless abandon once you have access to it. Personally, I think it'll be fine once you get used to it. Especially with a good IDE.

## Never Get The Most Vexing Parse

Here's some code.

```cpp
class Bar;

void Func()
{
  int foo(Bar());
}
```

Pop quiz: what is `foo`? If you answered "a variable", you're wrong. It's actually the prototype of a function that takes as its parameter a function that returns a `Bar`, and the `foo` function's return value is an int.

This is called C++'s "Most Vexing Parse" because it makes absolutely no sense to a human being. But the rules of C++ sadly require this: if it can possibly be interpreted as a function prototype, then it *will* be. The problem is `Bar()`; that could be one of two things. It could be a type named `Bar`, which means that it is creating a temporary. Or it could be a function that takes no parameters and returns a `Bar`.

Uniform initialization cannot be interpreted as a function prototype:

```cpp
class Bar;

void Func()
{
  int foo{Bar{}};
}
```

`Bar{}` always creates a temporary. `int foo{...}` always creates a variable.

There are many cases where you want to use `Typename()` but simply can't because of C++'s parsing rules. With `Typename{}`, there is no ambiguity.

注意区分 std::vector<int> v{100}; 

https://softwareengineering.stackexchange.com/questions/133688/is-c11-uniform-initialization-a-replacement-for-the-old-style-syntax

