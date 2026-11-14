//
//  anisette_core.h
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#ifndef ANISETTE_CORE_H
#define ANISETTE_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    ANISETTE_OK                            = 0,
    ANISETTE_ERR_INVALID_ARGUMENT          = -1,
    ANISETTE_ERR_LOADER_FAILED             = -2,
    ANISETTE_ERR_SYMBOL_MISSING            = -3,
    ANISETTE_ERR_READ_FILE_FAILED          = -4,
    ANISETTE_ERR_INVALID_JSON_RESPONSE     = -5,

    ADI_ERR_INVALID_PARAMS                 = -45001,
    ADI_ERR_INVALID_PARAMS_DECIPHER        = -45002,
    ADI_ERR_INVALID_TRUST_KEY              = -45003,
    ADI_ERR_PTM_TK_MISMATCH                = -45006,
    ADI_ERR_INVALID_INPUT_HEADER           = -45018,
    ADI_ERR_UNKNOWN_ADI_FUNCTION           = -45019,
    ADI_ERR_INVALID_INPUT_BODY             = -45020,
    ADI_ERR_UNKNOWN_SESSION                = -45025,
    ADI_ERR_EMPTY_SESSION                  = -45026,
    ADI_ERR_INVALID_DATA_HEADER            = -45031,
    ADI_ERR_DATA_TOO_SHORT                 = -45032,
    ADI_ERR_INVALID_DATA_BODY              = -45033,
    ADI_ERR_UNKNOWN_CALL_FLAGS             = -45034,
    ADI_ERR_TIME_ERROR                     = -45036,
    ADI_ERR_EMPTY_HARDWARE_IDS             = -45046,
    ADI_ERR_FILESYSTEM_ERROR               = -45054,
    ADI_ERR_NOT_PROVISIONED                = -45061,
    ADI_ERR_CANNOT_ERASE_NOT_PROVISIONED   = -45062,
    ADI_ERR_PENDING_SESSION                = -45063,
    ADI_ERR_SESSION_ALREADY_DONE           = -45066,
    ADI_ERR_LIBRARY_LOADING_FAILED         = -45075,
} AnisetteErrorCode;

const char* get_anisette_error_description(int32_t code);

void free_c_string(char *ptr);

int32_t get_anisette_headers_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *adi_pb,
    uint32_t adi_pb_len,
    char **out_json
);

int32_t start_provision_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *spim,
    uint32_t spim_len,
    char **out_json
);

int32_t end_provision_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session,
    const uint8_t *ptm,
    uint32_t ptm_len,
    const uint8_t *tk,
    uint32_t tk_len,
    char **out_json
);

int32_t cancel_provision_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session
);

int32_t get_anisette_headers_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *adi_pb,
    uint32_t adi_pb_len,
    char **out_json
);

int32_t start_provision_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *spim,
    uint32_t spim_len,
    char **out_json
);

int32_t end_provision_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session,
    const uint8_t *ptm,
    uint32_t ptm_len,
    const uint8_t *tk,
    uint32_t tk_len,
    char **out_json
);

int32_t cancel_provision_uc(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session
);

// logging methods
void anisetteCoreSetLogging(int enabled);
int  anisetteCoreIsLoggingEnabled(void);
void anisetteCoreLog(const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif /* ANISETTE_CORE_H */
