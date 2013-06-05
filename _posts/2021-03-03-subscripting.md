---
layout: post
title:  "How many engineers does it take to make subscripting work?"
date:   2021-03-03 09:12:45
comments: true
tags: [PostgreSQL, Jsonb]
overview: "Recently landed in PostgreSQL, jsonb subscripting support doesn't
look as exciting as some other improvements around jsonb. But it's user visible
changes are only tip of the iceberg. How many people were involved to make it,
and what decisions choices were made? How long did it take, and what are the
good/bad ideas to work on a patch?"
---

Are you tired of this syntax in PostgreSQL?

```sql
SELECT jsonb_column->'key' FROM table;
UPDATE table SET jsonb_column =
            jsonb_set(jsonb_column, '{"key"}', '"value"');
```

The select part is actually fine. But for updates, especially for complex
updates, it could be pretty verbose and far from being ergonomic. What would
you say to this syntax instead?

```sql
SELECT jsonb_column['key'] FROM table;
UPDATE table SET jsonb_column['key'] = '"value"';
```

<!--break-->

With subscripting it looks more concise and probably even familiar for
developers due to its "pythonic" style. If you like this syntax more I have
good news for you, recently a [patch][jsonb_subscripting_commit] implementing
this functionality landed in PostgreSQL:

```
commit 676887a3b0b8e3c0348ac3f82ab0d16e9a24bd43
Author: Alexander Korotkov
Date:   Sun Jan 31 23:50:40 2021 +0300

Implementation of subscripting for jsonb
...
Author: Dmitry Dolgov
Reviewed-by: Tom Lane, Arthur Zakirov, Pavel Stehule, Dian M Fay
Reviewed-by: Andrew Dunstan, Chapman Flack, Merlin Moncure
Reviewed-by: Peter Geoghegan, Alvaro Herrera, Jim Nasby
Reviewed-by: Josh Berkus, Victor Wagner, Aleksander Alekseev
Reviewed-by: Robert Haas, Oleg Bartunov
```

So hopefully in PostgreSQL 14 you would be able to use it. Theoretically I
could finish writing at this point and it would be the shortest blog post I've
ever written.

# The end?

But do you see anything strange in the commit mentioned above? From a user
point of view this change is probably not the most exciting one, then why so
untypical many people were involved in the development? Let's try to find out
and for that we need to explore the development timeline of this patch and how
it's design changed over this time.

Originally Oleg Bartunov shared with me an interesting idea:

<img src="/public/img/bartunov.png" border="0" width="80%" style="margin: auto">

Long story short, after some time I've posted a PoC patch in hackers:

```
From: Dmitry Dolgov
Date: Tue, 18 Aug 2015 00:57:48 +0700
Subject: jsonb array-style subscripting
To: PostgreSQL-development <pgsql-hackers@postgresql.org>

Hi,

Some time ago the array-style subscripting for the jsonb data type
was discussed in this mailing list. I think it will be quite
convenient to have a such nice syntax to update jsonb objects,
so I'm trying to implement this. I created a patch, that allows
doing something like this:
```

First thing to notice is the date, it happened sooo long time ago! To give you
an impression, in this time scientists have discovered gravitational waves,
confirmed several properties of Higgs boson predicted by Standard Model, Magnus
Carlsen managed to defend his World Chess Champion title two times, and AC/DC
have released a new album.

This version of patch had dead-simple design, it was just extending the
existing array subscripting implementation to understand jsonb data type. But
it was good enough to start the discussion and in fact all the important use
cases were working. Feedback from the community was mostly positive, it was
clear that this feature is useful. But the design of course had to be improved,
and there were even suggestions about making it so generic that any arbitrary
data type could use such functionality.

# In search for extensibility

Indeed, that was an interesting idea, and based in this feedback I've written a
new more generic implementation. The trick was to extend `pg_type` with a new
field `typsubscript`:

```
                   Table "pg_catalog.pg_type"
     Column     |     Type     | Collation | Nullable | Default
----------------+--------------+-----------+----------+---------
...
 typrelid       | oid          |           | not null |
 typsubscript   | regproc      |           | not null |
 typelem        | oid          |           | not null |
...
```

