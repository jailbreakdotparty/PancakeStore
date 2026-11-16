//
//  elf_loader_host.cpp
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "elf_loader_host.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_OSX

#include "anisette_base.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <ctype.h>
#include <string>
#include <vector>
#include <map>
#include <sstream>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>

static inline const char* format_errno_suffix(int err) {
    static thread_local char buf[32];
    if (err == 0) return "";
    snprintf(buf, sizeof(buf), ", errno %d", err);
    return buf;
}

extern "C" {
    int hook_open(const char* path, int flags, int mode) {
        int mac_flags = 0;
        mac_flags |= (flags & 3);
        if (flags & 0x0040)  mac_flags |= O_CREAT;
        if (flags & 0x0080)  mac_flags |= O_EXCL;
        if (flags & 0x0200)  mac_flags |= O_TRUNC;
        if (flags & 0x0400)  mac_flags |= O_APPEND;
        if (flags & 0x80000) mac_flags |= O_CLOEXEC;

        int fd = open(path, mac_flags, mode);
        int saved_errno = (fd < 0) ? errno : 0;
        LOG("[AnisetteKit] hook_open: '%s' (linux_flags=0x%x -> mac_flags=0x%x, mode=0%o) -> fd %d%s\n",
            path ? path : "<null>", flags, mac_flags, mode, fd, format_errno_suffix(saved_errno));
        errno = saved_errno;
        return fd;
    }

    int hook_mkdir(const char* path, mode_t mode) {
        int res = ::mkdir(path, mode);
        int saved_errno = (res != 0) ? errno : 0;
        if (res != 0 && saved_errno == EEXIST) {
            errno = 0;
            res = 0;
            saved_errno = 0;
        }
        LOG("[AnisetteKit] hook_mkdir: '%s' -> res %d%s\n", path ? path : "<null>", res, format_errno_suffix(saved_errno));
        errno = saved_errno;
        return res;
    }

    int hook_chmod(const char* path, mode_t mode) {
        int res = ::chmod(path, mode);
        int saved_errno = (res != 0) ? errno : 0;
        LOG("[AnisetteKit] hook_chmod: '%s' -> res %d%s\n", path ? path : "<null>", res, format_errno_suffix(saved_errno));
        errno = saved_errno;
        return res;
    }

    int hook_fstat(int fd, StatLinux* buf) {
        struct stat st;
        int res = ::fstat(fd, &st);
        int saved_errno = (res != 0) ? errno : 0;
        LOG("[AnisetteKit] hook_fstat: fd %d -> res %d%s\n", fd, res, format_errno_suffix(saved_errno));
        errno = saved_errno;
        if (res != 0) return res;

        memset(buf, 0, sizeof(StatLinux));
        buf->st_dev     = st.st_dev;
        buf->st_ino     = st.st_ino;
        buf->st_nlink   = st.st_nlink;
        buf->st_mode    = st.st_mode;
        buf->st_uid     = st.st_uid;
        buf->st_gid     = st.st_gid;
        buf->st_rdev    = st.st_rdev;
        buf->st_size    = st.st_size;
        buf->st_blksize = st.st_blksize;
        buf->st_blocks  = st.st_blocks;
#if defined(__APPLE__) || defined(__MACH__)
        buf->st_atime      = st.st_atimespec.tv_sec;
        buf->st_atime_nsec = st.st_atimespec.tv_nsec;
        buf->st_mtime      = st.st_mtimespec.tv_sec;
        buf->st_mtime_nsec = st.st_mtimespec.tv_nsec;
        buf->st_ctime      = st.st_ctimespec.tv_sec;
        buf->st_ctime_nsec = st.st_ctimespec.tv_nsec;
#elif defined(_WIN32)
        buf->st_atime      = (int64_t)st.st_atime;
        buf->st_atime_nsec = 0;
        buf->st_mtime      = (int64_t)st.st_mtime;
        buf->st_mtime_nsec = 0;
        buf->st_ctime      = (int64_t)st.st_ctime;
        buf->st_ctime_nsec = 0;
#else
        buf->st_atime      = (int64_t)st.st_atim.tv_sec;
        buf->st_atime_nsec = (uint64_t)st.st_atim.tv_nsec;
        buf->st_mtime      = (int64_t)st.st_mtim.tv_sec;
        buf->st_mtime_nsec = (uint64_t)st.st_mtim.tv_nsec;
        buf->st_ctime      = (int64_t)st.st_ctim.tv_sec;
        buf->st_ctime_nsec = (uint64_t)st.st_ctim.tv_nsec;
#endif
        return 0;
    }

    int hook_lstat(const char* path, StatLinux* buf) {
        struct stat st;
        int res = ::lstat(path, &st);
        int saved_errno = (res != 0) ? errno : 0;
        LOG("[AnisetteKit] hook_lstat: '%s' -> res %d%s\n", path ? path : "<null>", res, format_errno_suffix(saved_errno));
        errno = saved_errno;
        if (res != 0) return res;

        memset(buf, 0, sizeof(StatLinux));
        buf->st_dev     = st.st_dev;
        buf->st_ino     = st.st_ino;
        buf->st_nlink   = st.st_nlink;
        buf->st_mode    = st.st_mode;
        buf->st_uid     = st.st_uid;
        buf->st_gid     = st.st_gid;
        buf->st_rdev    = st.st_rdev;
        buf->st_size    = st.st_size;
        buf->st_blksize = st.st_blksize;
        buf->st_blocks  = st.st_blocks;
#if defined(__APPLE__) || defined(__MACH__)
        buf->st_atime      = st.st_atimespec.tv_sec;
        buf->st_atime_nsec = st.st_atimespec.tv_nsec;
        buf->st_mtime      = st.st_mtimespec.tv_sec;
        buf->st_mtime_nsec = st.st_mtimespec.tv_nsec;
        buf->st_ctime      = st.st_ctimespec.tv_sec;
        buf->st_ctime_nsec = st.st_ctimespec.tv_nsec;
#elif defined(_WIN32)
        buf->st_atime      = (int64_t)st.st_atime;
        buf->st_atime_nsec = 0;
        buf->st_mtime      = (int64_t)st.st_mtime;
        buf->st_mtime_nsec = 0;
        buf->st_ctime      = (int64_t)st.st_ctime;
        buf->st_ctime_nsec = 0;
#else
        buf->st_atime      = (int64_t)st.st_atim.tv_sec;
        buf->st_atime_nsec = (uint64_t)st.st_atim.tv_nsec;
        buf->st_mtime      = (int64_t)st.st_mtim.tv_sec;
        buf->st_mtime_nsec = (uint64_t)st.st_mtim.tv_nsec;
        buf->st_ctime      = (int64_t)st.st_ctim.tv_sec;
        buf->st_ctime_nsec = (uint64_t)st.st_ctim.tv_nsec;
#endif
        return 0;
    }

    int* hook_errno() {
#if defined(__APPLE__)
        return __error();
#elif defined(_WIN32)
        return _errno();
#else
        return __errno_location();
#endif
    }
}

