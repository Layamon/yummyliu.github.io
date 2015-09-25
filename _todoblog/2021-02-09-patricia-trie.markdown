---
layout: post
title: 
date: 2021-02-09 10:38
categories:
  -
typora-root-url: ../../layamon.github.io
---
* TOC
{:toc}
# Radix Trie

- Space Optimization：基于bit级别的radix的bitwise的比较，这样child就不需要存储Extend Ascii的256个字符，或者Unicode的65000个字符。
- Parent/Child的合并：Child中只需要存储于Parent不同的bits。

# Adaptive Radix Trie

> Practical Algorithm to Retrieve Information Coded in Alphanumeric

- Each node (TWIN is the original PATRICIA’s term) has two children (*r = 2* and *x = 1* in Radix Trie terms*)*;
- A node is only splitted into a prefix (L-PHRASE in PATRICIA’s terms) with two children (each child forming a BRANCH which is PATRICIA’s original term) if two words (PROPER OCCURRENCE in PATRICIA’s terms) share the same prefix; and
- Every word ending will be represented with a value within the node different than null (END mark in PATRICIA’s original nomenclature)

