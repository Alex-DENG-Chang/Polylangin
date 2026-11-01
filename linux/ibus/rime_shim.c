/*
 * Small C shim between the Python IBus engine and librime.
 *
 * It is compiled ON THE TARGET MACHINE against the system librime headers
 * (apt: librime-dev), so the RimeApi/RimeContext struct layouts always match.
 * The Python side only needs a stable, simple ABI.
 */
#include <rime_api.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static RimeApi* g_rime = NULL;
static int g_initialized = 0;
static RimeSessionId g_session = 0;
static int g_page_size = 5;

int polylangin_rime_init(const char* shared_dir, const char* user_dir, const char* log_dir,
                         char* err, int err_len) {
  if (g_initialized) return 0;
  g_rime = rime_get_api();
  if (!g_rime) {
    snprintf(err, err_len, "rime_get_api() returned NULL (librime not loaded?)");
    return -1;
  }
  RimeTraits traits;
  memset(&traits, 0, sizeof(traits));
  /* RIME_STRUCT_INIT matters: librime 1.10 defines data_size as
   * sizeof(Type) - sizeof(data_size), and RIME_STRUCT_CLEAR writes exactly
   * data_size bytes after the data_size field.  Setting it to sizeof(Type)
   * overflows RimeContext by 4 bytes (the stack-smashing bug). */
  RIME_STRUCT_INIT(RimeTraits, traits);
  /* The first Linux build uses only the standard Rime modules; the pinyin
   * schema is plain script_translator, so no external lua/octagram plugin is
   * loaded.  (Loading Debian's plugins manually caused an ABI crash.) */
  static const char* modules_default[] = {"default", NULL};
  traits.modules = modules_default;
  traits.shared_data_dir = shared_dir;
  traits.user_data_dir = user_dir;
  traits.log_dir = log_dir;
  traits.distribution_code_name = "Polylangin";
  traits.distribution_name = "Polylangin";
  traits.distribution_version = "0.1";
  traits.app_name = "polylangin";
  fprintf(stderr, "[polylangin] rime setup (traits size=%d)\n", (int)sizeof(RimeTraits));
  g_rime->setup(&traits);
  fprintf(stderr, "[polylangin] rime initialize\n");
  g_rime->initialize(NULL);
  fprintf(stderr, "[polylangin] rime maintenance\n");
  if (g_rime->start_maintenance(False)) {
    fprintf(stderr, "[polylangin] waiting for maintenance thread\n");
    g_rime->join_maintenance_thread();
  }
  fprintf(stderr, "[polylangin] rime maintenance done\n");
  g_initialized = 1;
  fprintf(stderr, "[polylangin] rime init ok\n");
  return 0;
}

void polylangin_rime_finalize(void) {
  if (!g_initialized || !g_rime) return;
  if (g_session) {
    g_rime->destroy_session(g_session);
    g_session = 0;
  }
  g_rime->finalize();
  g_initialized = 0;
}

unsigned long long polylangin_session(void) {
  if (!g_initialized || !g_rime) return 0;
  if (!g_session) {
    g_session = g_rime->create_session();
    fprintf(stderr, "[polylangin] session=%llu\n", (unsigned long long)g_session);
  }
  return (unsigned long long)g_session;
}

int polylangin_clear(void) {
  if (!g_rime || !g_session) return -1;
  g_rime->clear_composition(g_session);
  return 0;
}

int polylangin_process_key(int keycode, int mask) {
  if (!g_rime || !g_session) return 0;
  return g_rime->process_key(g_session, keycode, mask) ? 1 : 0;
}

/* Convert a token (ASCII letters) and write "cand\x1fcomment\x1e" records.
 * Returns the byte count, or -1 on failure. */
int polylangin_convert(const char* input, char* out, int out_len) {
  if (!g_rime || !g_session || !out || out_len <= 0) return -1;
  fprintf(stderr, "[polylangin] convert [%s]\n", input);
  out[0] = '\0';
  g_rime->clear_composition(g_session);
  for (const unsigned char* p = (const unsigned char*)input; *p; ++p) {
    g_rime->process_key(g_session, (int)(*p), 0);
  }

  size_t used = 0;
  int page = 0;
  int done = 0;
  while (!done && page < 6) {
    RimeContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    RIME_STRUCT_INIT(RimeContext, ctx);
    if (!g_rime->get_context(g_session, &ctx)) break;
    if (page == 0 && ctx.menu.page_size > 0) g_page_size = ctx.menu.page_size;
    int count = ctx.menu.num_candidates;
    for (int i = 0; i < count && used < (size_t)out_len - 1; ++i) {
      const char* text = ctx.menu.candidates[i].text ? ctx.menu.candidates[i].text : "";
      const char* comment = ctx.menu.candidates[i].comment ? ctx.menu.candidates[i].comment : "";
      int written = snprintf(out + used, (size_t)(out_len - (int)used), "%s\x1f%s\x1e", text, comment);
      if (written < 0 || written >= out_len - (int)used) { done = 1; break; }
      used += (size_t)written;
    }
    done = done || ctx.menu.is_last_page;
    g_rime->free_context(&ctx);
    if (!done) {
      if (!g_rime->change_page(g_session, False)) break;
      ++page;
    }
  }
  g_rime->clear_composition(g_session);
  out[used < (size_t)out_len ? used : (size_t)out_len - 1] = '\0';
  fprintf(stderr, "[polylangin] convert done (%d bytes)\n", (int)used);
  return (int)used;
}

int polylangin_last_page_size(void) {
  return g_page_size;
}

/* Feed a buffer, select a candidate by page/local index and report what pinyin
 * is left in the composition (multi-step selection: woshizhende|niubi). */
int polylangin_select(const char* input, int page, int index, char* out, int out_len) {
  if (!g_rime || !g_session || !out || out_len <= 0) return -1;
  out[0] = '\0';
  g_rime->clear_composition(g_session);
  for (const unsigned char* p = (const unsigned char*)input; *p; ++p) {
    g_rime->process_key(g_session, (int)(*p), 0);
  }
  for (int i = 0; i < page; ++i) {
    if (!g_rime->change_page(g_session, False)) break;
  }
  if (!g_rime->select_candidate_on_current_page(g_session, index)) {
    g_rime->clear_composition(g_session);
    return -1;
  }
  /* rime keeps the full original input in get_input(); the *remaining* raw
   * pinyin is the tail of the preedit starting at the current selection. */
  out[0] = '\0';
  RimeContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  RIME_STRUCT_INIT(RimeContext, ctx);
  if (g_rime->get_context(g_session, &ctx)) {
    const char* preedit = ctx.composition.preedit ? ctx.composition.preedit : "";
    int sel = (int)ctx.composition.sel_start;
    size_t len = strlen(preedit);
    if (sel >= 0 && (size_t)sel <= len) {
      char clean[512];
      size_t ci = 0;
      for (const char* p = preedit + sel; *p && ci < sizeof(clean) - 1; ++p) {
        if (*p == ' ') continue;
        clean[ci++] = *p;
      }
      clean[ci] = '\0';
      snprintf(out, out_len, "%s", clean);
    }
    g_rime->free_context(&ctx);
  }
  g_rime->clear_composition(g_session);
  return 0;
}

const char* polylangin_version(void) {
  if (g_rime && g_rime->get_version) return g_rime->get_version();
  return "unknown";
}