static void dummy_stub_function() {
    void* caller = __builtin_return_address(0);
    LOG("[ElfLoader] WARNING: Unresolved dummy stub function invoked from caller %p!\n", caller);
}

static int hook_system_property_get(const char* name, char* value) {
    LOG("[ElfLoader] hook_system_property_get: '%s'\n", name ? name : "");
    if (value) value[0] = '\0';
    return 0;
}

static int hook_android_log_print(int prio, const char* tag, const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char buf[2048];
    vsnprintf(buf, sizeof(buf), fmt ? fmt : "", args);
    va_end(args);
    LOG("[AndroidLog] [%s] %s\n", tag ? tag : "ADI", buf);
    return 0;
}

typedef void (*pthread_jit_write_protect_np_t)(int);
typedef int (*pthread_jit_write_protect_supported_np_t)(void);
static void set_jit_write_protect(int enabled) {
#if defined(__APPLE__) && defined(__aarch64__)
#if TARGET_OS_SIMULATOR || (defined(TARGET_OS_OSX) && TARGET_OS_OSX && !defined(TARGET_OS_MACCATALYST))
    static pthread_jit_write_protect_supported_np_t p_supp = (pthread_jit_write_protect_supported_np_t)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_supported_np");
    static pthread_jit_write_protect_np_t p_func = (pthread_jit_write_protect_np_t)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
    if (p_supp && p_supp() && p_func) {
        p_func(enabled);
    }
#else
    (void)enabled;
#endif
#else
    (void)enabled;
#endif
}

static std::map<std::string, ElfLoader*>& get_loaded_libraries_map() {
    static std::map<std::string, ElfLoader*> s_map;
    return s_map;
}

static void* lookup_hook(const std::string& name);
static void init_bionic_ctype();

ElfLoader::ElfLoader() : base_addr(nullptr), data_addr(nullptr), total_size(0),
              code_size(0), data_size(0),
              rela_ptr(nullptr), rela_sz(0),
              rel_ptr(nullptr), rel_sz(0),
              jmprel_ptr(nullptr), pltrel_sz(0),
              pltrel_kind(0), sym_tab(nullptr),
              str_tab(nullptr), sym_cnt(0) {}

ElfLoader::~ElfLoader() {
    if (base_addr) {
        munmap(base_addr, total_size);
    }
    if (data_addr) {
        munmap(data_addr, data_size);
    }
    auto& map = get_loaded_libraries_map();
    for (auto it = map.begin(); it != map.end(); ) {
        if (it->second == this) {
            it = map.erase(it);
        } else {
            ++it;
        }
    }
}

void ElfLoader::add_sibling(ElfLoader* sib) {
    siblings.push_back(sib);
}

