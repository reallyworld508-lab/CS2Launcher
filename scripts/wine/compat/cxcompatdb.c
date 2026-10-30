/*
 * cs2l-compat: open replacement for CodeWeavers' closed "cxcompatdb.so".
 *
 * CrossOver's ntdll.so (dlls/ntdll/unix/loader.c, "CW Hack 24067") dlopen()s
 * <dir of ntdll.so>/cxcompatdb.so at the end of process start-up. CodeWeavers'
 * own file is closed source and licensed for CrossOver only; it is not used
 * here. This file is a small independent implementation of the one job the
 * launcher needs from it: pick the graphics backend and put Apple's D3DMetal
 * Wine DLLs in front of Wine's own Direct3D DLLs.
 *
 * Environment (read at process start, so every Wine process gets it):
 *
 *   CX_GRAPHICS_BACKEND      wined3d (default) | d3dmetal | dxvk | dxmt
 *   CS2L_D3DMETAL_DIR        directory that holds Apple's  wine/  and  external/
 *                            (the "redist/lib" folder of the Game Porting Toolkit)
 *   CS2L_DXVK_DIR            directory with x86_64-windows/ and x86_64-unix/ (dxvk)
 *   CS2L_DXMT_DIR            same, for dxmt
 *   CS2L_PRIORITY_DLLPATH    extra directories, colon separated, searched before
 *                            Wine's own lib/wine (each one holds x86_64-windows/ ...)
 *   CS2L_COMPAT_DEBUG=1      print what was decided to stderr
 *
 * Result: CX_ACTIVE_GRAPHICS_BACKEND is set to the backend that is really in use
 * (win32u reads it: D3DKMT WDDM 2.7 caps for d3dmetal, CX_LIBVULKAN for wined3d).
 * If d3dmetal is requested but the files are not there, it falls back to wined3d.
 *
 * Copyright (C) 2026 the CS2 Launcher authors. LGPL-2.1-or-later, like Wine.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*prepend_dll_path_fn)(const char *);

static int debug;

static void say(const char *fmt, const char *a, const char *b)
{
    if (!debug) return;
    fprintf(stderr, "cs2l-compat: ");
    fprintf(stderr, fmt, a, b);
    fputc('\n', stderr);
}

static int exists(const char *dir, const char *rel)
{
    char *p = NULL;
    int ok;
    if (asprintf(&p, "%s/%s", dir, rel) < 0) return 0;
    ok = access(p, R_OK) == 0;           /* follows symlinks */
    free(p);
    return ok;
}

static void prepend(prepend_dll_path_fn fn, const char *dir)
{
    /* ntdll keeps the pointer: it must live for the whole process */
    char *copy = strdup(dir);
    if (copy) fn(copy);
}

__attribute__((constructor)) static void cs2l_compat_init(void)
{
    const char *want = getenv("CX_GRAPHICS_BACKEND");
    const char *extra = getenv("CS2L_PRIORITY_DLLPATH");
    const char *use = "wined3d";
    char *wine_dir = NULL;
    prepend_dll_path_fn fn;

    debug = getenv("CS2L_COMPAT_DEBUG") != NULL;
    if (!want || !*want) want = "wined3d";

    fn = (prepend_dll_path_fn)dlsym(RTLD_DEFAULT, "prepend_dll_path");
    if (!fn)
    {
        say("ntdll has no prepend_dll_path, nothing to do%s%s", "", "");
        return;
    }

    if (!strcmp(want, "d3dmetal"))
    {
        const char *dir = getenv("CS2L_D3DMETAL_DIR");
        if (dir && *dir && exists(dir, "wine/x86_64-windows/d3d11.dll") &&
            exists(dir, "wine/x86_64-unix/d3d11.so") && exists(dir, "external/libd3dshared.dylib") &&
            asprintf(&wine_dir, "%s/wine", dir) > 0)
        {
            prepend(fn, wine_dir);
            use = "d3dmetal";
            say("d3dmetal: %s first in the DLL path", wine_dir, "");
        }
        else say("d3dmetal requested but CS2L_D3DMETAL_DIR=%s is incomplete, using wined3d%s", dir ? dir : "(unset)", "");
        free(wine_dir);
    }
    else if (!strcmp(want, "dxvk") || !strcmp(want, "dxmt"))
    {
        const char *dir = getenv(!strcmp(want, "dxvk") ? "CS2L_DXVK_DIR" : "CS2L_DXMT_DIR");
        if (dir && *dir && exists(dir, "x86_64-windows"))
        {
            prepend(fn, dir);
            use = want;
            say("%s: first in the DLL path", dir, "");
        }
        else say("%s requested but its directory is missing, using wined3d", want, "");
    }
    else if (strcmp(want, "wined3d")) say("unknown backend %s, using wined3d", want, "");

    if (extra && *extra)
    {
        char *list = strdup(extra), *save = NULL, *tok;
        /* prepend in reverse so the first entry ends up first */
        char *items[64];
        int n = 0, i;
        for (tok = strtok_r(list, ":", &save); tok && n < 64; tok = strtok_r(NULL, ":", &save))
            items[n++] = tok;
        for (i = n - 1; i >= 0; i--) { prepend(fn, items[i]); say("extra path %s", items[i], ""); }
        free(list);
    }

    setenv("CX_ACTIVE_GRAPHICS_BACKEND", use, 1);
    say("active backend: %s%s", use, "");
}
