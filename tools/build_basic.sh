#!/bin/sh
# FreeBASIC's C backend creates and removes a .c file beside its input.
# Compile a copy in a private build directory to protect our actual C edition.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/basic
cp bessel.bas build/basic/observatory.bas
cd build/basic
"${FBC:-fbc}" observatory.bas -x ../bessel-basic
