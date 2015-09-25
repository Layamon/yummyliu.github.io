---
layout: post
title: 
date: 2021-06-11 11:35
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
在CPU上运行的二级制代码，可看作基于汇编命令来对各个寄存器和Memory进行计算与存储。在目前X86(64)架构中的多种寄存器都是从一开始的16bit寄存器发展而来的，如下图（在后来位宽变成32时，在之前加上'**E**'，以及后来的64位宽的寄存器，加上'R'）。

<img src="/image/assemble/register.png" alt="image-20210611173204022" style="zoom: 33%;" />

目前的CPU不只有上图这些寄存器，还有一些其他寄存器，比如pc（又叫ip，即 instruction pointer）、floating point相关等；另外在目前的架构还增加了R8,R9,R10等通用寄存器。

可以看出来寄存器分为general 和 special两类；能对special中的BP，SP，IP有足够的了解，基本就能了解程序是如何运行的。本文基于gdb调试着看一下如下示例代码是如何运行的。

```c++
struct BigType128 {
  uint64_t a;
  uint64_t b;
};

struct BigType156 {
  uint64_t a;
  uint64_t b;
  uint64_t c;
};

uint64_t foo(uint64_t x, BigType128 a, BigType156 b, uint64_t &c, uint32_t y,
             uint32_t *z, uint64_t l) {
  uint64_t local_var = 1;
  char local_array[10] = "123456789";
  static int static_var = -1;
  static_var += 1;
  static char static_array[] = "asdf";
  a.a++;
  c++;
  l++;
  (*z)++;
  return local_var + static_var;
}

int main() {
  uint64_t c = 0x4444444444444444;
  uint32_t z = 0x66666666;
  auto a = foo(0x1111111111111111, {0x2222222222222222, 0x2222222222222222},
               {0x3333333333333333, 0x3333333333333333, 0x3333333333333333}, c,
               0x55555555, &z, 0x7777777777777777);
  return 0;
}
```

我们在foo函数上加断点，看一下程序运行时相关的寄存器情况：

```assembly
(gdb) i r
rax            0x2222222222222222       2459565876494606882
rbx            0x0      0
rcx            0x7fffffffdf28   140737488346920
rdx            0x2222222222222222       2459565876494606882
rsi            0x2222222222222222       2459565876494606882
rdi            0x1111111111111111       1229782938247303441
rbp            0x7fffffffdef0   0x7fffffffdef0
rsp            0x7fffffffdef0   0x7fffffffdef0
r8             0x55555555       1431655765
r9             0x7fffffffdf24   140737488346916
r10            0x73     115
r11            0x1c     28
r12            0x5555555593d0   93824992252880
r13            0x7fffffffe030   140737488347184
r14            0x0      0
r15            0x0      0
rip            0x555555559525   0x555555559525 <foo(unsigned long, BigType128, BigType156, unsigned long&, unsigned int, unsigned int*, unsigned long)+37>
eflags         0x202    [ IF ]
cs             0x33     51
ss             0x2b     43
ds             0x0      0
es             0x0      0
fs             0x0      0
gs             0x0      0
```

这里我故意设置了7个参数，由于rdi、rsi、rdx、rcx、r8、r9通常用来进行参数传递，但是每个寄存器只有8B，这里我增加了两个大类型，可以发现rsi、rdx共同完成一个参数的传递；而对于引用类型其实就是传递了一个地址；而没有通过寄存器传递的参数去哪了呢？就得看具体的函数汇编代码了；在看具体代码前，先有个基本的认识：CPU通过PC寄存器一条条的读取指令执行，执行的的指令中如果有func call，那么就需要进出栈，栈中都是操作的对象数据；而通过两个寄存器保存了栈的状态，rsp（当前的栈顶）与rbp（当前的栈底）。

