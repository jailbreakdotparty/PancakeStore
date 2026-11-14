//
//  anisette_core_mac.cpp
//  AnisetteKit
//
//  Created by Magesh K on 20/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "anisette_core.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_OSX

#include "anisette_base.h"
#include "Loader/elf_loader_host.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <string>
#include <vector>
#include <sstream>
#include <sys/stat.h>

static ElfLoader* g_adi = nullptr;
static ElfLoader* g_ssc = nullptr;

static ElfLoader* load_adi_and_setup(const char* lib_dir, const char* provisioning_dir, const uint8_t* identifier, std::string& out_prov_path, std::string& out_err) {
    if (!lib_dir) {
        out_err = "Library directory path is null.";
        return nullptr;
    }
    struct stat st;
    if (stat(lib_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        out_err = std::string("Provided library path is not a valid directory: ") + lib_dir;
        return nullptr;
    }
    std::string lib_path(lib_dir);
    if (!lib_path.empty() && lib_path.back() != '/') lib_path += "/";
    std::string ssc_so     = lib_path + kADISymbols.lib_ssc;
    std::string coreadi_so = lib_path + kADISymbols.lib_core_adi;

    if (!g_adi) {
        g_ssc = new ElfLoader();
        if (!g_ssc->load(ssc_so)) {
            delete g_ssc; g_ssc = nullptr;
            out_err = "Failed to load libstoreservicescore.so at: " + ssc_so;
            return nullptr;
        }
        LOG("[AnisetteKit] libstoreservicescore.so loaded, %zu exports\n", g_ssc->exports.size());

        g_adi = new ElfLoader();
        if (!g_adi->load(coreadi_so)) {
            delete g_adi; g_adi = nullptr;
            delete g_ssc; g_ssc = nullptr;
            out_err = "Failed to load libCoreADI.so at: " + coreadi_so;
            return nullptr;
        }
        LOG("[AnisetteKit] libCoreADI.so loaded, %zu exports\n", g_adi->exports.size());

        g_ssc->add_sibling(g_adi);
        g_adi->add_sibling(g_ssc);

        g_ssc->relocate();
        g_adi->relocate();

        LOG("[AnisetteKit] Step 4: Resolving ADILoadLibraryWithPath (kq56gsgHG6)...\n");
        ADILoadLibraryWithPath load_lib = (ADILoadLibraryWithPath)get_adi_symbol(g_ssc, g_adi, kADISymbols.load_library, "ADILoadLibraryWithPath");
        if (!load_lib) {
            delete g_adi; g_adi = nullptr;
            delete g_ssc; g_ssc = nullptr;
            out_err = "Symbol ADILoadLibraryWithPath (kq56gsgHG6) missing from libraries";
            return nullptr;
        }

        LOG("[AnisetteKit] Executing ADILoadLibraryWithPath at %p (path=\"%s\")...\n", (void*)load_lib, lib_path.c_str());
        int32_t res = load_lib((const uint8_t*)lib_path.c_str(), nullptr);
        LOG("[AnisetteKit] ADILoadLibraryWithPath result = %d\n", res);
        if (res != 0) {
            delete g_adi; g_adi = nullptr;
            delete g_ssc; g_ssc = nullptr;
            out_err = "ADILoadLibraryWithPath (kq56gsgHG6) failed ("
                      + std::string(get_anisette_error_description(res)) + "): "
                      + std::to_string(res);
            return nullptr;
        }
    }

    std::string uuid = format_uuid_string(identifier);
    std::string uuid_prov_dir = std::string(provisioning_dir) + "/" + uuid;
    mkdir(uuid_prov_dir.c_str(), 0755);

    ADISetProvisioningPath set_prov = (ADISetProvisioningPath)get_adi_symbol(g_ssc, g_adi, kADISymbols.set_provisioning_path, "ADISetProvisioningPath");
    if (!set_prov) {
        out_err = "Symbol ADISetProvisioningPath (nf92ngaK92) missing";
        return nullptr;
    }
    LOG("[AnisetteKit] Calling ADISetProvisioningPath(\"%s\")...\n", uuid_prov_dir.c_str());
    int32_t res = set_prov((const uint8_t*)uuid_prov_dir.c_str());
    LOG("[AnisetteKit] ADISetProvisioningPath result = %d\n", res);
    if (res != 0) {
        out_err = "ADISetProvisioningPath failed ("
                  + std::string(get_anisette_error_description(res)) + "): "
                  + std::to_string(res);
        return nullptr;
    }

    ADISetAndroidId set_id = (ADISetAndroidId)get_adi_symbol(g_ssc, g_adi, kADISymbols.set_android_id, "ADISetAndroidID");
    if (!set_id) {
        out_err = "Symbol ADISetAndroidID (Sph98paBcz) missing";
        return nullptr;
    }
    std::string android_id = get_android_id_string(identifier);
    LOG("[AnisetteKit] Calling ADISetAndroidID(\"%s\", %zu)...\n", android_id.c_str(), android_id.length());
    res = set_id((const uint8_t*)android_id.c_str(), (uint32_t)android_id.length());
    LOG("[AnisetteKit] ADISetAndroidID result = %d\n", res);
    if (res != 0) {
        out_err = "ADISetAndroidID failed ("
                  + std::string(get_anisette_error_description(res)) + "): "
                  + std::to_string(res);
        return nullptr;
    }

    out_prov_path = uuid_prov_dir;
    return g_adi;
}

extern "C" {

int32_t get_anisette_headers_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *adi_pb,
    uint32_t adi_pb_len,
    char **out_json
) {
    std::string prov_dir, err;
    ElfLoader* adi = load_adi_and_setup(lib_dir, provisioning_dir, identifier, prov_dir, err);
    if (!adi) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }
    ElfLoader* ssc = !adi->siblings.empty() ? adi->siblings[0] : nullptr;

    std::string adi_pb_path = prov_dir + "/" + kADISymbols.adi_pb_filename;
    FILE* f = fopen(adi_pb_path.c_str(), "wb");
    if (f) {
        fwrite(adi_pb, 1, adi_pb_len, f);
        fclose(f);
    }

    ADIOtpRequest otp_req = (ADIOtpRequest)get_adi_symbol(ssc, adi, kADISymbols.otp_request, "ADIOTPRequest");
    if (!otp_req) {
        *out_json = strdup("{\"error\":\"Symbol ADIOTPRequest missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    const uint8_t* out_mid = nullptr;
    uint32_t out_mid_len = 0;
    const uint8_t* out_otp = nullptr;
    uint32_t out_otp_len = 0;

    LOG("[AnisetteKit] Calling ADIOTPRequest(dsid=-2)...\n");
    int32_t res = otp_req(-2, &out_mid, &out_mid_len, &out_otp, &out_otp_len);
    LOG("[AnisetteKit] ADIOTPRequest result = %d  mid_len=%u  otp_len=%u\n",
        res, out_mid_len, out_otp_len);
    if (res != 0) {
        std::stringstream ss;
        ss << "{\"error\":\"ADIOTPRequest failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    std::string mid = base64_encode(out_mid, out_mid_len);
    std::string otp = base64_encode(out_otp, out_otp_len);

    std::stringstream ss;
    ss << "{\"X-Apple-I-MD-M\":\"" << mid
       << "\",\"X-Apple-I-MD\":\"" << otp
       << "\",\"X-Apple-I-MD-RINFO\":\"" << kAppleRoutingInfoDefault << "\"}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

int32_t start_provision_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    const uint8_t *spim,
    uint32_t spim_len,
    char **out_json
) {
    std::string prov_dir, err;
    ElfLoader* adi = load_adi_and_setup(lib_dir, provisioning_dir, identifier, prov_dir, err);
    if (!adi) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }
    ElfLoader* ssc = !adi->siblings.empty() ? adi->siblings[0] : nullptr;

    ADIProvisioningStart prov_start = (ADIProvisioningStart)get_adi_symbol(ssc, adi, kADISymbols.provisioning_start, "ADIProvisioningStart");
    if (!prov_start) {
        *out_json = strdup("{\"error\":\"Symbol ADIProvisioningStart missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    const uint8_t* out_cpim = nullptr;
    uint32_t out_cpim_len = 0;
    uint32_t session = 0;

    LOG("[AnisetteKit] Calling ADIProvisioningStart(dsid=-2, spim_len=%u)...\n", spim_len);
    int32_t res = prov_start(-2, spim, spim_len, &out_cpim, &out_cpim_len, &session);
    LOG("[AnisetteKit] ADIProvisioningStart result = %d  session=%u  cpim_len=%u\n",
        res, session, out_cpim_len);
    if (res != 0) {
        rmdir(prov_dir.c_str());
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningStart failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    std::string cpim = base64_encode(out_cpim, out_cpim_len);

    std::stringstream ss;
    ss << "{\"cpim_base64\":\"" << cpim << "\",\"session\":" << session << "}";
    *out_json = strdup(ss.str().c_str());

    return ANISETTE_OK;
}

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
) {
    std::string prov_dir, err;
    ElfLoader* adi = load_adi_and_setup(lib_dir, provisioning_dir, identifier, prov_dir, err);
    if (!adi) {
        std::stringstream ss;
        ss << "{\"error\":\"" << err << "\"}";
        *out_json = strdup(ss.str().c_str());
        return ANISETTE_ERR_LOADER_FAILED;
    }
    ElfLoader* ssc = !adi->siblings.empty() ? adi->siblings[0] : nullptr;

    ADIProvisioningEnd prov_end = (ADIProvisioningEnd)get_adi_symbol(ssc, adi, kADISymbols.provisioning_end, "ADIProvisioningEnd");
    if (!prov_end) {
        *out_json = strdup("{\"error\":\"Symbol ADIProvisioningEnd missing\"}");
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    LOG("[AnisetteKit] Calling ADIProvisioningEnd(session=%u, ptm_len=%u, tk_len=%u)...\n",
        session, ptm_len, tk_len);
    int32_t res = prov_end(session, ptm, ptm_len, tk, tk_len);
    LOG("[AnisetteKit] ADIProvisioningEnd result = %d\n", res);
    if (res != 0) {
        rmdir(prov_dir.c_str());
        std::stringstream ss;
        ss << "{\"error\":\"ADIProvisioningEnd failed ("
           << get_anisette_error_description(res) << "): " << res << "\"}";
        *out_json = strdup(ss.str().c_str());
        return res;
    }

    std::string adi_pb_path = prov_dir + "/" + kADISymbols.adi_pb_filename;
    FILE* f = fopen(adi_pb_path.c_str(), "rb");
    if (!f) {
        rmdir(prov_dir.c_str());
        *out_json = strdup("{\"error\":\"Failed to read generated adi.pb\"}");
        return ANISETTE_ERR_READ_FILE_FAILED;
    }

    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);

    std::vector<uint8_t> pb_data(size);
    fread(pb_data.data(), 1, size, f);
    fclose(f);

    std::string adi_pb = base64_encode(pb_data.data(), size);

    std::stringstream ss;
    ss << "{\"adi_pb_base64\":\"" << adi_pb << "\"}";
    *out_json = strdup(ss.str().c_str());

    unlink(adi_pb_path.c_str());
    rmdir(prov_dir.c_str());
    return ANISETTE_OK;
}

int32_t cancel_provision_c(
    const char *lib_dir,
    const char *provisioning_dir,
    const uint8_t *identifier,
    uint32_t session
) {
    std::string prov_dir, err;
    ElfLoader* adi = load_adi_and_setup(lib_dir, provisioning_dir, identifier, prov_dir, err);
    if (!adi) return ANISETTE_ERR_LOADER_FAILED;
    ElfLoader* ssc = !adi->siblings.empty() ? adi->siblings[0] : nullptr;

    ADIProvisioningDestroy destroy = (ADIProvisioningDestroy)get_adi_symbol(ssc, adi, kADISymbols.destroy_session, "ADIProvisioningDestroy");
    if (!destroy) {
        return ANISETTE_ERR_SYMBOL_MISSING;
    }

    LOG("[AnisetteKit] Calling ADIProvisioningDestroy(session=%u)...\n", session);
    int32_t res = destroy(session);
    rmdir(prov_dir.c_str());
    return res;
}

}

#endif
#endif
