# Patches

`*.patch` files in this directory are applied, in name order, to `sources/wine`
of the CrossOver source tarball (`patch -p1`) by `scripts/wine/build.sh patch`.

The directory is empty on purpose: the engine is built from CodeWeavers' sources
as published. Add a patch here only when the first CI run shows a concrete build
failure that needs one, name it `NNNN-short-description.patch`, and keep it in
the LGPL-2.1-or-later license of the code it changes.
