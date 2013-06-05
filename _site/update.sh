#!/usr/bin/env bash

source ~/.nix-profile/etc/profile.d/nix.sh
export LANG="en_US.UTF-8"
export LANGUAGE="en_US.UTF-8"
export LC_ALL="C.UTF-8"

bundle exec jekyll build
jekyll serve --skip-initial-build --no-watch
