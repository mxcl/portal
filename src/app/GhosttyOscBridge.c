#include <stdint.h>
#include <string.h>

#if PORTAL_WITH_GHOSTTY
#include <ghostty/vt.h>
#endif

int32_t portal_ghostty_osc_command_type(const char *payload) {
  if (payload == 0) {
    return 0;
  }

#if PORTAL_WITH_GHOSTTY
  GhosttyOscParser parser;
  if (ghostty_osc_new(0, &parser) != GHOSTTY_SUCCESS) {
    return 0;
  }

  size_t length = strlen(payload);
  for (size_t i = 0; i < length; i++) {
    ghostty_osc_next(parser, (uint8_t)payload[i]);
  }

  GhosttyOscCommand command = ghostty_osc_end(parser, 0x07);
  int32_t type = (int32_t)ghostty_osc_command_type(command);
  ghostty_osc_free(parser);
  return type;
#else
  return strncmp(payload, "133;", 4) == 0 ? 3 : 0;
#endif
}