void ElfLoader::relocate() {
    if (!base_addr || !sym_tab || !str_tab) return;

    uintptr_t base = (uintptr_t)base_addr;
    Elf64_Sym* symtab = sym_tab;
    const char* strtab = str_tab;
    size_t sym_count = sym_cnt;
    const void* rela = rela_ptr;
    size_t relasz = rela_sz;
    const void* rel = rel_ptr;
    size_t relsz = rel_sz;
    const void* jmprel = jmprel_ptr;
    size_t pltrelsz = pltrel_sz;
    uint64_t pltrel_type = pltrel_kind;

    int unresolved_count = 0;
    auto resolve_symbol = [&](uint32_t sym_idx) -> void* {
        if (sym_idx >= sym_count) return nullptr;
        Elf64_Sym* sym = &symtab[sym_idx];
        if (sym->st_value != 0) {
            return (void*)(base + sym->st_value);
        }
        const char* raw_name = strtab + sym->st_name;
        if (raw_name && raw_name[0] != '\0') {
            std::string name(raw_name);
            auto it_local = exports.find(name);
            if (it_local != exports.end()) return it_local->second;
            for (ElfLoader* sib : siblings) {
                auto it_sib = sib->exports.find(name);
                if (it_sib != sib->exports.end()) return it_sib->second;
            }

            std::string converted = name;
            size_t pos = converted.find("6__ndk1");
            if (pos != std::string::npos) {
                converted.replace(pos, 7, "3__1");
            } else {
                pos = converted.find("__ndk1");
                if (pos != std::string::npos) {
                    converted.replace(pos, 6, "__1");
                }
            }
            if (converted != name) {
                auto it_c_local = exports.find(converted);
                if (it_c_local != exports.end()) return it_c_local->second;
                for (ElfLoader* sib : siblings) {
                    auto it_c_sib = sib->exports.find(converted);
                    if (it_c_sib != sib->exports.end()) return it_c_sib->second;
                }
            }
        }
        void* hooked = lookup_hook(raw_name);
        if (hooked) return hooked;
        LOG("[ElfLoader]   UNRESOLVED symbol: %s -> using dummy_stub\n", raw_name);
        unresolved_count++;
        return (void*)&dummy_stub_function;
    };

    auto apply_rela = [&](const void* table_ptr, size_t size_bytes, const char* label) {
        if (!table_ptr) return;
        const Elf64_Rela* table = (const Elf64_Rela*)table_ptr;
        size_t count = size_bytes / sizeof(Elf64_Rela);
        LOG("[ElfLoader] Applying %zu %s (RELA) relocations...\n", count, label);
        size_t applied = 0, skipped = 0;
        for (size_t i = 0; i < count; i++) {
            const Elf64_Rela* r = &table[i];
            uintptr_t* target = (uintptr_t*)(base + r->r_offset);
            uint32_t type = ELF64_R_TYPE(r->r_info);
            uint32_t sym_idx = ELF64_R_SYM(r->r_info);
            switch (type) {
                case R_AARCH64_RELATIVE:
                    *target = base + r->r_addend;
                    applied++; break;
                case R_AARCH64_ABS64: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr + r->r_addend;
                    applied++; break;
                }
                case R_AARCH64_GLOB_DAT:
                case R_AARCH64_JUMP_SLOT: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr;
                    applied++; break;
                }
                default:
                    skipped++; break;
            }
        }
        LOG("[ElfLoader] %s RELA: applied=%zu skipped=%zu unresolved_syms=%d\n",
            label, applied, skipped, unresolved_count);
    };

    auto apply_rel = [&](const void* table_ptr, size_t size_bytes, const char* label) {
        if (!table_ptr) return;
        const Elf64_Rel* table = (const Elf64_Rel*)table_ptr;
        size_t count = size_bytes / sizeof(Elf64_Rel);
        LOG("[ElfLoader] Applying %zu %s (REL 16-byte) relocations...\n", count, label);
        size_t applied = 0, skipped = 0;
        for (size_t i = 0; i < count; i++) {
            const Elf64_Rel* r = &table[i];
            uintptr_t* target = (uintptr_t*)(base + r->r_offset);
            uint32_t type = ELF64_R_TYPE(r->r_info);
            uint32_t sym_idx = ELF64_R_SYM(r->r_info);
            int64_t implicit_addend = (int64_t)(*target);
            switch (type) {
                case R_AARCH64_RELATIVE:
                    *target = base + implicit_addend;
                    applied++; break;
                case R_AARCH64_ABS64: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr + implicit_addend;
                    applied++; break;
                }
                case R_AARCH64_GLOB_DAT:
                case R_AARCH64_JUMP_SLOT: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr;
                    applied++; break;
                }
                default:
                    skipped++; break;
            }
        }
        LOG("[ElfLoader] %s REL: applied=%zu skipped=%zu unresolved_syms=%d\n",
            label, applied, skipped, unresolved_count);
    };

    if (rela && relasz > 0) apply_rela(rela, relasz, "RELA");
    if (rel && relsz > 0) apply_rel(rel, relsz, "REL");
    if (jmprel && pltrelsz > 0) {
        if (pltrel_type == DT_REL) {
            apply_rel(jmprel, pltrelsz, "JMPREL/PLT");
        } else {
            apply_rela(jmprel, pltrelsz, "JMPREL/PLT");
        }
    }

    uintptr_t b = (uintptr_t)base_addr;
    size_t page_sz = (size_t)getpagesize();
    LOG("[ElfLoader] Applying W^X per-segment protections (page_size=%zu)...\n", page_sz);
    for (const auto& seg : segments) {
        bool has_exec  = (seg.flags & 0x1) != 0;
        bool has_write = (seg.flags & 0x2) != 0;
        if (has_exec && !has_write) {
            uintptr_t seg_base = b + seg.vaddr;
            uintptr_t page_start = seg_base & ~(page_sz - 1);
            size_t offset = seg_base - page_start;
            size_t seg_sz = (seg.memsz + offset + page_sz - 1) & ~(page_sz - 1);

#ifdef __APPLE__
            kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page_start, (vm_size_t)seg_sz, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
            LOG("[ElfLoader] mach vm_protect R+X page_start=0x%lx size=0x%lx -> kr=%d\n",
                (unsigned long)page_start, (unsigned long)seg_sz, (int)kr);
            if (kr != KERN_SUCCESS) {
                int res = mprotect((void*)page_start, seg_sz, PROT_READ | PROT_EXEC);
                LOG("[ElfLoader] mprotect fallback R+X page_start=0x%lx size=0x%lx -> res=%d (errno=%d)\n",
                    (unsigned long)page_start, (unsigned long)seg_sz, res, res == -1 ? errno : 0);
            }
#else
            int res = mprotect((void*)page_start, seg_sz, PROT_READ | PROT_EXEC);
            LOG("[ElfLoader] mprotect R+X page_start=0x%lx size=0x%lx -> res=%d (errno=%d)\n",
                (unsigned long)page_start, (unsigned long)seg_sz, res, res == -1 ? errno : 0);
#endif
        }
    }
    LOG("[ElfLoader] W^X protection complete.\n");
}

