/* LD_PRELOAD malloc counter for tools/membench.mojo: counts allocation calls and requested bytes; the bench reads
   mc_calls() and mc_bytes() through OwnedDLHandle. Build: gcc -shared -fPIC -O2 -o .work/malloc_count.so tools/malloc_count.c -ldl */
#include <stddef.h>
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);
static unsigned long calls, bytes;
static void note(size_t n) { __atomic_fetch_add(&calls, 1, __ATOMIC_RELAXED); __atomic_fetch_add(&bytes, n, __ATOMIC_RELAXED); }
unsigned long mc_calls(void) { return __atomic_load_n(&calls, __ATOMIC_RELAXED); }
unsigned long mc_bytes(void) { return __atomic_load_n(&bytes, __ATOMIC_RELAXED); }
void *malloc(size_t n) { note(n); return __libc_malloc(n); }
void *calloc(size_t a, size_t b) { note(a * b); return __libc_calloc(a, b); }
void *realloc(void *p, size_t n) { note(n); return __libc_realloc(p, n); }
void *aligned_alloc(size_t al, size_t n) { note(n); return __libc_memalign(al, n); }
int posix_memalign(void **r, size_t al, size_t n) { note(n); void *p = __libc_memalign(al, n); if (!p) return 12; *r = p; return 0; }
/* Mojo's List / String storage goes through the compiler runtime, not libc malloc: wrap it too (alignment, size). */
#define _GNU_SOURCE
#include <dlfcn.h>
void *KGEN_CompilerRT_AlignedAlloc(size_t a, size_t n) {
  static void *(*real)(size_t, size_t);
  if (!real) real = dlsym(RTLD_NEXT, "KGEN_CompilerRT_AlignedAlloc");
  note(n);
  return real(a, n);
}
