/* Run with the guest loader, not the builder's dependency closure. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *symbol(const char *name)
{
  void *value = dlsym(RTLD_DEFAULT, name);
  if (!value) {
    fprintf(stderr, "%s: %s\n", name, dlerror());
    exit(1);
  }
  return value;
}

static void load(const char *name)
{
  if (!dlopen(name, RTLD_NOW | RTLD_GLOBAL)) {
    fprintf(stderr, "%s: %s\n", name, dlerror());
    exit(1);
  }
  printf("loaded %s\n", name);
}

static void version(const char *name, const char *actual, const char *expected)
{
  printf("runtime %s %s\n", name, actual);
  if (strcmp(actual, expected)) {
    fprintf(stderr, "%s: expected %s\n", name, expected);
    exit(1);
  }
}

int main(int argc, char **argv)
{
  if (argc != 4) return 2;
  load("libgtksourceview-5.so.0");
  load("libpinecone-text-commit.so");
  load("libspelling-1.so.2");
  char value[64];
  snprintf(value, sizeof value, "%u.%u.%u",
           *(unsigned *)symbol("glib_major_version"),
           *(unsigned *)symbol("glib_minor_version"),
           *(unsigned *)symbol("glib_micro_version"));
  version("GLib", value, argv[1]);
  const char *(*pango_version)(void) = symbol("pango_version_string");
  version("Pango", pango_version(), argv[2]);
  unsigned (*major)(void) = symbol("gtk_get_major_version");
  unsigned (*minor)(void) = symbol("gtk_get_minor_version");
  unsigned (*micro)(void) = symbol("gtk_get_micro_version");
  snprintf(value, sizeof value, "%u.%u.%u", major(), minor(), micro());
  version("GTK", value, argv[3]);
  return 0;
}