bool ElfLoader::load(const std::string& path) {
    init_bionic_ctype();
    set_jit_write_protect(0);
    LOG("[ElfLoader] Loading: %s\n", path.c_str());
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) {
        LOG("[ElfLoader] ERROR: fopen failed for %s\n", path.c_str());
        return false;
    }

    fseek(f, 0, SEEK_END);
    size_t file_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    LOG("[ElfLoader] File size: %zu bytes\n", file_size);

    std::vector<uint8_t> bytes(file_size);
    if (fread(bytes.data(), 1, file_size, f) != file_size) {
        LOG("[ElfLoader] ERROR: fread failed\n");
        fclose(f);
        return false;
    }
    fclose(f);

    if (file_size < sizeof(Elf64_Ehdr)) {
        LOG("[ElfLoader] ERROR: file too small for ELF header\n");
        return false;
    }
    Elf64_Ehdr* ehdr = (Elf64_Ehdr*)bytes.data();

    bool magic_ok = memcmp(ehdr->e_ident, "\x7f\x45\x4c\x46", 4) == 0;
    LOG("[ElfLoader] ELF magic: %s | class: %d (2=64bit) | machine: %d (183=ARM64) | type: %d (3=SO)\n",
           magic_ok ? "OK" : "BAD", ehdr->e_ident[4], ehdr->e_machine, ehdr->e_type);
    if (!magic_ok || ehdr->e_machine != 183) {
        LOG("[ElfLoader] ERROR: Not a valid ARM64 ELF\n");
        return false;
    }

    size_t min_vaddr = SIZE_MAX;
    size_t max_vaddr = 0;
    bool has_load = false;
    LOG("[ElfLoader] Program headers (%d):\n", ehdr->e_phnum);
    for (int i = 0; i < ehdr->e_phnum; i++) {
        Elf64_Phdr* phdr = (Elf64_Phdr*)(bytes.data() + ehdr->e_phoff + i * ehdr->e_phentsize);
        LOG("[ElfLoader]   phdr[%d] type=%u offset=0x%llx vaddr=0x%llx filesz=0x%llx memsz=0x%llx flags=0x%x\n",
            i, phdr->p_type, (unsigned long long)phdr->p_offset,
            (unsigned long long)phdr->p_vaddr, (unsigned long long)phdr->p_filesz,
            (unsigned long long)phdr->p_memsz, phdr->p_flags);
        if (phdr->p_type == PT_LOAD) {
            if (phdr->p_vaddr < min_vaddr) min_vaddr = phdr->p_vaddr;
            if (phdr->p_vaddr + phdr->p_memsz > max_vaddr) max_vaddr = phdr->p_vaddr + phdr->p_memsz;
            has_load = true;
        }
    }

    if (!has_load) {
        LOG("[ElfLoader] ERROR: No PT_LOAD segments found\n");
        return false;
    }
    total_size = max_vaddr - min_vaddr;
    LOG("[ElfLoader] Virtual range: 0x%zx - 0x%zx, total_size=%zu\n", min_vaddr, max_vaddr, total_size);

    {
        void* addr = mmap(NULL, total_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (addr == MAP_FAILED) {
            LOG("[ElfLoader] ERROR: mmap failed: %d\n", errno);
            return false;
        }
        base_addr = addr;
        code_size = total_size;
    }
    LOG("[ElfLoader] Allocated region via mmap at base=%p (size=%zu)\n", base_addr, total_size);

    uintptr_t base = (uintptr_t)base_addr;

    segments.clear();
    for (int i = 0; i < ehdr->e_phnum; i++) {
        Elf64_Phdr* phdr = (Elf64_Phdr*)(bytes.data() + ehdr->e_phoff + i * ehdr->e_phentsize);
        if (phdr->p_type == PT_LOAD) {
            segments.push_back({(uintptr_t)phdr->p_vaddr, (size_t)phdr->p_memsz, (uint32_t)phdr->p_flags});
            void* dest = (void*)(base + phdr->p_vaddr);
            memcpy(dest, bytes.data() + phdr->p_offset, phdr->p_filesz);
            if (phdr->p_memsz > phdr->p_filesz) {
                memset((uint8_t*)dest + phdr->p_filesz, 0, phdr->p_memsz - phdr->p_filesz);
            }
            LOG("[ElfLoader] Copied PT_LOAD vaddr=0x%llx → %p (%llu bytes) flags=0x%x\n",
                (unsigned long long)phdr->p_vaddr, dest,
                (unsigned long long)phdr->p_filesz, phdr->p_flags);
        }
    }

    if (total_size > 0x507c8) {
        uint32_t target_instr = *(uint32_t*)(base + 0x507c4);
        LOG("[ElfLoader] Verification: word at base+0x507c4 (cvu8io98wun) = 0x%08x\n",
            target_instr);
    }

    Elf64_Dyn* dyn = nullptr;
    for (int i = 0; i < ehdr->e_phnum; i++) {
        Elf64_Phdr* phdr = (Elf64_Phdr*)(bytes.data() + ehdr->e_phoff + i * ehdr->e_phentsize);
        if (phdr->p_type == PT_DYNAMIC) {
            dyn = (Elf64_Dyn*)(base + phdr->p_vaddr);
            LOG("[ElfLoader] PT_DYNAMIC at vaddr=0x%llx\n", (unsigned long long)phdr->p_vaddr);
            break;
        }
    }
    if (!dyn) {
        LOG("[ElfLoader] ERROR: No PT_DYNAMIC segment\n");
        return false;
    }

    Elf64_Sym* symtab = nullptr;
    const char* strtab = nullptr;
    void* rela = nullptr;
    size_t relasz = 0;
    void* rel = nullptr;
    size_t relsz = 0;
    void* jmprel = nullptr;
    size_t pltrelsz = 0;
    uint64_t pltrel_type = 0;
    uint32_t* hash = nullptr;
    uint32_t* gnu_hash = nullptr;
    int needed_count = 0;

    LOG("[ElfLoader] Dynamic table:\n");
    for (Elf64_Dyn* d = dyn; d->d_tag != DT_NULL; d++) {
        switch (d->d_tag) {
            case DT_NEEDED:   needed_count++; break;
            case DT_SYMTAB:   symtab   = (Elf64_Sym*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_SYMTAB  = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_STRTAB:   strtab   = (const char*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_STRTAB  = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_STRSZ:    LOG("[ElfLoader]   DT_STRSZ   = %llu\n", (unsigned long long)d->d_un.d_val); break;
            case DT_RELA:     rela     = (void*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_RELA    = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_RELASZ:   relasz   = d->d_un.d_val;
                              LOG("[ElfLoader]   DT_RELASZ  = %zu (%zu entries)\n", relasz, relasz/sizeof(Elf64_Rela)); break;
            case DT_REL:      rel      = (void*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_REL     = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_RELSZ:    relsz    = d->d_un.d_val;
                              LOG("[ElfLoader]   DT_RELSZ   = %zu (%zu entries)\n", relsz, relsz/sizeof(Elf64_Rel)); break;
            case DT_JMPREL:   jmprel   = (void*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_JMPREL  = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_PLTRELSZ: pltrelsz = d->d_un.d_val;
                              LOG("[ElfLoader]   DT_PLTRELSZ= %zu\n", pltrelsz); break;
            case DT_PLTREL:   pltrel_type = d->d_un.d_val;
                              LOG("[ElfLoader]   DT_PLTREL  = %llu (7=REL, 17=RELA)\n", (unsigned long long)pltrel_type); break;
            case DT_HASH:     hash     = (uint32_t*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_HASH    = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case 0x6ffffef5:  gnu_hash = (uint32_t*)(base + d->d_un.d_ptr);
                              LOG("[ElfLoader]   DT_GNU_HASH= 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_SONAME:   LOG("[ElfLoader]   DT_SONAME  = (index %llu)\n", (unsigned long long)d->d_un.d_val); break;
            case DT_INIT:     LOG("[ElfLoader]   DT_INIT    = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            case DT_FINI:     LOG("[ElfLoader]   DT_FINI    = 0x%llx\n", (unsigned long long)d->d_un.d_ptr); break;
            default:          LOG("[ElfLoader]   tag=0x%llx val=0x%llx\n",
                                     (unsigned long long)d->d_tag, (unsigned long long)d->d_un.d_val); break;
        }
    }

    if (strtab) {
        for (Elf64_Dyn* d = dyn; d->d_tag != DT_NULL; d++) {
            if (d->d_tag == DT_NEEDED) {
                LOG("[ElfLoader]   DT_NEEDED  = %s\n", strtab + d->d_un.d_val);
            }
        }
    }

    if (!symtab || !strtab) {
        LOG("[ElfLoader] ERROR: Missing DT_SYMTAB or DT_STRTAB\n");
        return false;
    }

    size_t sym_count = 0;
    if (hash) {
        sym_count = hash[1];
        LOG("[ElfLoader] DT_HASH: nbuckets=%u nchain(sym_count)=%u\n", hash[0], hash[1]);
    } else if (gnu_hash) {
        uint32_t nbuckets   = gnu_hash[0];
        uint32_t symoffset  = gnu_hash[1];
        uint32_t bloom_size = gnu_hash[2];
        uint32_t bloom_shift = gnu_hash[3];
        LOG("[ElfLoader] DT_GNU_HASH: nbuckets=%u symoffset=%u bloom_size=%u bloom_shift=%u\n",
               nbuckets, symoffset, bloom_size, bloom_shift);
        uint32_t* buckets = gnu_hash + 4 + bloom_size * 2;
        uint32_t* chains  = buckets + nbuckets;
        uint32_t max_idx = symoffset;
        for (uint32_t b = 0; b < nbuckets; b++) {
            if (buckets[b] > max_idx) max_idx = buckets[b];
        }
        if (max_idx >= symoffset) {
            uint32_t chain_idx = max_idx - symoffset;
            while (!(chains[chain_idx] & 1)) { chain_idx++; max_idx++; }
        }
        sym_count = max_idx + 1;
        LOG("[ElfLoader] GNU hash derived sym_count=%zu\n", sym_count);
    } else {
        LOG("[ElfLoader] WARNING: No hash table — fallback sequential scan\n");
        while (true) {
            Elf64_Sym* sym = &symtab[sym_count];
            if (sym->st_name == 0 && sym->st_value == 0 && sym_count > 0) break;
            sym_count++;
            if (sym_count > 10000) break;
        }
        LOG("[ElfLoader] Fallback sym_count=%zu\n", sym_count);
    }

    int unresolved_count = 0;
    auto resolve_symbol = [&](uint32_t sym_idx) -> void* {
        if (sym_idx >= sym_count) return nullptr;
        Elf64_Sym* sym = &symtab[sym_idx];
        if (sym->st_value != 0) {
            return (void*)(base + sym->st_value);
        }
        const char* name = strtab + sym->st_name;
        if (name && name[0] != '\0') {
            auto it_local = exports.find(name);
            if (it_local != exports.end()) return it_local->second;
            for (ElfLoader* sib : siblings) {
                auto it_sib = sib->exports.find(name);
                if (it_sib != sib->exports.end()) return it_sib->second;
            }
        }
        void* hooked = lookup_hook(name);
        if (hooked) return hooked;
        LOG("[ElfLoader]   UNRESOLVED symbol: %s\n", name);
        unresolved_count++;
        return nullptr;
    };

    auto apply_rela = [&](const void* table_ptr, size_t size_bytes, const char* label) {
        if (!table_ptr) return;
        const Elf64_Rela* table = (const Elf64_Rela*)table_ptr;
        size_t count = size_bytes / sizeof(Elf64_Rela);
        LOG("[ElfLoader] Applying %zu %s (RELA) relocations...\n", count, label);
        size_t applied = 0, skipped = 0;
        for (size_t i = 0; i < count; i++) {
            const Elf64_Rela* r = &table[i];
            uintptr_t* target = (uintptr_t*)(base + r->r_offset);
            uint32_t type = ELF64_R_TYPE(r->r_info);
            uint32_t sym_idx = ELF64_R_SYM(r->r_info);
            switch (type) {
                case R_AARCH64_RELATIVE:
                    *target = base + r->r_addend;
                    applied++; break;
                case R_AARCH64_ABS64: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr + r->r_addend;
                    applied++; break;
                }
                case R_AARCH64_GLOB_DAT:
                case R_AARCH64_JUMP_SLOT: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr;
                    applied++; break;
                }
                default:
                    LOG("[ElfLoader]   Unhandled RELA reloc type=%u at offset=0x%llx\n",
                           type, (unsigned long long)r->r_offset);
                    skipped++; break;
            }
        }
        LOG("[ElfLoader] %s RELA: applied=%zu skipped=%zu unresolved_syms=%d\n",
               label, applied, skipped, unresolved_count);
    };

    auto apply_rel = [&](const void* table_ptr, size_t size_bytes, const char* label) {
        if (!table_ptr) return;
        const Elf64_Rel* table = (const Elf64_Rel*)table_ptr;
        size_t count = size_bytes / sizeof(Elf64_Rel);
        LOG("[ElfLoader] Applying %zu %s (REL 16-byte) relocations...\n", count, label);
        size_t applied = 0, skipped = 0;
        for (size_t i = 0; i < count; i++) {
            const Elf64_Rel* r = &table[i];
            uintptr_t* target = (uintptr_t*)(base + r->r_offset);
            uint32_t type = ELF64_R_TYPE(r->r_info);
            uint32_t sym_idx = ELF64_R_SYM(r->r_info);
            int64_t implicit_addend = (int64_t)(*target);
            switch (type) {
                case R_AARCH64_RELATIVE:
                    *target = base + implicit_addend;
                    applied++; break;
                case R_AARCH64_ABS64: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr + implicit_addend;
                    applied++; break;
                }
                case R_AARCH64_GLOB_DAT:
                case R_AARCH64_JUMP_SLOT: {
                    void* addr = resolve_symbol(sym_idx);
                    *target = (uintptr_t)addr;
                    applied++; break;
                }
                default:
                    LOG("[ElfLoader]   Unhandled REL reloc type=%u at offset=0x%llx\n",
                           type, (unsigned long long)r->r_offset);
                    skipped++; break;
            }
        }
        LOG("[ElfLoader] %s REL: applied=%zu skipped=%zu unresolved_syms=%d\n",
               label, applied, skipped, unresolved_count);
    };

    if (gnu_hash) {
        uint32_t nbuckets   = gnu_hash[0];
        uint32_t symoffset  = gnu_hash[1];
        uint32_t bloom_size = gnu_hash[2];
        uint32_t* buckets   = gnu_hash + 4 + bloom_size * 2;
        uint32_t* chains    = buckets + nbuckets;
        for (uint32_t b = 0; b < nbuckets; b++) {
            uint32_t idx = buckets[b];
            if (idx == 0) continue;
            uint32_t chain_idx = idx - symoffset;
            while (true) {
                Elf64_Sym* sym = &symtab[idx];
                if (sym->st_value != 0) {
                    const char* name = strtab + sym->st_name;
                    exports[name] = (void*)(base + sym->st_value);
                }
                if (chains[chain_idx] & 1) break;
                chain_idx++; idx++;
            }
        }
    } else {
        for (size_t i = 0; i < sym_count; i++) {
            Elf64_Sym* sym = &symtab[i];
            if (sym->st_value != 0) {
                const char* name = strtab + sym->st_name;
                exports[name] = (void*)(base + sym->st_value);
            }
        }
    }

    rela_ptr = rela; rela_sz = relasz;
    rel_ptr = rel; rel_sz = relsz;
    jmprel_ptr = jmprel; pltrel_sz = pltrelsz;
    pltrel_kind = pltrel_type;
    sym_tab = symtab; str_tab = strtab; sym_cnt = sym_count;

    relocate();

    set_jit_write_protect(1);

    std::string filename = path;
    size_t slash = filename.find_last_of("/");
    if (slash != std::string::npos) {
        filename = filename.substr(slash + 1);
    }
    get_loaded_libraries_map()[path] = this;
    get_loaded_libraries_map()[filename] = this;
    LOG("[ElfLoader] Registered loader handle for '%s' and '%s' @ %p\n", path.c_str(), filename.c_str(), this);

    LOG("[ElfLoader] DONE loading '%s': %zu exports, %d unresolved imports\n",
           path.c_str(), exports.size(), unresolved_count);
    return true;
}

void* ElfLoader::get_symbol(const char* name) {
    if (!name) return nullptr;
    auto it = exports.find(name);
    if (it != exports.end()) {
        return it->second;
    }
    return nullptr;
}

static void* hook_dlopen(const char* filename, int flags) {
    if (!filename) return (void*)0xDEADBEEF;
    LOG("[ElfLoader] hook_dlopen: %s (flags=0x%x)\n", filename, flags);
    std::string path(filename);

    auto& map = get_loaded_libraries_map();
    for (auto& kv : map) {
        if (path == kv.first || path.find(kv.first) != std::string::npos || kv.first.find(path) != std::string::npos) {
            LOG("[ElfLoader] hook_dlopen resolved '%s' -> ElfLoader @ %p\n", filename, kv.second);
            return (void*)kv.second;
        }
    }

    void* host_handle = dlopen(filename, flags);
    if (host_handle) {
        LOG("[ElfLoader] hook_dlopen resolved '%s' via host dlopen -> %p\n", filename, host_handle);
        return host_handle;
    }

    LOG("[ElfLoader] hook_dlopen fallback dummy handle for '%s'\n", filename);
    return (void*)0xDEADBEEF;
}

static void* hook_dlsym(void* handle, const char* symbol) {
    LOG("[ElfLoader] hook_dlsym requested symbol '%s' for handle %p\n", symbol ? symbol : "<null>", handle);
    if (!symbol) return nullptr;

    auto& map = get_loaded_libraries_map();
    for (auto& kv : map) {
        if ((void*)kv.second == handle) {
            void* s = kv.second->get_symbol(symbol);
            if (s) {
                LOG("[ElfLoader] hook_dlsym found '%s' in %s @ %p\n", symbol, kv.first.c_str(), s);
                return s;
            }
        }
    }

    for (auto& kv : map) {
        void* s = kv.second->get_symbol(symbol);
        if (s) {
            LOG("[ElfLoader] hook_dlsym found '%s' across loaders in %s @ %p\n", symbol, kv.first.c_str(), s);
            return s;
        }
    }

    void* host_sym = dlsym(handle == (void*)0xDEADBEEF ? RTLD_DEFAULT : handle, symbol);
    if (host_sym) return host_sym;

    host_sym = dlsym(RTLD_DEFAULT, symbol);
    if (host_sym) return host_sym;

    void* hooked = lookup_hook(std::string(symbol));
    if (hooked) {
        LOG("[ElfLoader] hook_dlsym resolved '%s' via lookup_hook @ %p\n", symbol, hooked);
        return hooked;
    }

    LOG("[ElfLoader] hook_dlsym UNRESOLVED: %s -> dummy_stub\n", symbol);
    return (void*)&dummy_stub_function;
}

static int hook_dlclose(void* handle) {
    LOG("[ElfLoader] hook_dlclose: handle=%p\n", handle);
    return 0;
}

static char* hook_dlerror() {
    return nullptr;
}

static uintptr_t g_stack_chk_guard = 0xDEADBEEF;

static void hook_stack_chk_fail() {
    LOG("[ElfLoader] WARNING: __stack_chk_fail triggered!\n");
}

static uint16_t g_ctype_array[384] = {0};
static const uint16_t* g_ctype_ptr = &g_ctype_array[128];

static void init_bionic_ctype() {
    static bool initialized = false;
    if (initialized) return;
    initialized = true;

    for (int c = 0; c < 256; ++c) {
        uint16_t mask = 0;
        if (isupper(c)) mask |= 0x0001;
        if (islower(c)) mask |= 0x0002;
        if (isdigit(c)) mask |= 0x0004;
        if (isspace(c)) mask |= 0x0008;
        if (ispunct(c)) mask |= 0x0010;
        if (iscntrl(c)) mask |= 0x0020;
        if (isblank(c)) mask |= 0x0040;
        if (isxdigit(c)) mask |= 0x0080;
        g_ctype_array[128 + c] = mask;
    }
}

static char* g_dummy_environ[] = { nullptr };
static char** g_environ_ptr = g_dummy_environ;

struct dl_phdr_info_stub {
    Elf64_Addr dlpi_addr;
    const char* dlpi_name;
    const Elf64_Phdr* dlpi_phdr;
    Elf64_Half dlpi_phnum;
};

static int hook_dl_iterate_phdr(int (*callback)(void* info, size_t size, void* data), void* data) {
    LOG("[ElfLoader] hook_dl_iterate_phdr invoked\n");
    auto& map = get_loaded_libraries_map();
    for (auto& kv : map) {
        if (kv.second && kv.second->base_addr) {
            dl_phdr_info_stub info;
            info.dlpi_addr = (Elf64_Addr)kv.second->base_addr;
            info.dlpi_name = kv.first.c_str();
            info.dlpi_phdr = (const Elf64_Phdr*)((uintptr_t)kv.second->base_addr + 0x40);
            info.dlpi_phnum = 8;
            int res = callback(&info, sizeof(info), data);
            if (res != 0) return res;
        }
    }
    return 0;
}

static unsigned long hook_getauxval(unsigned long type) {
    LOG("[ElfLoader] hook_getauxval: type=%lu\n", type);
    return 0;
}

struct ThreadArg {
    void* (*start_routine)(void*);
    void* arg;
};

static void* pthread_wrapper(void* param) {
    ThreadArg* targ = (ThreadArg*)param;
    void* (*start_routine)(void*) = targ->start_routine;
    void* arg = targ->arg;
    delete targ;

    set_jit_write_protect(1);
    return start_routine(arg);
}

static int hook_pthread_create(pthread_t* thread, const pthread_attr_t* attr, void* (*start_routine)(void*), void* arg) {
    if (!start_routine) return 22;
    ThreadArg* targ = new ThreadArg{start_routine, arg};
    return pthread_create(thread, attr, pthread_wrapper, targ);
}
#include <mutex>
#include <map>

static std::map<void*, pthread_rwlock_t*> g_rwlock_map;
static std::mutex g_rwlock_mutex;

static pthread_rwlock_t* get_host_rwlock(void* guest_lock, bool create_if_missing = false) {
    std::lock_guard<std::mutex> lock(g_rwlock_mutex);
    auto it = g_rwlock_map.find(guest_lock);
    if (it != g_rwlock_map.end()) {
        return it->second;
    }
    if (create_if_missing) {
        pthread_rwlock_t* host_lock = (pthread_rwlock_t*)malloc(sizeof(pthread_rwlock_t));
        pthread_rwlock_init(host_lock, nullptr);
        g_rwlock_map[guest_lock] = host_lock;
        return host_lock;
    }
    return nullptr;
}

static int hook_pthread_rwlock_init(void* guest_lock, const void* attr) {
    get_host_rwlock(guest_lock, true);
    return 0;
}

static int hook_pthread_rwlock_rdlock(void* guest_lock) {
    pthread_rwlock_t* host_lock = get_host_rwlock(guest_lock, true);
    return pthread_rwlock_rdlock(host_lock);
}

static int hook_pthread_rwlock_wrlock(void* guest_lock) {
    pthread_rwlock_t* host_lock = get_host_rwlock(guest_lock, true);
    return pthread_rwlock_wrlock(host_lock);
}

static int hook_pthread_rwlock_unlock(void* guest_lock) {
    pthread_rwlock_t* host_lock = get_host_rwlock(guest_lock);
    if (host_lock) {
        return pthread_rwlock_unlock(host_lock);
    }
    return 0;
}

static int hook_pthread_rwlock_destroy(void* guest_lock) {
    std::lock_guard<std::mutex> lock(g_rwlock_mutex);
    auto it = g_rwlock_map.find(guest_lock);
    if (it != g_rwlock_map.end()) {
        pthread_rwlock_destroy(it->second);
        free(it->second);
        g_rwlock_map.erase(it);
    }
    return 0;
}

static void* lookup_hook(const std::string& name) {
    if (name == "open") return (void*)&hook_open;
    if (name == "mkdir") return (void*)&hook_mkdir;
    if (name == "chmod") return (void*)&hook_chmod;
    if (name == "fstat") return (void*)&hook_fstat;
    if (name == "lstat") return (void*)&hook_lstat;
    if (name == "__errno" || name == "__errno_location") return (void*)&hook_errno;
    if (name == "__system_property_get") return (void*)&hook_system_property_get;
    if (name == "__android_log_print") return (void*)&hook_android_log_print;
    if (name == "__stack_chk_guard") return (void*)&g_stack_chk_guard;
    if (name == "__stack_chk_fail") return (void*)&hook_stack_chk_fail;
    if (name == "__ctype_" || name == "_ctype_") {
        init_bionic_ctype();
        return (void*)&g_ctype_ptr;
    }
    if (name == "environ" || name == "__environment") return (void*)&g_environ_ptr;
    if (name == "dlopen") return (void*)&hook_dlopen;
    if (name == "dlsym") return (void*)&hook_dlsym;
    if (name == "dlclose") return (void*)&hook_dlclose;
    if (name == "dlerror") return (void*)&hook_dlerror;
    if (name == "dl_iterate_phdr") return (void*)&hook_dl_iterate_phdr;
    if (name == "getauxval") return (void*)&hook_getauxval;
    if (name == "pthread_create") return (void*)&hook_pthread_create;
    if (name == "pthread_rwlock_init") return (void*)&hook_pthread_rwlock_init;
    if (name == "pthread_rwlock_destroy") return (void*)&hook_pthread_rwlock_destroy;
    if (name == "pthread_rwlock_rdlock") return (void*)&hook_pthread_rwlock_rdlock;
    if (name == "pthread_rwlock_wrlock") return (void*)&hook_pthread_rwlock_wrlock;
    if (name == "pthread_rwlock_unlock") return (void*)&hook_pthread_rwlock_unlock;

    void* sym = dlsym(RTLD_DEFAULT, name.c_str());
    if (sym) return sym;

    std::string converted = name;
    size_t pos = converted.find("6__ndk1");
    if (pos != std::string::npos) {
        converted.replace(pos, 7, "3__1");
        sym = dlsym(RTLD_DEFAULT, converted.c_str());
        if (sym) {
            LOG("[ElfLoader] Resolved NDK symbol '%s' -> '%s' @ %p\n", name.c_str(), converted.c_str(), sym);
            return sym;
        }
    }
    converted = name;
    pos = converted.find("__ndk1");
    if (pos != std::string::npos) {
        converted.replace(pos, 6, "__1");
        sym = dlsym(RTLD_DEFAULT, converted.c_str());
        if (sym) {
            LOG("[ElfLoader] Resolved NDK symbol '%s' -> '%s' @ %p\n", name.c_str(), converted.c_str(), sym);
            return sym;
        }
    }

    LOG("[ElfLoader] UNRESOLVED import symbol: '%s' -> using dummy_stub\n", name.c_str());
    return (void*)&dummy_stub_function;
}

void* get_adi_symbol(ElfLoader* primary, ElfLoader* secondary, const char* obfuscated_key, const char* readable_fallback) {
    if (!primary) return nullptr;
    void* sym = primary->get_symbol(obfuscated_key);
    if (sym) {
        LOG("[AnisetteKit] Resolved symbol '%s' (key: %s) @ %p\n", readable_fallback ? readable_fallback : obfuscated_key, obfuscated_key, sym);
        return sym;
    }
    if (secondary) {
        sym = secondary->get_symbol(obfuscated_key);
        if (sym) {
            LOG("[AnisetteKit] Resolved symbol '%s' (key: %s) in secondary loader @ %p\n", readable_fallback ? readable_fallback : obfuscated_key, obfuscated_key, sym);
            return sym;
        }
    }
    if (readable_fallback) {
        sym = primary->get_symbol(readable_fallback);
        if (!sym && secondary) sym = secondary->get_symbol(readable_fallback);
        if (sym) {
            LOG("[AnisetteKit] Resolved symbol '%s' via readable name @ %p\n", readable_fallback, sym);
            return sym;
        }
    }
    LOG("[AnisetteKit] ERROR: Failed to resolve symbol (key: %s, fallback: %s)\n", obfuscated_key, readable_fallback ? readable_fallback : "none");
    return nullptr;
}

#endif
#endif
