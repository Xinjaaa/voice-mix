#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Opaque context is confined to the Rust backend worker thread.
void *mvm_create(void);
// Returned UTF-8 JSON is owned by native code. Always release with mvm_free.
char *mvm_execute(void *context, const char *request_json);
void mvm_free(char *json);
void mvm_destroy(void *context);
#ifdef __cplusplus
}
#endif
