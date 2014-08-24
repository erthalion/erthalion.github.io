---
layout: post
title:  "Django and PostgreSQL schemas"
date:   2014-03-08 12:10:05
comments: true
---

There are a some cases, when we prefer to use a PostgreSQL schemas for our purposes. The reasons for this can be different, but how it can be done?

There are a lot of discussion about the implementation of PostgreSQL schemas in Django (for example [one][schema_ticket1], [two][schema_ticket2]). And I want to describe several caveats.

First of all - you shouldn't use the `options` key to choice a schema like this:
{% highlight python %}
    DATABASES['default']['OPTIONS'] = {
        'options': '-c search_path=schema'
    }
{% endhighlight %}

It can be working, until you [don't use pgbouncer][pgbouncer_maillist]. This option hasn't supported because of the connection pool - when you close a connection with `search_path`, it will be returned into the pool, and can be reused with the out of date `search_path`.

So what we gonna do? The only choice is to use `connection_create` signal:
{% highlight python %}
# schema.py
def set_search_path(sender, **kwargs):
    from django.conf import settings

    conn = kwargs.get('connection')
    if conn is not None:
        cursor = conn.cursor()
        cursor.execute("SET search_path={}".format(
            settings.SEARCH_PATH,
        ))

# ?.py
from django.db.backends.signals import connection_created
from schema import set_search_path

connection_created.connect(set_search_path)
{% endhighlight %}

But where should we place this code? In general case if we want to handle the migrations, the only place is a settings file (a `model.py` isn't suitable for this, when we want to distribute an application models and third-party models over different schemas). And to avoid circular dependencies, we should use three (OMG!) configuration files - `default.py` (main configuration), `local.py/staging.py/production.py` (depends on the server), `migration.py` (used to set a search path). The last configuration is used only for the migration purposes:
{% highlight bash %}
python manage.py migrate app --settings=project.migration
{% endhighlight %}

For the normal usage we can connect `set_search_path` function to the `connection_create` signal in the root `urls.py` and avoid the `migration.py` configuration of course.

But that's not all - there is one more trouble with the different schemas, if you using `TransactionTestCase` for testing. Sometimes you can see an error at the tests `tear_down`:
{% highlight bash %}
Error: Database test_store couldn't be flushed. 
DETAIL:  Table "some_table" references "some_other_table".
{% endhighlight %}

To avoid this error you can define `available_apps` field, which must contain the minimum of apps required for testing:
{% highlight bash %}
class SomeTests(TransactionTestCase):
    available_apps = ('one_app', 'another_app')
{% endhighlight %}

So we finished. I hope I have described the all possibe issues =)

[schema_ticket1]: https://code.djangoproject.com/ticket/1051
[schema_ticket2]: https://code.djangoproject.com/ticket/6148
[pgbouncer_maillist]: http://lists.pgfoundry.org/pipermail/pgbouncer-general/2011-August/000842.html