This column contains a function which would be an entry point for every custom
subscripting implementation. This function must construct and return a
structure describing how subscripting would work for this particular data type:

```c
/* Execution step methods used for SubscriptingRef */
typedef struct SubscriptExecSteps
{
	/* process subscripts */
	ExecEvalBoolSubroutine sbs_check_subscripts;
	/* fetch an element */
	ExecEvalSubroutine sbs_fetch;
	/* assign to an element */
	ExecEvalSubroutine sbs_assign;
	/* fetch old value for assignment */
	ExecEvalSubroutine sbs_fetch_old;
} SubscriptExecSteps;
```

Following this interface an extension developer can implement subscripting
support for any custom data type. Of course on top of that there was a
structure containing necessary state:

```c
typedef struct SubscriptingRef
{
	/* type of the container proper */
	Oid		 refcontainertype;
	/* the container type's pg_type.typelem */
	Oid		 refelemtype;
	...
	/* expressions that evaluate to container indexes */
	List		*refupperindexpr;
	List		*reflowerindexpr;
	...
} SubscriptingRef;
```

These structures are coming from the latest committed version, the original
ones were a bit different, but followed the same idea. Having this at hand
you're free to implement whatever is needed.

This version was pretty good in many ways, but had one significant flaw -- it
was simply big and rather invasive from the code point of view. This of course
caused reluctance from anyone to review it. I've even tried to clean dust from
my sense of humour and add something catchy into commentaries:

```c
/*
 * Perform preparation for the jsonb subscripting. This
 * function produces an expression that represents the
 * result of extracting a single container element or
 * the new container value with the source data inserted
 * into the right part of the container. If you have read
 * until this point, and will submit a meaningful review
 * of this patch series, I'll owe you a beer at the next
 * PGConfEU.
 */
```

Fortunately after some time the patch picked up again some activity.

<img src="/public/img/array-slow-down.png" border="0" width="80%" style="margin: auto">

One of the obvious concerns was performance influence on arrays, as array
subscripting now goes through the same generic mechanism. Theoretically it
should not be a problem, because the only change is an extra function call, but
still it had to be proved. It turns out that the original implementation had
about 2% slowdown for arrays, and as a side note I wanted to emphasize one
interesting point -- if you do any performance testing with PostgreSQL, do not
forget to disable `--enable-cassert` which you have to use for development.
It's interesting that most of the overhead comes in this case not from the
asserts themselves, but from memory checks that are enabled together with
asserts:

```c
/*
 * Define this to check memory allocation errors (scribbling on more
 * bytes than were allocated).  Right now, this gets defined
 * automatically if --enable-cassert or USE_VALGRIND.
 */
#if defined(USE_ASSERT_CHECKING) || defined(USE_VALGRIND)
#define MEMORY_CONTEXT_CHECKING
#endif
```

If you're like me curious enough, checking the difference between PostgreSQL
compiled with and without asserts you can see that significant part of the
overhead could be attributed to this:

```
$ perf diff no-cassert.data cassert.data
    ...
    18.86%             postgres            [.] AllocSetCheck
    12.07%             postgres            [.] sentinel_ok
    ...
```

Returning to the original topic, why I like PostgreSQL community is that it's
always not enough. In this particular case it turns out one could shave off a
bit more from the overhead (by reducing some intermediate calls, what was
discovered and done by Tom Lane) and make it even more generic! The latter one
could be achieved via adding more flexibility to the structures containing
subscripting state so that it also can contain some opaque custom data.
`SubscriptingRef` has to be fixed, because it's a planner node and could be
sent to other workers, so the only possibility for that is
at execution step with `SubscriptingRefState`:

```c
typedef struct SubscriptingRefState
{
	/* workspace for type-specific subscripting code */
	void		*workspace;
	/* filled at expression compile and runtime time */
	int		 numupper;
	bool		*upperprovided;
	Datum		*upperindex;
	bool		*upperindexnull;
	...
	/* sbs_fetch_old puts old value here */
	Datum		 prevvalue;
	bool		 prevnull;
} SubscriptingRefState;
```

