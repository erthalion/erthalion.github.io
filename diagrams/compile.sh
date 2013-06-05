#! /bin/bash

for file in $(ls *.dot); do
	dot -Tpng -Gsize=9,15\! -Gdpi=300 -o $file.png $file;
done;
