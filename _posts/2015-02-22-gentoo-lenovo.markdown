---
layout: post
title:  "Gentoo and Lenovo u430p - the sad story"
date:   2015-02-22 1:14:21
comments: true
---

Finally, I decided to replace my old laptop, and my chose fell on the Lenovo u430p. As I understand now, it was not a good idea in case of Gentoo =) Actually, I was surprised, how many nerves you can lose only because of the adaptation of you hardware to your requirements. And here is the shortlist of what you shouldn't forget, if you want to do the same more easily.

<!--break-->

## EFI loader

So you've successfully passed several steps from Gentoo Handbook. One of the last is Grub2 installation and configuration. You've completed this, rebooted and...nothing happened, you see the Windows 8 again.

<img src="/public/img/farnsworth.jpg" border="0" width="50%" style="margin: auto">

The clue to this problem is the "Secure Boot" option, which enabled by default in BIOS.

## iwlwifi

Next big disaster is the `iwlwifi` driver for the Intel Wireless 7260. The most of wifi routers are working in the mixed 11bgn mode, and 11n drives `iwlwifi` (and you with him) mad. There are an endless disconnections and the terrible instability.

<img src="/public/img/fry-bender-roar.jpg" border="0" width="50%" style="margin: auto">

The only known solution is cut out the 11n mode:
{% highlight bash %}
# /etc/modprobe.d/iwlwifi.conf

options iwlwifi 11n_disable=1
{% endhighlight %}

And you shouldn't forget to compile `iwlwifi` as kernel module (otherwise, obviously, this option will not be applied). The last step is the firmware installation. You can download the `iwlwifi-7260-9.ucode`, place it in `/lib/firmware`, and configure to load this firmware with kernel:

{% highlight bash %}
Device Driver ->
    Generic Driver Options ->
        [*] Include in-kernel firmware blobs in kernel library
        (iwlwifi-7260-9.ucode) External firmware blobs to build into kernel library
        (/lib/firmware) Firmware blobls root directory
{% endhighlight %}

Btw, one more note - loos like `iwlwifi-7269-9.ucode` is working more stable, then `iwlwifi-7260-10.ucode`.

## Microphone

I don't know why, but this there was no working configuration for microphone out of box =) I installed alsa and pulseaudio (the last one for the Skype, of course), and issues with the audio capture were really unexpected for me.

<img src="/public/img/fry-megaphone.jpg" border="0" width="50%" style="margin: auto">

Actually, I though, that everything was unmutes in the alsamixer, but I was wrong:

{% highlight bash %}
$ amixer -c 1
...
Simple mixer control 'Capture',0 
Capabilities: cvolume cswitch 
Capture channels: Front Left - Front Right 
Limits: Capture 0 - 63 
Front Left: Capture 63 [100%] [30.00dB] [off] 
Front Right: Capture 63 [100%] [30.00dB] [off]
...
{% endhighlight %}

You can unmute the `Capture, 0` control by this command (`-c 1` is the card number):

{% highlight bash %}
$ amixer -c 1 Capture, 0 80% 40% unmute cap
{% endhighlight %}

And btw, don't forget about the web cam:

{% highlight bash %}
Device Drivers ->
    Multimedia support ->
        [*] Cameras/video grabbers support
        [*] Media USB Adapters ->
            <*> USB input event device support
{% endhighlight %}

## Windows 8 loading

Ok, it's well enough. But if you'll try to load now from the grub2 menu to Win8, you'll suprised because of the messages `error: can't find command drivemap` and `error: invalid EFI file path`.

<img src="/public/img/fry-fall.jpg" border="0" width="50%" style="margin: auto">

To avoid this problem you should create custom menu entry for `grub.cfg` with chainloader for Win8:

{% highlight bash %}
#!/bin/sh
# /etc/grub.d/40_custom
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.
menuentry 'Windows 8 (UEFI loader)' --class windows --class os $menuentry_id_option 'osprober-chain-02E42074E4206BDB' {
	search --file --no-floppy --set=root /EFI/Microsoft/Boot/bootmgfw.efi
	chainloader (${root})/EFI/Microsoft/Boot/bootmgfw.efi
}
{% endhighlight %}

Don't forget to update `grub.cfg`:

{% highlight bash %}
# grub2-mkconfig -o /boot/grub/grub.cfg
{% endhighlight %}

## Touchpad

Default configuration for touchpad is terrible...

<img src="/public/img/fry-coffee.jpg" border="0" width="50%" style="margin: auto">

You can improve it - just don't forget, that this model doesn't have the hardware right mouse button (so you shouldn't disable software button). Here is my configuration:

{% highlight bash %}
# /etc/X11/xorg.conf.d/50-synaptics.conf

Section "InputClass"
    Identifier "touchpad"
    MatchIsTouchpad "on"
    MatchDevicePath "/dev/input/event*"
    Driver "synaptics"
 
    Option "TapButton1" "1"
    Option "TapButton2" "3"
    Option "TapButton3" "2"

    # accurate tap-to-click!
    Option "FingerLow" "50"
    Option "FingerHigh" "55"
 
    # prevents too many intentional clicks
    Option "PalmDetect" "0"
 
    # vertical and horizontal scrolling, use negative delta values for "natural" scrolling
    Option "VertTwoFingerScroll" "1"
    Option "VertScrollDelta" "75"
    Option "HorizTwoFingerScroll" "1"
    Option "HorizScrollDelta" "75"
 
    Option "MinSpeed" "1"
    Option "MaxSpeed" "2"
 
    Option "AccelerationProfile" "2"
    Option "ConstantDeceleration" "4"
EndSection
{% endhighlight %}

And one more note - if you're using the `laptop-mode` and a wireless keyboard from Logitech, it probably will be better to put this device into blacklist to avoid annoying problems with an unexpectedly frozen keyboard:

{% highlight bash %}
$ lsusb
......
Bus 001 Device 002: ID 046d:c52b Logitech, Inc. Unifying Receiver
......
{% endhighlight %}

{% highlight bash %}
# /etc/laptop-mode/conf.d/runtime-pm.conf

AUTOSUSPEND_RUNTIME_DEVID_BLACKLIST="046d:c52b"
{% endhighlight %}

## End

It was interesting journey to the world of bugs, strange configurations and default options. I hope this shortlist can be useful, at least for me in the future =)

<img src="/public/img/futurama.jpg" border="0" width="50%" style="margin: auto">
