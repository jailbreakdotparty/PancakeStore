#ifndef MAC_ADI_CORE_H
#define MAC_ADI_CORE_H
#include <stdint.h>
#include <stddef.h>
#include "unicorn/unicorn.h"
#include <bzlib.h>
#include <zlib.h>

static inline uc_err sap_uc_hook_add_code(uc_engine *uc, uc_hook *hh, void *callback, void *user_data, uint64_t begin, uint64_t end) {
    return uc_hook_add(uc, hh, UC_HOOK_CODE, callback, user_data, begin, end);
}
#ifdef __cplusplus
extern "C" {
#endif

typedef struct AdiHandle AdiHandle;
typedef struct { uint8_t *ptr; size_t len; } AdiBuf;
int32_t adi_open(const uint8_t *image, size_t len, AdiHandle **out);
void adi_close(AdiHandle *handle);
size_t adi_last_error(char *buf, size_t cap);
void adi_buf_free(AdiBuf buffer);
int32_t adi_set_host_uuid(AdiHandle *handle, const uint8_t *uuid);
int32_t adi_store_import(AdiHandle *handle, const uint8_t *data, size_t len);
int32_t adi_store_export(AdiHandle *handle, AdiBuf *out);
int32_t adi_headers(AdiHandle *handle, int64_t dsid, AdiBuf *mid, AdiBuf *otp, uint64_t *routing);
int32_t adi_provisioning_begin(AdiHandle *handle, int64_t dsid, const uint8_t *spim, size_t spim_len, AdiBuf *cpim, uint32_t *session);
int32_t adi_provisioning_finish(AdiHandle *handle, int64_t dsid, uint32_t session, const uint8_t *ptm, size_t ptm_len, const uint8_t *tk, size_t tk_len, uint64_t routing);
int32_t adi_erase(AdiHandle *handle, int64_t ds_id);
#ifdef __cplusplus
}
#endif
#endif
