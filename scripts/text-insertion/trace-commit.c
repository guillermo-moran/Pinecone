#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include "trace.h"

typedef guint (*AddNotify)(GtkTextBuffer *, GtkTextBufferNotifyFlags,
                          GtkTextBufferCommitNotify, gpointer, GDestroyNotify);
typedef struct {
  GtkTextBufferCommitNotify callback;
  gpointer data;
  GDestroyNotify destroy;
} Closure;

static void forward_commit(GtkTextBuffer *buffer, GtkTextBufferNotifyFlags flags,
                           guint position, guint length, gpointer data)
{
  Closure *closure = data;
  const char *name = "spelling.commit.other";
  switch (flags) {
    case GTK_TEXT_BUFFER_NOTIFY_BEFORE_INSERT: name = "spelling.commit.before-insert"; break;
    case GTK_TEXT_BUFFER_NOTIFY_AFTER_INSERT: name = "spelling.commit.after-insert"; break;
    case GTK_TEXT_BUFFER_NOTIFY_BEFORE_DELETE: name = "spelling.commit.before-delete"; break;
    case GTK_TEXT_BUFFER_NOTIFY_AFTER_DELETE: name = "spelling.commit.after-delete"; break;
  }
  PC_TEXT_SCOPE(name, 0);
  closure->callback(buffer, flags, position, length, closure->data);
}

static void destroy_closure(gpointer data)
{
  Closure *closure = data;
  if (closure->destroy)
    closure->destroy(closure->data);
  g_free(closure);
}

/* Only wrap the callback originating in libspelling. Never inspect opaque data.
 * Registration IDs, flags, argument lifetimes and destroy ordering stay GTK's.
 * This intercepts an external public call, not GTK's hidden internal calls. */
guint gtk_text_buffer_add_commit_notify(GtkTextBuffer *buffer,
                                       GtkTextBufferNotifyFlags flags,
                                       GtkTextBufferCommitNotify callback,
                                       gpointer data, GDestroyNotify destroy)
{
  int saved = errno;
  AddNotify original = (AddNotify)dlsym(RTLD_NEXT, "gtk_text_buffer_add_commit_notify");
  if (!original)
    g_error("text-insertion trace requires gtk_text_buffer_add_commit_notify");
  const char *enabled = getenv("PINECONE_TEXT_INSERTION_TRACE");
  Dl_info info;
  const char *base = NULL;
  if (enabled && strcmp(enabled, "1") == 0 && callback &&
      dladdr((void *)callback, &info) && info.dli_fname) {
    base = strrchr(info.dli_fname, '/');
    base = base ? base + 1 : info.dli_fname;
  }
  const char prefix[] = "libspelling-1.so";
  if (!base || strncmp(base, prefix, sizeof(prefix) - 1) != 0 ||
      (base[sizeof(prefix) - 1] != '\0' && base[sizeof(prefix) - 1] != '.')) {
    errno = saved;
    return original(buffer, flags, callback, data, destroy);
  }
  Closure *closure = g_new(Closure, 1);
  *closure = (Closure){callback, data, destroy};
  errno = saved;
  guint id = original(buffer, flags, forward_commit, closure, destroy_closure);
  if (!id)
    g_free(closure); /* GTK did not take ownership; do not destroy caller data. */
  return id;
}
