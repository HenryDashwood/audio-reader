// Text to Kokoro phonemes for Magpie's downloadable voice. See native/g2p/src/ffi.rs.
#ifndef MAGPIE_G2P_H
#define MAGPIE_G2P_H

#include <stdbool.h>

typedef struct MagpieG2P MagpieG2P;

// Load one accent from the voice's folder. NULL on failure, with *error (if error isn't NULL) set to a message to free.
MagpieG2P *magpie_g2p_open(const char *dir, bool british, char **error);

// {"phonemes": ..., "tokens": [{"text", "phonemes", "whitespace"}]} or {"error": ...}. Free it. Thread-safe.
char *magpie_g2p_phonemize(const MagpieG2P *g2p, const char *text);

void magpie_g2p_free_string(char *string);

void magpie_g2p_close(MagpieG2P *g2p);

#endif
