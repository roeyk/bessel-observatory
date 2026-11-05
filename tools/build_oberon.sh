#!/bin/sh
# Compile OBC's required .m filename in an isolated directory, keeping the
# Objective-C bessel.m source and generated compiler products separate.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/oberon
cp Bessel.Mod build/oberon/Bessel.m
cd build/oberon
"${OBC:-obc}" -C -lm -o ../bessel-oberon Bessel.m ../../bessel-oberon-posix.c
