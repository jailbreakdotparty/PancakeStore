//
//  anisette_base.cpp
//  AnisetteKit
//
//  Created by Magesh K on 25/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "anisette_base.h"
#include "anisette_core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

const ADISymbols kADISymbols;

static int g_anisette_logging_enabled = 0;

extern "C" {

void anisetteCoreSetLogging(int enabled) {
    g_anisette_logging_enabled = enabled;
}

int anisetteCoreIsLoggingEnabled(void) {
    return g_anisette_logging_enabled;
}

void anisetteCoreLog(const char* fmt, ...) {
    if (!g_anisette_logging_enabled) return;
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    fflush(stdout);
}

const char* get_anisette_error_description(int32_t code) {
    switch (code) {
        case ANISETTE_OK:                          return "Success";
        case ANISETTE_ERR_INVALID_ARGUMENT:        return "Invalid argument passed";
        case ANISETTE_ERR_LOADER_FAILED:           return "ELF Loader failed to map dependencies";
        case ANISETTE_ERR_SYMBOL_MISSING:          return "Required ADI symbol missing";
        case ANISETTE_ERR_READ_FILE_FAILED:        return "Failed to read generated file";
        case ANISETTE_ERR_INVALID_JSON_RESPONSE:   return "Failed to parse response JSON";
        case ADI_ERR_INVALID_PARAMS:               return "Invalid ADI parameters (-45001)";
        case ADI_ERR_INVALID_PARAMS_DECIPHER:      return "Invalid ADI decipher params (-45002)";
        case ADI_ERR_INVALID_TRUST_KEY:            return "Invalid ADI trust key (-45003)";
        case ADI_ERR_PTM_TK_MISMATCH:              return "PTM and TK mismatch (-45006)";
        case ADI_ERR_INVALID_INPUT_HEADER:         return "Invalid input header (-45018)";
        case ADI_ERR_UNKNOWN_ADI_FUNCTION:         return "Unknown ADI function (-45019)";
        case ADI_ERR_INVALID_INPUT_BODY:           return "Invalid input body (-45020)";
        case ADI_ERR_UNKNOWN_SESSION:              return "Unknown ADI session (-45025)";
        case ADI_ERR_EMPTY_SESSION:                return "Empty ADI session (-45026)";
        case ADI_ERR_INVALID_DATA_HEADER:          return "Invalid data header (-45031)";
        case ADI_ERR_DATA_TOO_SHORT:               return "Data too short (-45032)";
        case ADI_ERR_INVALID_DATA_BODY:            return "Invalid data body (-45033)";
        case ADI_ERR_UNKNOWN_CALL_FLAGS:           return "Unknown call flags (-45034)";
        case ADI_ERR_TIME_ERROR:                   return "ADI time error (-45036)";
        case ADI_ERR_EMPTY_HARDWARE_IDS:           return "Empty hardware IDs (-45046)";
        case ADI_ERR_FILESYSTEM_ERROR:             return "ADI filesystem error (-45054)";
        case ADI_ERR_NOT_PROVISIONED:              return "Device not provisioned (-45061)";
        case ADI_ERR_CANNOT_ERASE_NOT_PROVISIONED: return "Cannot erase unprovisioned device (-45062)";
        case ADI_ERR_PENDING_SESSION:              return "Pending ADI session (-45063)";
        case ADI_ERR_SESSION_ALREADY_DONE:         return "ADI session already done (-45066)";
        case ADI_ERR_LIBRARY_LOADING_FAILED:       return "Library loading failed (-45075)";
        default:                                   return "Unknown ADI error";
    }
}

void free_c_string(char *ptr) {
    if (ptr) {
        free(ptr);
    }
}

}

std::string base64_encode(const uint8_t* input, size_t length) {
    if (!input || length == 0) return "";
    const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve((length + 2) / 3 * 4);
    
    size_t i = 0;
    while (i < length) {
        size_t chunk_len = (length - i >= 3) ? 3 : (length - i);
        uint32_t b = 0;
        for (size_t j = 0; j < chunk_len; j++) {
            b |= (uint32_t)input[i + j] << (16 - j * 8);
        }
        out.push_back(table[(b >> 18) & 63]);
        out.push_back(table[(b >> 12) & 63]);
        if (chunk_len > 1) {
            out.push_back(table[(b >> 6) & 63]);
        } else {
            out.push_back('=');
        }
        if (chunk_len > 2) {
            out.push_back(table[b & 63]);
        } else {
            out.push_back('=');
        }
        i += 3;
    }
    return out;
}

std::string format_uuid_string(const uint8_t* identifier) {
    if (!identifier) return "";
    char uuid_str[37];
    snprintf(uuid_str, sizeof(uuid_str),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        identifier[0], identifier[1], identifier[2], identifier[3],
        identifier[4], identifier[5], identifier[6], identifier[7],
        identifier[8], identifier[9], identifier[10], identifier[11],
        identifier[12], identifier[13], identifier[14], identifier[15]);
    return std::string(uuid_str);
}

std::string get_android_id_string(const uint8_t* uuid_bytes) {
    if (!uuid_bytes) return "";
    char buf[17];
    snprintf(buf, sizeof(buf),
             "%02X%02X%02X%02X%02X%02X%02X%02X",
             uuid_bytes[0], uuid_bytes[1], uuid_bytes[2], uuid_bytes[3],
             uuid_bytes[4], uuid_bytes[5], uuid_bytes[6], uuid_bytes[7]);
    return std::string(buf);
}
