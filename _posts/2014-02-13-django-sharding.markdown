---
layout: post
title:  "What about sharding in the Django?"
date:   2014-02-13 21:14:42
comments: true
---

Some time ago I was faced with the need to implement the sharding in Django 1.6 . It was an attempt to make step beyond the standart features of this framework and I felt the resistance of Django =) I'll talk a bit about this challenge and its results.

Let's start with definitions. Wikipedia says that:

> A database shard is a horizontal partition in a database.
> Horizontal partitioning is a database design principle whereby rows of a database table are held separately, rather than being split into columns (which is what normalization and vertical partitioning do, to differing extents). Each partition forms part of a shard, which may in turn be located on a separate database server or physical location.

We wanted split our database entities by the different PostgreSQL schemas and used something like [this][instagramm_id] for the `id` generation. The sharding model was clear, but how to implement it in the Django application?

My solution of this problem was a custom database backend, that contains a custom sql compilers. Maybe it was a dirty hack, but I hope it wasn't =)

To create your own custom database backend, you can copy structure from one of the existing backends from `django.db.backends` (`postgresql_psycopg2` for our case) and override `DatabaseOperations`:

{% highlight python %}
# operations.py
from django.db.backends.postgresql_psycopg2.operations import *

class CustomDatabaseOperations(DatabaseOperations):
    compiler_module = "path.to.the.compiler.module"

# base.py
from django.db.backends.postgresql_psycopg2.base import *
from operations import CustomDatabaseOperations

class CustomDatabaseWrapper(DatabaseWrapper):
    def __init__(self, *args, **kwargs):
        super(CustomDatabaseWrapper, self).__init__(*args, **kwargs)

        self.ops = CustomDatabaseOperations(self)

DatabaseWrapper = CustomDatabaseWrapper
{% endhighlight %}

A custom sql compilers will be adding a corresponding schema name into the sql request based on the entity id:
{% highlight python %}
# compilers.py

class CustomSQLCompiler(SQLCompiler):
    def as_sql(self):
        table = self.query.get_meta().db_table
        if table not in self.sharded_tables:
            return super(CustomSQLCompiler, self).as_sql()
        else:
            sql, params = super(CustomSQLCompiler, self).as_sql()

            """ The first item of the params tuple must be entity id
            """
            schema = self.get_shard_name(params[0])

            old = '"{}"'.format(table)
            new = '{}."{}"'.format(schema, table)
            sql = sql.replace(old, new)

        return sql, params


SQLCompiler = CustomSQLCompiler
{% endhighlight %}

That's all! Oh, okay, that's not all =) Now you must create a custom `QuerySet` (with the two overrided methods - `get` & `create`) to provide a correct sharded id for an all entities.

But there is one problem - migrations. You can't migrate correctly your sharded models and it's sad. To avoid this we inctoruced the some more complex database configuration dictionary. We used the special method, that converted this complex config into the standard with a lot of database connections - a one for each shard. All connections have the `search_path` option. In the `settings.py` we must take in account a type of action:
{% highlight python %}
# settings.py

def get_shard_settings(shard_migrate=False, shard_sync=False):
    """ Not an all apps must be sharded.
    """
    installed_apps = ('some_sharded_app1', 'some_sharder_app2',)
    databases = DB_CONFIGURATOR(DB_CONFIG, shard_migrate=shard_migrate, shard_sync=shard_sync)
    return installed_apps, databases

""" We must separate
    - normal usage,
    - sharded models synchronization
    - sharded models migration 
"""
if sys.argv[-1] == 'shard_migrate':
    del sys.argv[-1]
    INSTALLED_APPS, DATABASES = get_shard_settings(shard_migrate=True)

elif sys.argv[-1] == 'shard_sync':
    del sys.argv[-1]
    INSTALLED_APPS, DATABASES = get_shard_settings(shard_sync=True)

else:
    DATABASES = DB_CONFIGURATOR(DB_CONFIG)

{% endhighlight %}

Now we can manage sharded migrations by `--database` options. For convenience you can write a fab script of course.

And one more and last caveat - you must create `SOUTH_DATABASE_ADAPTERS` variable, that will be pointing to original postgres adapter `south.db.postgresql_psycopg2` - south can't create a correct migration otherwise.

[instagramm_id]: http://instagram-engineering.tumblr.com/post/10853187575/sharding-ids-at-instagram
