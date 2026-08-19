#ifndef ENTOLI_ANDROID_COMPAT_H
#define ENTOLI_ANDROID_COMPAT_H

/* Bionic has no pthread cancellation at all, and git only ever uses it to keep
 * a section from being cancelled — which on a libc that cannot cancel is what
 * happens anyway. The whole of the source-level incompatibility, for the whole
 * of git. */
#define PTHREAD_CANCEL_ENABLE 0
#define PTHREAD_CANCEL_DISABLE 1

static inline int pthread_setcancelstate(int state, int *oldstate) {
  (void)state;
  if (oldstate) *oldstate = PTHREAD_CANCEL_ENABLE;
  return 0;
}

#endif
