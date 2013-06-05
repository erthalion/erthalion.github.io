---
layout: post
title:  "Another strange thing - an endless paginator"
date:   2014-04-21 18:14:42
comments: true
---

A little bit about my new program-frankenstein. Now it is an endless `Paginator` for Django. It sounds crazy, isn't?

Standart Django `Paginator` uses the `count()` function for the verification of page number. It is converted to the `SELECT COUNT(*) ...` query, of course. But as I was explained (I really don't know, maybe it's just an exaggeration - you can post your opinion in the commentaries), this is not a such lightweight query, as we want for the paginated rest api, because of the [MVCC][mvcc] in PostgreSQL.

How we can avoid the extra `COUNT(*)` query? Don't panic, we can trick the Django.

First of all we need to disable `count` parameter from the api response. We can introduce a custom pagination serializer:

{% highlight python %}
# serializers.py
class CustomPaginationSerializer(BasePaginationSerializer):
    next = NextPageField(source='*')
    previous = PreviousPageField(source='*')

# api.py
class SomeListView(generics.ListAPIView):
    model = SomeModel
    serializer_class = SomeSerializerClass
    pagination_serializer_class = CustomPaginationSerializer
{% endhighlight %}

The next our move - disable the page number verification. This can be done by the custom paginator class:

{% highlight python %}
class CustomPaginator(Paginator):
    """ HACK: To avoid unneseccary `SELECT COUNT(*) ...`
        paginator has an infinity page number and a count of elements.
    """
    def _get_num_pages(self):
        """
        Returns the total number of pages.
        """
        return float('inf')

    num_pages = property(_get_num_pages)

    def _get_count(self):
        """
        Returns the total number of objects, across all pages.
        """
        return float('inf')

    count = property(_get_count)

    def _get_page(self, *args, **kwargs):
        return CustomPage(*args, **kwargs)


class SomeListView(generics.ListAPIView):
    model = SomeModel
    serializer_class = SomeSerializerClass
    pagination_serializer_class = CustomPaginationSerializer
    paginator_class = CustomPaginator

{% endhighlight %}

Oh, goodness - we introduced the infinity number of the pages and the infinity number of elements... But we want also the correct next/prev links, so one more detail:

{% highlight python %}
class CustomPage(Page):
    def has_next(self):
        """ HACK: Select object_list + 1 element
            to verify next page existense.
        """
        low = self.object_list.query.__dict__['low_mark']
        high = self.object_list.query.__dict__['high_mark']
        self.object_list.query.clear_limits()
        self.object_list.query.set_limits(low=low, high=high+1)

        try:
            # len is used only for small portions of data (one page)
            if len(self.object_list) <= self.paginator.per_page:
                return False

            return True
        finally:
            # restore initial object_list count
            self.object_list = self.object_list[:(high-low)]
{% endhighlight %}

This solution looks very questionable, but exciting for me. If you have something to say about this - welcome! =)

[mvcc]: http://wiki.postgresql.org/wiki/MVCC
