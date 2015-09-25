---
layout: post
title: LRUcache的C++实现
date: 2016-08-26 16:00
header-img: "img/head.jpg"
categories: 
    - datastruct
---


> 最近面试了某家公司，提出了手写实现LRUcache的题目，当时并没有手写出来，只是给出了HashMap+DoubleLinkedList的思路
> 实现起来还是有很多细节需要注意的，特别是双向链表实现的时候，注意指针的问题
> 另外，c++中List就是实现的双向链表，但是要和HashMap结合，HashMap需要索引到链表节点


代码如下:

``` cpp
#include <iostream>
#include <map>
using namespace std;

class Node
{
public:
    int key;
    int value;
    Node* pre;
    Node* nxt;
    Node(int key,int value):key(key),value(value)
    {
    }
};

class List
{
private:
	size_t size;
public:

    Node* head;
    Node* tail;

    List()
    {
        head = nullptr;
        tail = nullptr;
        size = 0;
    }

    int pop_back()
    {
        if (size==0) {
            return -1;
        }
        int key = tail->key;
        Node* tmp = tail;
        tail = tail->pre;
        if(tail!=nullptr)
            tail->nxt = nullptr;
        free(tmp);
        size--;
        return key;
    }

    void push_front(Node* newnode)
    {
        if (size==0)
        {
            newnode->nxt = nullptr;
            newnode->pre = nullptr;
			head=newnode;
			tail=newnode;
        }
        else
        {
            newnode->nxt = head;
            head->pre = newnode;
            newnode->pre = nullptr;
            head = newnode;
        }
        size++;
    }

    void behead(Node* node)
    {
        if (node == head)
            return;
        if (node == tail)
        {
            tail = node->pre;
            tail->nxt = nullptr;
        }
        else
        {
            node->pre->nxt = node->nxt;
            node->nxt->pre = node->pre;
        }

        head->pre = node;
        node->nxt = head;
        node->pre = nullptr;
        head = node;
    }
};

class LRUCache
{

public:
    size_t capacity;
    size_t length;

    List *nodes;
    multimap<int,Node*> cache;

    LRUCache(int capacity):capacity(capacity)
    {
        length = 0;
        nodes = new List();
    }

    int get(int key)
    {
        auto ite = cache.find(key);
        if (ite == cache.end()) {
            // cache miss
            return -1;
        }

        // cache hit
        nodes->behead(ite->second);

        return ite->second->value;
    }

    void set(int key, int value)
    {
        auto ite = cache.find(key);
        if(ite==cache.end())
        {
            // cache miss
            if (capacity == length) {
                // cache full
                int k = nodes->pop_back();
                cache.erase(cache.find(k));
                length--;
            }

            Node *newnode = new Node(key,value);
            nodes->push_front(newnode);
            cache.insert(make_pair(key, newnode));
            length++;
        }
        else
        {
            // cache hit
            ite->second->value = value;
            nodes->behead(ite->second);
        }
    }
};

int main()
{
    LRUCache ch(2);
    cout << ch.get(2) <<endl;
    ch.set(2, 6);
    cout << ch.get(1) <<endl;
    ch.set(1, 5);
    ch.set(1, 2);
    cout << ch.get(1) <<endl;
    cout << ch.get(2) <<endl;

    return 0;
}
```
