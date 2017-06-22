hpcguix-web
===========

This repository contains the code that drives 
[hpcguix.op.umcutrecht.nl](https://hpcguix.op.umcutrecht.nl).

To run it yourself, you need to install [GNU Guix](https://www.guixsd.org),
and run the following commands:
```
# Set up a proper environment and build the source code
guix environment guix --ad-hoc guix
autoreconf -vfi
./configure
make

# Run the web interface
./pre-inst-env guile -s web-interface.scm
```
