---
layout: post
title:  "Use an exception instead of the NaN"
date:   2014-08-16 15:20:42
comments: true
---

This is a small notice about a very useful trick. I often have to deal with computations, because the CFD is the part of my activity. And one of the annoying problem in this kind of research is when after many hours of computations you got a `Not A Number` result, caused by a stupid mistake. It would be nice, if a computation was interrupted by the NaN.

<!--break-->

And there is the [solution][stackoverflow]:

{% highlight c %}
#define _GNU_SOURCE
#include <fenv.h>
#include <stdio.h>

int main(void) {
    double x, y, z;
    feenableexcept(FE_DIVBYZERO | FE_INVALID | FE_OVERFLOW);

    x = 0.0;
    y = 0.0;
    z = x / y; /* should cause an FPE */
    printf("result is %f\n", z);
    return 0;
}
{% endhighlight %}

The `fenv.h` header declares a set of functions and macros to access the floating-point environment, along with specific types.
According to man:

> The  feenableexcept() function enable traps for each of the exceptions represented by excepts and return the previous set of enabled exceptions when successful, and -1 otherwise. 

Now, what we have without `feenableexcept`:

{% highlight sh %}
$ ./test_no_fenv 
> result is -nan
{% endhighlight %}

And with:

{% highlight sh %}
$ ./test_fenv 
> fish: Job 1, './test' terminated by signal SIGFPE (Floating point exception)
{% endhighlight %}

[stackoverflow]: http://stackoverflow.com/a/2949452