Now together with other fields containing already known information there is a
`workspace` which could be used to store anything you need between different
stages.

# Further improvements

Of course all of this doesn't solve the problem of size and invasiveness. One
way to solve it was obvious to split the patch into small(-ish) chunks to make
everything more digestible. Another idea I find interesting came on the fly and
I would like to put in into unexpected perspective. In chess there is an old
wisdom called "The principle of two files" which says that the inferior side
may be able to defend a position with one weakness, but a second weakness on
the other side of the board will prove fatal. Broadly speaking one could apply
this to pretty much anything, e.g. if your invasive patch instead of just one
thing does couple of improvements it's always better. Something similar
happened in this case, when Tom used this opportunity to do some refactoring
within the array type itself:

```
commit c7aba7c14efdbd9fc1bb44b4cb83bedee0c6a6fc
Author: Tom Lane <tgl@sss.pgh.pa.us>
Date:   Wed Dec 9 12:40:37 2020 -0500

One useful side-effect of this is that we now have a less squishy
mechanism for identifying whether a data type is a "true" array:
instead of wiring in weird rules about typlen, we can look to see
if pg_type.typsubscript == F_ARRAY_SUBSCRIPT_HANDLER.
```

Somewhat similar happened with hstore data type, which acquired subscripting
functionality as a sort of side effect to test this code even more and provide
a simple example of implementing subscripting in an extension.

Another interesting suggestion from Pavel Stehule was about taking this chance
to improve jsonb user interface as well:

<img src="/public/img/stehule.png" border="0" width="80%" style="margin: auto">

The idea was to smooth some corner cases that were bothering developers in the
past. Here are couple of examples:

```sql
-- Where jsonb_field was NULL, it is now {"a": 1}
-- For jsonb_set it will be NULL
UPDATE table_name SET jsonb_field['a'] = '1';

-- Where jsonb_field was [], it is now [null, null, 2];
-- For jsonb_set it will be [2].
-- For negative indexes it will return an out of range error.
UPDATE table_name SET jsonb_field[2] = '2';

-- Where jsonb_field was {}, it is now {'a': [{'b': 1}]}
-- For jsonb_set it will be {}
UPDATE table_name SET jsonb_field['a'][0]['b'] = '1';

-- An exception from the previous case.
-- This will raise an error if any record's
-- jsonb_field['a']['b'] is something other than
-- an object. For example, the value {"a": 1}
-- has no 'b' key.
UPDATE table_name SET jsonb['a']['b']['c'] = '1';
```

In fact, I was originally hesitant to do this. My plan for this version of the
patch was to function exactly as jsonb_set, and then implement any subsequent
improvements separately. But eventually I've changed my mind and it turns out
to be a good idea.

# Types questions

One of the questions about this functionality I've seen was regarding assign
value -- why should it be of jsonb type?

```sql
-- Update object value by key. Note the quotes
-- around '1': -- the assigned value must be
-- of the jsonb type as well
UPDATE table_name SET jsonb_field['key'] = '1';
```

Why it couldn't be simply like this, which is probably more intuitive?

```sql
UPDATE table_name SET jsonb_field['key'] = 1;
```

Well, in fact originally it was exactly like this. But after extensive
discussions it turns out that it's not the best idea. To quote
[Tom][type_email]:

```
The background for my being so down on this is that it reminds me
way too much of the implicit-casts-to-text mess that we cleaned up
(with great pain and squawking) back around 8.3.  It looks to me
like you're basically trying to introduce multiple implicit casts
to jsonb, and I'm afraid that's just as bad an idea.
```

So, `jsonb_set` function was fine in this case because it was processing jsonb
into another jsonb, and for subscripting to keep everything sane it had to work
similarly. Hence, assigned value has to be jsonb as well.

Another similar type question was about how to handle different types as
subscripting argument? In particular Alexander Korotkov was interested in
jsonpath support.

<img src="/public/img/korotkov.png" border="0" width="80%" style="margin: auto">

Essentially the patch already could do this:

```sql
-- Extract object value by key
SELECT ('{"a": 1}'::jsonb)['a'];

-- Extract array element by index
SELECT ('[1, "2", null]'::jsonb)[1];
```

