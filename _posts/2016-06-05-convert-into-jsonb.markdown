---
layout: post
title:  "How to convert your data to jsonb?"
date:   2016-06-05 00:16:21
comments: true
tags: [PostgreSQL]
---

"How to start" is always a difficult question, and `jsonb` isn't an exception.
Here are few notes about converting different types of data into `jsonb`, that
someone can find useful.

Basically there are three possible cases of data conversion:

* Convert data from inside PostgreSQL
* Convert data from other database
* Convert plain data outside database

<!--break-->

## From inside PostgreSQL

First of all we shouldn't forget we can build data in `jsonb` format manually:

```sql
select '{"id": 1, "data": "aaa"}'::jsonb;
```
```bash
          jsonb           
--------------------------
 {"id": 1, "data": "aaa"}
```

```sql
select jsonb_build_object('id', 1, 'data', 'aaa');
```
```bash
    jsonb_build_object    
--------------------------
 {"id": 1, "data": "aaa"}
```

If we already have some relational data we can easy perform one-to-one
conversion for both complex and simple data types:

```sql
select to_jsonb(timestamp '2016-06-05');
```
```bash
       to_jsonb        
-----------------------
 "2016-06-05T00:00:00"
```

```sql
select to_jsonb(ARRAY[1, 2, 3]);
```
```bash
 to_jsonb  
-----------
 [1, 2, 3]
```

```sql
select to_jsonb('id=>1, data=>"aaa"'::hstore);
```
```bash
          to_jsonb          
----------------------------
 {"id": "1", "data": "aaa"}
```

Don't forget that `jsonb` is just a valid textual json, so all values will be
converted to number, string, boolean or null.

And if we want to produce a really complex and well-structured `jsonb` document
from large amount of relational data, `jsonb_agg` is our friend. This
function can transform a recordset into the format `column_name: record_value`:

```sql
select jsonb_agg(query) from (
    select id, data
    from jsonb_table
) query;
```
```bash
                      jsonb_agg                       
------------------------------------------------------
 [{"id": 1, "data": "aaa"}, {"id": 2, "data": "bbb"}]
```

## From other database

Again there are two options how to import data from another database:

* Import right in the json format as plain data (see following section)
* Import as relational data and then convert from inside PostgreSQL as in
  previous section

And in any case you should create all indices and make sure they're correct.
Let's see few examples:

### MongoDB

We can easily create a json dump of MongoDB database and then load it with minimal
modifications:

```bash
$ mongoexport                       \
    --db database_name              \
    --collection collection_name    \
    --jsonArray                     \
    -out dump.json
```

But you should be aware of specific data types, since BSON isn't 100%
compatible with textual json. To be more precise I'm talking about
`data_binary`, `data_date`, `data_timestamp`, `data_regex`, `data_oid` etc, see
[documentation][documentation]). E.g. when you'll create a dump of collection
with `data_date` field, you'll get something like this:

```python
"created_at": {
    "$date": 1445510017229
}
```

and you may decide to move this value one level up or keep this structure.

There is also another interesting option, which is related to the [ToroDB][ToroDB].

> ToroDB is an open source project that turns your RDBMS into a
> MongoDB-compatible server, supporting the MongoDB query API and MongoDB's
> replication, but storing your data into a reliable and trusted ACID database.

So it's like NoSQL over RDBMS. You can setup ToroDB as a hidden read-only
replica of a MondoDB replica set. Then when you'll be ready you can examine
ToroDB data structure and convert it into `jsonb` as in previous section.

Speaking about indices - it's possible to cover good amount of queries using
GIN index for `jsonb` column, but since it available only for small list of
operators, you should probably add separate indices for range queries.

### MySQL

`JSON` data type format in MySQL is pretty close to PostgreSQL, we can even use
`mysqldump` to convert one into another:

```bash
$ mysqldump                                     \
    --compact                                   \
    --compatible=postgresql                     \
    database_name                               \
    table_name | sed -e 's/\\\"/"/g' > dump.sql

$ cat ./dump.sql
```
```sql
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE "table_name" (
  "data" json DEFAULT NULL
);
/*!40101 SET character_set_client = @saved_cs_client */;
INSERT INTO "table_name" VALUES ('{"aaa": 1, "bbb": 2}'),('{"aaa": 3, "bbb": 4}'),('{"aaa": 5, "bbb": 6}');
```
```bash
$ psql < dump.sql
```

Just be careful about double quotes escaping and that's it.

## From plain data

And finally we have an option to import plain json data into PostgreSQL. But
imagine a situation, when we need to process not so well formatted data. Since
`jsonb` should strictly follow the json format, what can we do in that case?

It depends on how badly our document is broken. If document structure is
preserved, but there are some issues with formatting (one quote instead of
double or even without quotes, no commas and so on), it's possible to fix it
using (oh my gosh) `node.js` and more precisely the [json5][json5] extension and
the corresponding library:

```js
// format.js

var JSON5 = require('json5');
var stdin = process.stdin;
var stdout = process.stdout;

var inputChunks = [];

stdin.resume();
stdin.setEncoding('utf8');

stdin.on('data', function (chunk) {
    inputChunks.push(chunk);
});

stdin.on('end', function () {
    var inputData = inputChunks.join();

    var outputData = inputData
        .split('\n')
        .filter(function(input) {
            if(input) {
                return true;
            }
        })
        .map(function(input) {
            var parsed = JSON5.parse(input);
            var output = JSON.stringify(parsed);
            return output;
        }).join('\n');

    stdout.write(outputData);
});
```

```bash
$ cat data.json | node format.js > data_formatted.json
```

```sql
=# COPY table_name(jsonb_column_name) from 'data_formatted.json'
```

But if document structure is broken too - nothing can help, we need to fix it
manually using one of json linters.

[documentation]: https://docs.mongodb.com/manual/reference/mongodb-extended-json/
[ToroDB]: https://github.com/torodb/torodb
[json5]: http://json5.org/
