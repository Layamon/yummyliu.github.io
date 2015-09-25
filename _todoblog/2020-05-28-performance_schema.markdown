---
layout: post
title: 
date: 2020-05-28 11:43
categories:
  -
typora-root-url: ../../layamon.github.io
---
> * TOC
{:toc}



select * from setup_instruments



共12张系统表，分成4类，每3类三张

For wait, stage, statement, and transaction events, the Performance Schema can monitor and store current events. In addition, when events end, the Performance Schema can store them in history tables. For each event type, the Performance Schema uses three tables for storing current and historical events. The tables have names of the following forms, where *`xxx`* indicates the event type (`waits`, `stages`, `statements`, `transactions`):

- `events_*`xxx`*_current`: The “current events” table stores the current monitored event for each thread (one row per thread).
- `events_*`xxx`*_history`: The “recent history” table stores the most recent events that have ended per thread (up to a maximum number of rows per thread).
- `events_*`xxx`*_history_long`: The “long history” table stores the most recent events that have ended globally (across all threads, up to a maximum number of rows per table).