The question was if it would be possible in the future to do this?

```sql
-- How to support jsonpath?
SELECT ('{"a": {"b": 1}}'::jsonb)['$.a'];
```

Again after some discussion we've found out that it would be not enough just
check which data type was received as an argument, because it will lead to
subtle differences between different data types. The solution was to look at
overloaded functions, and following this example the implementation should
check whether the subscript expression can be implicitly coerced to either of
the supported data types, and fail if neither coercion nor both coercions
succeed. In this way we could have a sound design, although things like this
would not work any more:

```sql
SELECT ('[1, "2", null]'::jsonb)[1.0];
```

Another development in this area was proposed by Nikita Glukhov:

<img src="/public/img/glukhov.png" border="0" width="80%" style="margin: auto">

This suggestion was about making subscripting work more similar to the
corresponding part of jsonpath specification and in top of that adding some
performance improvements for integer use case. Unfortunately this part had to
be reworked and eventually got lost on the way.

# The end?

Now we finally have reached the starting point of this blog post, the commit
with the jsonb subscripting functionality. Was it the end of the story? Well,
not really. Right after the commit couple of buildfarm members started to show
this type of error:

```
=== stack trace: pgsql.build/src/test/regress/tmp_check/data/core ===
[New LWP 2266507]
[Thread debugging using libthread_db enabled]
Using host libthread_db library "/lib/sparc64-linux-gnu/libthread_db.so.1".
Core was generated by `postgres: nm regression [local] SELECT
Program terminated with signal SIGILL, Illegal instruction.
#0  0x000001000075c410 in jsonb_subscript_check_subscripts
```

It turns out that one part of the implementation was producing a misaligned
memory access which was making some architectures upset. It was fixed, but
this raised another question about how to identify such issues earlier, maybe
even by CF bot. Fortunately this could be done with compiler support, i.e.
using:

```
-fsanitize=alignment -fno-sanitize-recover=alignment
```

for gcc and

```
-fsanitize=alignment -fsanitize-trap=alignment
```

for clang, except that the codebase already contains x86-specific crc32
computation code, which uses unaligned access. Eventually this was addressed
via another change:

```
commit 994bdb9f935a751935a03c80d30857150ba2b645
Author: Alexander Korotkov <akorotkov@postgresql.org>
Date:   Fri Feb 12 17:14:33 2021 +0300

pg_attribute_no_sanitize_alignment() macro
```

# Summary

That was a long story, longer that I anticipated in the beginning. In a way I
find this patch somewhat an interesting use case from which one can learn a
thing or two about how to work on patches for PostgreSQL. Here are few
learnings of my own in no particular order:

* A new patch is always a threat to stability of the code base and maintenance
  burden, one needs to keep this in mind.

* It's always good to get feedback early. Not always possible, but helps
  figuring out design problems at the start.

* Spliting a patch into small chunks always helps reviewers.

* You maybe surprised, but there are not that many people who can follow the
  thread closely and be aware about the current state of things, especially in
  long run. To help a CFM or anyone else who wants to jump into the thread it
  would be nice to write summaries from time to time.

* Even when it's not obviously required, reasonable and reproducable
  performance tests could make things easier. Not only others can run those
  tests on different hardware and with different configurations, it could serve
  as documentation on where the patch performs well and what are the worst case
  scenarious.

* If the patch achieve more than one goals (even of some of those are internal
  and not visible for users) it helps with the review efforts/produced value
  balance.

* Having another perspective on user interface for the patch is always useful.

* Last but not least -- reviewing of a patch requires significant efforts, and
  it's only fair to do the same and put significant efforts in review of
  patches from others.

I hope the story together with those (maybe partially opinionated) points could
be helpful for you, reader, or at least will provide some entertaining for the
evening.

[jsonb_subscripting_commit]: https://git.postgresql.org/gitweb/?p=postgresql.git;a=commit;h=676887a3b0b8e3c0348ac3f82ab0d16e9a24bd43
[type_email]: https://www.postgresql.org/message-id/112397.1608236975%40sss.pgh.pa.us
