// Load/lookup smoke test only. SNE initialization requires a Flutter engine.
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  const char *symbols[] = {
    "super_native_extensions_init",
    "super_native_extensions_init_message_channel_context",
  };
  for (unsigned i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
    if (!dlsym(library, symbols[i])) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  }
  puts("SNE native library loads and exports both entrypoints");
  dlclose(library);
  return 0;
}
