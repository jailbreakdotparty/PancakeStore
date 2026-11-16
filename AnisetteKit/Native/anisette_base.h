//
//  anisette_base.h
//  AnisetteKit
//
//  Created by Magesh K on 25/07/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#ifndef ANISETTE_BASE_H
#define ANISETTE_BASE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/stat.h>
#include "anisette_core.h"

#ifdef st_atime
#undef st_atime
#endif
#ifdef st_atime_nsec
#undef st_atime_nsec
#endif
#ifdef st_mtime
#undef st_mtime
#endif
#ifdef st_mtime_nsec
#undef st_mtime_nsec
#endif
#ifdef st_ctime
#undef st_ctime
#endif
#ifdef st_ctime_nsec
#undef st_ctime_nsec
#endif

typedef uint64_t Elf64_Addr;
typedef uint64_t Elf64_Off;
typedef uint16_t Elf64_Half;
typedef uint32_t Elf64_Word;
typedef int32_t  Elf64_Sword;
typedef uint64_t Elf64_Xword;
typedef int64_t  Elf64_Sxword;

#ifndef EI_NIDENT
#define EI_NIDENT 16
#endif

typedef struct {
    unsigned char e_ident[EI_NIDENT];
    Elf64_Half    e_type;
    Elf64_Half    e_machine;
    Elf64_Word    e_version;
    Elf64_Addr    e_entry;
    Elf64_Off     e_phoff;
    Elf64_Off     e_shoff;
    Elf64_Word    e_flags;
    Elf64_Half    e_ehsize;
    Elf64_Half    e_phentsize;
    Elf64_Half    e_phnum;
    Elf64_Half    e_shentsize;
    Elf64_Half    e_shnum;
    Elf64_Half    e_shstrndx;
} Elf64_Ehdr;

typedef struct {
    Elf64_Word  p_type;
    Elf64_Word  p_flags;
    Elf64_Off   p_offset;
    Elf64_Addr  p_vaddr;
    Elf64_Addr  p_paddr;
    Elf64_Xword p_filesz;
    Elf64_Xword p_memsz;
    Elf64_Xword p_align;
} Elf64_Phdr;

#ifndef PT_LOAD
#define PT_LOAD    1
#define PT_DYNAMIC 2
#endif

typedef struct {
    Elf64_Sxword d_tag;
    union {
        Elf64_Xword d_val;
        Elf64_Addr  d_ptr;
    } d_un;
} Elf64_Dyn;

#ifndef DT_NULL
#define DT_NULL     0
#define DT_NEEDED   1
#define DT_PLTRELSZ 2
#define DT_HASH     4
#define DT_STRTAB   5
#define DT_SYMTAB   6
#define DT_RELA     7
#define DT_RELASZ   8
#define DT_RELAENT  9
#define DT_STRSZ    10
#define DT_SYMENT   11
#define DT_INIT     12
#define DT_FINI     13
#define DT_SONAME   14
#define DT_REL      17
#define DT_RELSZ    18
#define DT_PLTREL   20
#define DT_JMPREL   23
#define DT_INIT_ARRAY 25
#define DT_INIT_ARRAYSZ 27
#endif

typedef struct {
    Elf64_Word    st_name;
    unsigned char st_info;
    unsigned char st_other;
    Elf64_Half    st_shndx;
    Elf64_Addr    st_value;
    Elf64_Xword   st_size;
} Elf64_Sym;

typedef struct {
    Elf64_Addr  r_offset;
    Elf64_Xword r_info;
} Elf64_Rel;

typedef struct {
    Elf64_Addr   r_offset;
    Elf64_Xword  r_info;
    Elf64_Sxword r_addend;
} Elf64_Rela;

#ifndef ELF64_R_SYM
#define ELF64_R_SYM(i)    ((i) >> 32)
#define ELF64_R_TYPE(i)   ((i) & 0xffffffffL)
#endif

#ifndef R_AARCH64_ABS64
#define R_AARCH64_ABS64      257
#define R_AARCH64_GLOB_DAT   1025
#define R_AARCH64_JUMP_SLOT  1026
#define R_AARCH64_RELATIVE   1027
#endif

#ifndef PF_X
#define PF_X 1
#define PF_W 2
#define PF_R 4
#endif

struct android_stat64 {
    uint64_t st_dev;
    uint64_t st_ino;
    uint32_t st_mode;
    uint32_t st_nlink;
    uint32_t st_uid;
    uint32_t st_gid;
    uint64_t st_rdev;
    uint64_t __pad1;
    int64_t  st_size;
    int32_t  st_blksize;
    int32_t  __pad2;
    int64_t  st_blocks;
    int64_t  st_atime;
    uint64_t st_atime_nsec;
    int64_t  st_mtime;
    uint64_t st_mtime_nsec;
    int64_t  st_ctime;
    uint64_t st_ctime_nsec;
    uint32_t __unused4;
    uint32_t __unused5;
};

typedef struct android_stat64 StatLinux;

typedef int32_t (*ADILoadLibraryWithPath)(const uint8_t* path, void* reserved_context);
typedef int32_t (*ADISetAndroidId)(const uint8_t* id, uint32_t len);
typedef int32_t (*ADISetProvisioningPath)(const uint8_t* path);
typedef int32_t (*ADIProvisioningStart)(int64_t ds_id, const uint8_t* spim, uint32_t spim_len, const uint8_t** out_cpim, uint32_t* out_cpim_len, uint32_t* out_session);
typedef int32_t (*ADIProvisioningEnd)(uint32_t session, const uint8_t* ptm, uint32_t ptm_len, const uint8_t* tk, uint32_t tk_len);
typedef int32_t (*ADIProvisioningDestroy)(uint32_t session);
typedef int32_t (*ADIOtpRequest)(int64_t ds_id, const uint8_t** out_mid, uint32_t* out_mid_size, const uint8_t** out_otp, uint32_t* out_otp_size);
typedef int32_t (*ADIDispose)(const uint8_t* ptr);

#ifdef __cplusplus
#include <string>

struct ADISymbols {
    const char* set_android_id        = "Sph98paBcz";
    const char* set_provisioning_path = "nf92ngaK92";
    const char* load_library          = "kq56gsgHG6";
    const char* otp_request           = "qi864985u0";
    const char* provisioning_start    = "rsegvyrt87";
    const char* provisioning_end      = "uv5t6nhkui";
    const char* destroy_session       = "n388H58b";
    const char* dispose               = "p435345l3";

    const char* lib_ssc               = "libstoreservicescore.so";
    const char* lib_core_adi          = "libCoreADI.so";
    const char* adi_pb_filename       = "adi.pb";
};

extern const ADISymbols kADISymbols;

static const char* const kAppleRoutingInfoDefault = "17106176";
static const char* const kAppleLocalUserDefault   = "0000000000000000000000000000000000000000000000000000000000000001";

std::string base64_encode(const uint8_t* input, size_t length);
std::string format_uuid_string(const uint8_t* identifier);
std::string get_android_id_string(const uint8_t* uuid_bytes);
#endif

#endif /* ANISETTE_BASE_H */
