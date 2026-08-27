/* What talloc's build system would have worked out by running test programs,
 * written down instead, because it cannot run anything on the machine it is
 * being built for. talloc.c includes samba's libreplace, which stands in for
 * whatever the platform is missing; every line below says bionic has it
 * already, and the file is exactly as long as talloc.c's own includes make it.
 * Anything not listed is unreferenced rather than absent.
 *
 * That is the whole reason this is not waf: with these, talloc.c compiles on
 * its own and needs nothing of libreplace, so there is no cross-compile
 * configure step to answer and the result is one object file.
 */

#include <string.h>

#define HAVE_CONSTRUCTOR_ATTRIBUTE 1

/* C23, and bionic only has it from API 34 — below that talloc scrubs memory it
 * is about to free with this instead. The barrier is the whole point of the
 * call: a plain memset over a dead allocation is something a compiler may drop.
 */
#define HAVE_MEMSET_EXPLICIT 1
#if __ANDROID_API__ < 34
static inline void *memset_explicit(void *block, int c, size_t size) {
	memset(block, c, size);
	__asm__ __volatile__("" : : "r"(block) : "memory");
	return block;
}
#endif

#define HAVE_STDBOOL_H 1
#define HAVE_BOOL 1
#define HAVE_STDINT_H 1
#define HAVE_INTPTR_T 1
#define HAVE_UINTPTR_T 1
#define HAVE_PTRDIFF_T 1
#define HAVE_USECONDS_T 1
#define HAVE_USLEEP 1
#define HAVE_DLFCN_H 1
#define HAVE_LIMITS_H 1
#define HAVE_UNISTD_H 1
#define HAVE_STRING_H 1
#define HAVE_STRINGS_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_VA_COPY 1
#define HAVE_MEMMOVE 1
#define HAVE_STRNLEN 1
#define HAVE_STRDUP 1
#define HAVE_STRNDUP 1
#define HAVE_STRLCPY 1
#define HAVE_STRLCAT 1
#define HAVE_SNPRINTF 1
#define HAVE_VSNPRINTF 1
#define HAVE_C99_VSNPRINTF 1
#define HAVE_GETPROGNAME 1
