#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wordexp.h>

static void check(const char *input, const char *expected)
{
  wordexp_t state = {0};
  static unsigned sequence;
  int status = wordexp(input, &state, WRDE_NOCMD);
  fprintf(stderr, "wordexp case=%u status=%d\n", ++sequence, status);
  assert(status == 0);
  assert(state.we_wordc == 1);
  assert(strcmp(state.we_wordv[0], expected) == 0);
  assert(state.we_wordv[1] == NULL);
  wordfree(&state);
}

int main(void)
{
  check("'/root'", "/root");
  check("'private payload'", "private payload");
  check("'a'\\''b'", "a'b");
  check("''", "");
  check("'$HOME/~/*'", "$HOME/~/*");
  check("'\xc3\xa9/e\xcc\x81/\xe6\x97\xa5'", "\xc3\xa9/e\xcc\x81/\xe6\x97\xa5");
  assert(setenv("PC_WORD_TEST", "expansion", 1) == 0);
  check("'${PC_WORD_TEST}'", "${PC_WORD_TEST}");
  wordexp_t state = {0};
  assert(wordexp("$(printf forbidden)", &state, WRDE_NOCMD) == WRDE_CMDSUB);
  wordfree(&state);
  state = (wordexp_t){.we_offs = 2};
  assert(wordexp("'one'", &state, WRDE_NOCMD | WRDE_DOOFFS) == 0);
  assert(state.we_wordv[0] == NULL && state.we_wordv[1] == NULL);
  assert(wordexp("'two'", &state, WRDE_NOCMD | WRDE_DOOFFS | WRDE_APPEND) == 0);
  assert(state.we_wordc == 2);
  assert(strcmp(state.we_wordv[2], "one") == 0);
  assert(strcmp(state.we_wordv[3], "two") == 0);
  assert(wordexp("'replacement'", &state, WRDE_NOCMD | WRDE_DOOFFS | WRDE_REUSE) == 0);
  assert(state.we_wordc == 1);
  assert(strcmp(state.we_wordv[2], "replacement") == 0);
  wordfree(&state);
  puts("wordexp forwarding passed");
  return 0;
}