```assembly
(gdb) disassemble /s
Dump of assembler code for function foo(unsigned long, BigType128, BigType156, unsigned long&, unsigned int, unsigned int*, unsigned long):
/data00/liuyangming/GoofDB/tools/mytest/mytest.cc:
22                   uint32_t *z, uint64_t l) {
   0x0000555555559500 <+0>:     push   %rbp # 将前一个rbp保存在栈内，rsp+8；
   0x0000555555559501 <+1>:     mov    %rsp,%rbp # 然后设置新的rbp；
   0x0000555555559504 <+4>:     mov    %rdi,-0x28(%rbp) # 第一个参数压栈
   0x0000555555559508 <+8>:     mov    %rsi,%rax # v 以下是第二个参数压栈
   0x000055555555950b <+11>:    mov    %rdx,%rsi
   0x000055555555950e <+14>:    mov    %rsi,%rdx
   0x0000555555559511 <+17>:    mov    %rax,-0x40(%rbp) 
   0x0000555555559515 <+21>:    mov    %rdx,-0x38(%rbp) # ^
   0x0000555555559519 <+25>:    mov    %rcx,-0x30(%rbp) # 第三个
   0x000055555555951d <+29>:    mov    %r8d,-0x44(%rbp) # 第四个
   0x0000555555559521 <+33>:    mov    %r9,-0x50(%rbp) # 第五个

23        uint64_t local_var = 1;
=> 0x0000555555559525 <+37>:    movq   $0x1,-0x8(%rbp) #给出了将要执行的下一条指令，即局部变量赋值1；

24        char local_array[10] = "123456789";
   0x000055555555952d <+45>:    movabs $0x3837363534333231,%rax
   0x0000555555559537 <+55>:    mov    %rax,-0x12(%rbp)
   0x000055555555953b <+59>:    movw   $0x39,-0xa(%rbp)

25        static int static_var = -1;
26        static_var += 1;
   0x0000555555559541 <+65>:    mov    0x265fe9(%rip),%eax        # 0x5555557bf530 <_ZZ3foom10BigType12810BigType156RmjPjmE10static_var>
   0x0000555555559547 <+71>:    add    $0x1,%eax
   0x000055555555954a <+74>:    mov    %eax,0x265fe0(%rip)        # 0x5555557bf530 <_ZZ3foom10BigType12810BigType156RmjPjmE10static_var>

27        static char static_array[] = "asdf";
28        a.a++;
   0x0000555555559550 <+80>:    mov    -0x40(%rbp),%rax
   0x0000555555559554 <+84>:    add    $0x1,%rax
   0x0000555555559558 <+88>:    mov    %rax,-0x40(%rbp)

29        c++;
   0x000055555555955c <+92>:    mov    -0x30(%rbp),%rax
   0x0000555555559560 <+96>:    mov    (%rax),%rax
   0x0000555555559563 <+99>:    lea    0x1(%rax),%rdx
   0x0000555555559567 <+103>:   mov    -0x30(%rbp),%rax
   0x000055555555956b <+107>:   mov    %rdx,(%rax)

30        l++;
   0x000055555555956e <+110>:   addq   $0x1,0x28(%rbp)

31        (*z)++;
   0x0000555555559573 <+115>:   mov    -0x50(%rbp),%rax
   0x0000555555559577 <+119>:   mov    (%rax),%eax
   0x0000555555559579 <+121>:   lea    0x1(%rax),%edx
   0x000055555555957c <+124>:   mov    -0x50(%rbp),%rax
   0x0000555555559580 <+128>:   mov    %edx,(%rax)

32        return local_var + static_var;
   0x0000555555559582 <+130>:   mov    0x265fa8(%rip),%eax        # 0x5555557bf530 <_ZZ3foom10BigType12810BigType156RmjPjmE10static_var>
   0x0000555555559588 <+136>:   movslq %eax,%rdx
   0x000055555555958b <+139>:   mov    -0x8(%rbp),%rax
   0x000055555555958f <+143>:   add    %rdx,%rax

33      }
   0x0000555555559592 <+146>:   pop    %rbp
   0x0000555555559593 <+147>:   retq   
End of assembler dump.
```

从函数的汇编代码中，我关注了这几个信息，如上注释：

- rsp与rbp的变化
- pc（ip）寄存器的值
- 各种类型变量的地址：
- 引用与指针类型的访问方式





目前系统上的


```assembly
(gdb) disassemble 
Dump of assembler code for function foo():
   0x0000555555559500 <+0>:     push   %rbp # 存下旧的stack base pointer
   0x0000555555559501 <+1>:     mov    %rsp,%rbp # 将rbp设置为新的rsp， 这样rbp只想当前函数foo的栈底
=> 0x0000555555559504 <+4>:     movl   $0x0,-0x4(%rbp) # 访存 -0x4(%rbp) <=> %rbp + -0x4,指向第一个local var，即a，如下
   0x000055555555950b <+11>:    addl   $0x1,-0x4(%rbp)
   0x000055555555950f <+15>:    mov    -0x4(%rbp),%eax # x86规定 eax寄存器存储返回值
   0x0000555555559512 <+18>:    pop    %rbp
   0x0000555555559513 <+19>:    retq   
End of assembler dump.
```



> ```
> (gdb) x $rbp -4
> 0x7fffffffdf3c: 0x00005555
> (gdb) x &a
> 0x7fffffffdf3c: 0x00005555
> ```



> `mov dest, src` is called **[Intel syntax](https://stackoverflow.com/tags/intel-syntax/info)**. (e.g. `mov eax, 123`)
>
> `mov src, dest` is called **[AT&T syntax](https://stackoverflow.com/tags/att/info)**. (e.g. `mov $123, %eax`)
>
> UNIX assemblers including the GNU assembler uses AT&T syntax, all other x86 assemblers I know of uses Intel syntax. You can read up on the differences [on wikipedia](http://en.wikipedia.org/wiki/X86_assembly_language#Syntax).

![img](/image/assemble/x64_frame_nonleaf.png)

```c++
long myfunc(long a, long b, long c, long d,
            long e, long f, long g, long h)
{
    long xx = a * b * c * d * e * f * g * h;
    long yy = a + b + c + d + e + f + g + h;
    long zz = utilfunc(xx, yy, xx % yy);
    return zz + 20;
}
```

