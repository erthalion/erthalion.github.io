---
layout: post
title:  "From bash to fish"
date:   2014-08-08 22:20:42
comments: true
---

I'm doing a small revolution in my environment from time to time. I think "hey, a cool stuff", take a deep breath and doing something new. And this is story about my migration from the bash to the fish shell.

Let's see, what says the official tutorial:

>fish is a fully-equipped command line shell (like bash or zsh) that is smart and user-friendly. fish supports powerful features like syntax highlighting, autosuggestions, and tab completions that just work, with nothing to learn or configure.
> If you want to make your command line more productive, more useful, and more fun, without learning a bunch of arcane syntax and configuration options, then fish might be just what you're looking for! 

And this is almost true =) But there is another concrete reason, why I like fish shell:

* Search by history (as an autocomplete by tab)
* More intuitive and clean configuration files
* Vim mode [support][vim-ticket]

<!--break-->

I would to avoid unnecessary lyrics, and pay more attention to the configuration and gotchas (from the bash point of view).

First of all - use `.` command instead `source` for the inclusion of the script.

{% highlight sh %}
. /some-install-path/fish-shell/share/fish/functions/fish_vi_mode.fish
. /some-install-path/.config/fish/themes/fish_right_prompt.fish
. /some-install-path/.config/fish/themes/fish_prompt.fish
. /etc/profile.d/autojump.fish
fish_vi_key_bindings
{% endhighlight %}

I've used `some-install-path` because I'm a Vim hacker (~~an extra pathos~~), and I want a fresh version for the Vim support, so the manual compilation from github is my way. Then I've turned on Vim mode (`fish_vi_mode.fish` is necessary for this). `fish_prompt.fish` and `fish_right_prompt.fish` contain a description for the shell prompt and will be discussed later. If you use `autojump`, you should also include `autojump.fish` (if this file doesn't exist, download it from repo).

{% highlight sh %}
set fish_greeting ""
{% endhighlight %}

This greeting is very distracting, so disable it. No comments =)

{% highlight sh %}
set -x EDITOR vim
set PATH /home/erthalion/.local/bin /usr/local/bin /opt/bin $PATH
{% endhighlight %}

We should set environment variables in this format. Pay attention to the `PATH` variable - don't forget about `/usr/local/bin` and `/opt/bin` (looks like fish shell doesn't include them by default).

{% highlight sh %}
alias goutshow='git fetch; git show origin/master..'
{% endhighlight %}

One more observation - we should replace `&&` by the `;` or `and` commands.

Now get closer to the prompt. It described by the two functions - `fish_prompt` and `fish_right_prompt` (your C.O.). I have no advices for this section. Really. You can use your imagination and do what you want =) There are my examples - [left][fish_prompt] and [right][fish_right_prompt]. Only one comment - you may want to show `virtualenv` name in the prompt. In that case you should disable original by the variable `set -x VIRTUAL_ENV_DISABLE_PROMPT 1`.

But unfortunately, Vim support isn't very well in the fish shell. For example, there is no `replace (r)` command, or `undo (u)`. Actually it's a horrible problem for me, especially the first one =) And here is my [solution][pull-request] of this problem.

I think, fish shell is available for a lot of improvements. All, that described above, is only a base for a convenient environment, and I hope, it will be useful.

[vim-ticket]: https://github.com/fish-shell/fish-shell/issues/65
[fish_prompt]: https://github.com/erthalion/dotfiles/blob/master/fish_themes/fish_prompt.fish
[fish_right_prompt]: https://github.com/erthalion/dotfiles/blob/master/fish_themes/fish_right_prompt.fish
[pull-request]: https://github.com/fish-shell/fish-shell/pull/1595 
