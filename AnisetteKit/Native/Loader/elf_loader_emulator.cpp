//
//  elf_loader_emulator.cpp
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#include "elf_loader_emulator.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>

#if defined(_WIN32) || defined(_MSC_VER)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <io.h>
#include <direct.h>
#include <process.h>
#include <winsock2.h>
#include <windows.h>
#define close _close
#define read _read
#define write _write
#define open _open
#define fstat _fstat64
#define lstat _stat64
#define stat _stat64
#define ftruncate _chsize
#define mkdir(p, m) _mkdir(p)
#define rmdir _rmdir
typedef int mode_t;

static inline int gettimeofday(struct timeval *tv, void *tz) {
    (void)tz;
    if (tv) {
        FILETIME ft;
        GetSystemTimeAsFileTime(&ft);
        ULARGE_INTEGER uli;
        uli.LowPart = ft.dwLowDateTime;
        uli.HighPart = ft.dwHighDateTime;
        uint64_t unix_time_100ns = uli.QuadPart - 116444736000000000ULL;
        tv->tv_sec = (long)(unix_time_100ns / 10000000ULL);
        tv->tv_usec = (long)((unix_time_100ns % 10000000ULL) / 10);
    }
    return 0;
}

#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif
#ifndef O_SYNC
#define O_SYNC 0
#endif
#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif
#ifndef O_BINARY
#ifdef _O_BINARY
#define O_BINARY _O_BINARY
#else
#define O_BINARY 0
#endif
#endif

#else
#include <unistd.h>
#include <sys/time.h>
#ifndef O_BINARY
#define O_BINARY 0
#endif
#endif
#include <string>
#include <vector>
#include <unordered_map>
#include <sstream>
#include <random>

const AndroidSystemProperties kAndroidProperties;

static thread_local uint64_t g_last_pcs[16];
static thread_local size_t g_pc_idx = 0;

static void trace_pc_hook(uc_engine *uc, uint64_t address, uint32_t size, void *user_data) {
    (void)uc; (void)size; (void)user_data;
    g_last_pcs[g_pc_idx % 16] = address;
    g_pc_idx++;
}

static bool hook_mem_invalid(uc_engine *uc, uc_mem_type type,
                             uint64_t address, int size, int64_t value,
                             void *user_data) {
    (void)size;
    (void)value;
    (void)user_data;
    uint64_t page_addr = address & ~0xFFFFULL;

    if (type == UC_MEM_FETCH_UNMAPPED) {
        LOG_UC("[Emulator - UC] FETCH_UNMAPPED at 0x%llx - stopping VM\n", (unsigned long long)address);
        LOG_UC("[TRACE] Last PCs before stop:\n");
        for (int i = 15; i >= 0; i--) {
            size_t idx = (g_pc_idx + 16 - 1 - i) % 16;
            LOG_UC("  [-%d] PC=0x%llx\n", i, (unsigned long long)g_last_pcs[idx]);
        }
        fflush(stdout);
        uc_emu_stop(uc);
        return false;
    }

    if (page_addr == 0 && type == UC_MEM_WRITE_UNMAPPED) {
        LOG_UC("[Emulator - UC] Null pointer write to address 0x%llx - stopping VM safely\n",
               (unsigned long long)address);
        fflush(stdout);
        uc_emu_stop(uc);
        return false;
    }

    uint64_t crash_pc = 0;
    uc_reg_read(uc, UC_ARM64_REG_PC, &crash_pc);
    LOG_UC("[Emulator - UC] Dynamically mapping page at 0x%llx (type %d, target=0x%llx) PC=0x%llx\n",
           (unsigned long long)page_addr, (int)type, (unsigned long long)address, (unsigned long long)crash_pc);
    fflush(stdout);

    uc_err err = uc_mem_map(uc, page_addr, 0x10000, UC_PROT_ALL);
    if (err == UC_ERR_OK || err == UC_ERR_MAP) {
        return true;
    }

    uc_emu_stop(uc);
    return false;
}

uint64_t PageAllocator::alloc(uint64_t bytes) {
    uint64_t align_mask = alignment - 1;
    uint64_t aligned_size = (bytes + align_mask) & ~align_mask;
    if (aligned_size == 0) aligned_size = alignment;

    if (offset + aligned_size > size) {
        LOG_UC("[Emulator] Error: Out of virtual memory heap allocation range (needed %llu, offset %llu / %llu)!\n",
               (unsigned long long)aligned_size, (unsigned long long)offset, (unsigned long long)size);
        abort();
    }
    uint64_t addr = base + offset;
    offset += aligned_size;
    return addr;
}

static void import_callback_router(uc_engine *uc, uint64_t address, uint32_t size, void *user_data);
static void hook_intr(uc_engine *uc, uint32_t intno, void *user_data);

EmulatorVM::EmulatorVM()
    : uc(nullptr),
      heap(kHeapAddress, kHeapSize, 64),
      library_alloc(0x10000000, 0x30000000, 0x10000),
      next_import_address(kImportAddress),
      next_guest_fd(10)
{
    uc_err err = uc_open(UC_ARCH_ARM64, UC_MODE_ARM, &uc);
    if (err != UC_ERR_OK) {
        LOG_UC("[Emulator] Failed on uc_open() with error returned: %u (%s)\n", err, uc_strerror(err));
        abort();
    }

    uc_mem_map(uc, kHeapAddress, kHeapSize, UC_PROT_READ | UC_PROT_WRITE);

    uc_mem_map(uc, kStackAddress, kStackSize, UC_PROT_READ | UC_PROT_WRITE);

    uc_mem_map(uc, kImportAddress, kImportSize, UC_PROT_ALL);

    uc_mem_map(uc, 0x0, 0x10000, UC_PROT_NONE);

    errno_addr = 0x3FF00000;
    uc_mem_map(uc, errno_addr, 0x10000, UC_PROT_READ | UC_PROT_WRITE);
    uint32_t zero = 0;
    uc_mem_write(uc, errno_addr, &zero, sizeof(zero));

    uc_hook_add(uc, &invalid_hook, UC_HOOK_MEM_UNMAPPED, (void *)hook_mem_invalid, this, 1, 0);

    uc_hook intr_hook = 0;
    uc_hook_add(uc, &intr_hook, UC_HOOK_INTR, (void *)hook_intr, this, 1, 0);

    uc_hook_add(uc, &import_hook, UC_HOOK_CODE, (void *)import_callback_router, this,
                kImportAddress, kImportAddress + kImportSize - 1);

    uc_hook_add(uc, &pc_trace_hook, UC_HOOK_CODE, (void *)trace_pc_hook, this, 1, 0);
}

EmulatorVM::~EmulatorVM() {
    if (uc) {
        uc_close(uc);
        uc = nullptr;
    }
}

uint64_t EmulatorVM::register_import(const std::string &name) {
    auto it = imported_symbols.find(name);
    if (it != imported_symbols.end()) {
        return it->second;
    }

    uint64_t stub_addr = next_import_address;
    next_import_address += 8;

    uint32_t ret_insn = 0xD65F03C0;
    uc_mem_write(uc, stub_addr, &ret_insn, sizeof(ret_insn));

    imported_symbols[name] = stub_addr;
    import_stubs[stub_addr] = name;

    return stub_addr;
}

uint64_t EmulatorVM::write_bytes(const uint8_t *data, size_t len) {
    if (!data || len == 0) return 0;
    uint64_t addr = heap.alloc(len + 16);
    uc_mem_write(uc, addr, data, len);
    return addr;
}

uint64_t EmulatorVM::write_string(const char *str) {
    if (!str) return 0;
    size_t len = strlen(str) + 1;
    return write_bytes((const uint8_t *)str, len);
}

static EmulatorVM *g_active_vm = nullptr;

static void hook_intr(uc_engine *uc, uint32_t intno, void *user_data) {
    (void)user_data;
    uint64_t pc = 0;
    uc_reg_read(uc, UC_ARM64_REG_PC, &pc);
    LOG_UC("[Emulator] Interrupt %u at PC=0x%llx\n", intno, (unsigned long long)pc);
}

static void hook_malloc(EmulatorVM *vm) {
    uint64_t size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &size);
    uint64_t ptr = vm->heap.alloc(size + 16);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
}

static void hook_calloc(EmulatorVM *vm) {
    uint64_t num = 0, size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &num);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &size);
    uint64_t total = num * size;
    uint64_t ptr = vm->heap.alloc(total + 16);
    std::vector<uint8_t> zeros(total, 0);
    if (total > 0) {
        uc_mem_write(vm->uc, ptr, zeros.data(), total);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
}

static void hook_realloc(EmulatorVM *vm) {
    uint64_t ptr = 0, new_size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &new_size);
    uint64_t new_ptr = vm->heap.alloc(new_size + 16);
    if (ptr != 0 && new_size > 0) {
        std::vector<uint8_t> buf(new_size);
        uc_mem_read(vm->uc, ptr, buf.data(), new_size);
        uc_mem_write(vm->uc, new_ptr, buf.data(), new_size);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &new_ptr);
}

static void hook_free(EmulatorVM *vm) {
    uint64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_strlen(EmulatorVM *vm) {
    uint64_t str_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &str_ptr);
    if (!str_ptr) {
        uint64_t zero = 0;
        uc_reg_write(vm->uc, UC_ARM64_REG_X0, &zero);
        return;
    }
    uint64_t len = 0;
    char c = 0;
    while (true) {
        if (uc_mem_read(vm->uc, str_ptr + len, &c, 1) != UC_ERR_OK || c == '\0') break;
        len++;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &len);
}

static void hook_strcmp(EmulatorVM *vm) {
    uint64_t s1_ptr = 0, s2_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s1_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &s2_ptr);
    std::string s1, s2;
    char c = 0;
    if (s1_ptr) {
        while (uc_mem_read(vm->uc, s1_ptr++, &c, 1) == UC_ERR_OK && c != '\0') s1.push_back(c);
    }
    if (s2_ptr) {
        while (uc_mem_read(vm->uc, s2_ptr++, &c, 1) == UC_ERR_OK && c != '\0') s2.push_back(c);
    }
    int64_t cmp_res = (int64_t)s1.compare(s2);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &cmp_res);
}

static void hook_strncmp(EmulatorVM *vm) {
    uint64_t s1_ptr = 0, s2_ptr = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s1_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &s2_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    std::string s1, s2;
    char c = 0;
    if (s1_ptr) {
        for (uint64_t i = 0; i < n && uc_mem_read(vm->uc, s1_ptr + i, &c, 1) == UC_ERR_OK && c != '\0'; i++) s1.push_back(c);
    }
    if (s2_ptr) {
        for (uint64_t i = 0; i < n && uc_mem_read(vm->uc, s2_ptr + i, &c, 1) == UC_ERR_OK && c != '\0'; i++) s2.push_back(c);
    }
    int64_t cmp_res = (int64_t)s1.compare(s2);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &cmp_res);
}

static void hook_strcpy(EmulatorVM *vm) {
    uint64_t dst = 0, src = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &src);
    char c = 0;
    uint64_t offset = 0;
    if (src && dst) {
        do {
            if (uc_mem_read(vm->uc, src + offset, &c, 1) != UC_ERR_OK) break;
            uc_mem_write(vm->uc, dst + offset, &c, 1);
            offset++;
        } while (c != '\0');
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_strncpy(EmulatorVM *vm) {
    uint64_t dst = 0, src = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &src);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    char c = 0;
    bool null_reached = false;
    for (uint64_t i = 0; i < n; i++) {
        if (!null_reached) {
            if (uc_mem_read(vm->uc, src + i, &c, 1) == UC_ERR_OK) {
                if (c == '\0') null_reached = true;
            } else {
                null_reached = true;
                c = '\0';
            }
        } else {
            c = '\0';
        }
        uc_mem_write(vm->uc, dst + i, &c, 1);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_memcpy(EmulatorVM *vm) {
    uint64_t dst = 0, src = 0, size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &src);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &size);
    if (size > 0 && dst != 0 && src != 0) {
        std::vector<uint8_t> buf(size);
        uc_mem_read(vm->uc, src, buf.data(), size);
        uc_mem_write(vm->uc, dst, buf.data(), size);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_memset(EmulatorVM *vm) {
    uint64_t dst = 0, val = 0, size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &dst);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &val);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &size);
    if (size > 0 && dst != 0) {
        std::vector<uint8_t> buf(size, (uint8_t)val);
        uc_mem_write(vm->uc, dst, buf.data(), size);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &dst);
}

static void hook_memcmp(EmulatorVM *vm) {
    uint64_t s1 = 0, s2 = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s1);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &s2);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    int64_t res = 0;
    if (n > 0 && s1 && s2) {
        std::vector<uint8_t> b1(n), b2(n);
        uc_mem_read(vm->uc, s1, b1.data(), n);
        uc_mem_read(vm->uc, s2, b2.data(), n);
        res = memcmp(b1.data(), b2.data(), n);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_memchr(EmulatorVM *vm) {
    uint64_t s = 0, c = 0, n = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &s);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &c);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &n);
    uint64_t res = 0;
    uint8_t target = (uint8_t)c;
    for (uint64_t i = 0; i < n; i++) {
        uint8_t byte = 0;
        if (uc_mem_read(vm->uc, s + i, &byte, 1) != UC_ERR_OK) break;
        if (byte == target) {
            res = s + i;
            break;
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static int linux_to_darwin_open_flags(int linux_flags) {
    int darwin_flags = 0;
    int acc_mode = linux_flags & 3;
    if (acc_mode == 0) darwin_flags |= O_RDONLY;
    else if (acc_mode == 1) darwin_flags |= O_WRONLY;
    else if (acc_mode == 2) darwin_flags |= O_RDWR;

    if (linux_flags & 0x0040)  darwin_flags |= O_CREAT;
    if (linux_flags & 0x0080)  darwin_flags |= O_EXCL;
    if (linux_flags & 0x0100)  darwin_flags |= O_NOCTTY;
    if (linux_flags & 0x0200)  darwin_flags |= O_TRUNC;
    if (linux_flags & 0x0400)  darwin_flags |= O_APPEND;
    if (linux_flags & 0x0800)  darwin_flags |= O_NONBLOCK;
    if (linux_flags & 0x1000)  darwin_flags |= O_SYNC;
    if (linux_flags & 0x80000) darwin_flags |= O_CLOEXEC;

    return darwin_flags;
}

static void hook_open(EmulatorVM *vm) {
    uint64_t path_ptr = 0, flags = 0, mode = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &flags);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &mode);

    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }

    int host_flags = linux_to_darwin_open_flags((int)flags);
    int host_fd = open(path.c_str(), host_flags, (mode_t)mode);
    int64_t guest_fd = -1;
    if (host_fd >= 0) {
        guest_fd = vm->next_guest_fd++;
        vm->fd_map[guest_fd] = host_fd;
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    } else {
        uint32_t err = (uint32_t)errno;
        uc_mem_write(vm->uc, vm->errno_addr, &err, sizeof(err));
    }
    LOG_UC("[Hook] open('%s', linux=0x%x, mac=0x%x, mode=0%o) -> fd %lld (errno=%d)\n",
           path.c_str(), (int)flags, host_flags, (int)mode, (long long)guest_fd, errno);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &guest_fd);
}

static void hook_close(EmulatorVM *vm) {
    uint64_t guest_fd = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    int64_t res = 0;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        close(it->second);
        vm->fd_map.erase(it);
    } else {
        res = -1;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_read(EmulatorVM *vm) {
    uint64_t guest_fd = 0, buf_ptr = 0, count = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &buf_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &count);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        std::vector<uint8_t> tmp(count);
        ssize_t bytes_read = read(it->second, tmp.data(), count);
        if (bytes_read > 0) {
            uc_mem_write(vm->uc, buf_ptr, tmp.data(), bytes_read);
        }
        res = (int64_t)bytes_read;
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_write(EmulatorVM *vm) {
    uint64_t guest_fd = 0, buf_ptr = 0, count = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &buf_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &count);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        std::vector<uint8_t> tmp(count);
        uc_mem_read(vm->uc, buf_ptr, tmp.data(), count);
        res = (int64_t)write(it->second, tmp.data(), count);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_ftruncate(EmulatorVM *vm) {
    uint64_t guest_fd = 0, length = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &length);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end()) {
        res = (int64_t)ftruncate(it->second, (off_t)length);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_mkdir(EmulatorVM *vm) {
    uint64_t path_ptr = 0, mode = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &mode);
    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }
    int res = mkdir(path.c_str(), (mode_t)mode);
    if (res != 0 && errno == EEXIST) {
        res = 0;
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    } else if (res != 0) {
        uint32_t err = (uint32_t)errno;
        uc_mem_write(vm->uc, vm->errno_addr, &err, sizeof(err));
    } else {
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    }
    int64_t ret = res;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_umask(EmulatorVM *vm) {
    uint64_t mask = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &mask);
    int64_t old_mask = (int64_t)umask((mode_t)mask);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &old_mask);
}

static void hook_chmod(EmulatorVM *vm) {
    uint64_t path_ptr = 0, mode = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &mode);
    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }
    int64_t res = (int64_t)chmod(path.c_str(), (mode_t)mode);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_lstat(EmulatorVM *vm) {
    uint64_t path_ptr = 0, stat_buf_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &path_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &stat_buf_ptr);
    std::string path;
    char c = 0;
    if (path_ptr) {
        while (uc_mem_read(vm->uc, path_ptr++, &c, 1) == UC_ERR_OK && c != '\0') path.push_back(c);
    }
    struct stat host_st;
    int res = lstat(path.c_str(), &host_st);
    if (res == 0 && stat_buf_ptr != 0) {
        StatLinux linux_st = {0};
        linux_st.st_dev = (uint64_t)host_st.st_dev;
        linux_st.st_ino = (uint64_t)host_st.st_ino;
        linux_st.st_mode = (uint32_t)host_st.st_mode;
        linux_st.st_nlink = (uint32_t)host_st.st_nlink;
        linux_st.st_uid = (uint32_t)host_st.st_uid;
        linux_st.st_gid = (uint32_t)host_st.st_gid;
        linux_st.st_rdev = (uint64_t)host_st.st_rdev;
        linux_st.st_size = (int64_t)host_st.st_size;
#if defined(_WIN32)
        linux_st.st_blksize = 4096;
        linux_st.st_blocks = (linux_st.st_size + 511) / 512;
#else
        linux_st.st_blksize = (int32_t)host_st.st_blksize;
        linux_st.st_blocks = (int64_t)host_st.st_blocks;
#endif
#if defined(__APPLE__) || defined(__MACH__)
        linux_st.st_atime = (int64_t)host_st.st_atimespec.tv_sec;
        linux_st.st_atime_nsec = (uint64_t)host_st.st_atimespec.tv_nsec;
        linux_st.st_mtime = (int64_t)host_st.st_mtimespec.tv_sec;
        linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtimespec.tv_nsec;
        linux_st.st_ctime = (int64_t)host_st.st_ctimespec.tv_sec;
        linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctimespec.tv_nsec;
#elif defined(_WIN32)
        linux_st.st_atime = (int64_t)host_st.st_atime;
        linux_st.st_atime_nsec = 0;
        linux_st.st_mtime = (int64_t)host_st.st_mtime;
        linux_st.st_mtime_nsec = 0;
        linux_st.st_ctime = (int64_t)host_st.st_ctime;
        linux_st.st_ctime_nsec = 0;
#else
        linux_st.st_atime = (int64_t)host_st.st_atim.tv_sec;
        linux_st.st_atime_nsec = (uint64_t)host_st.st_atim.tv_nsec;
        linux_st.st_mtime = (int64_t)host_st.st_mtim.tv_sec;
        linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtim.tv_nsec;
        linux_st.st_ctime = (int64_t)host_st.st_ctim.tv_sec;
        linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctim.tv_nsec;
#endif
        uc_mem_write(vm->uc, stat_buf_ptr, &linux_st, sizeof(linux_st));
        uint32_t zero_err = 0;
        uc_mem_write(vm->uc, vm->errno_addr, &zero_err, sizeof(zero_err));
    } else {
        uint32_t err = (uint32_t)errno;
        uc_mem_write(vm->uc, vm->errno_addr, &err, sizeof(err));
    }
    LOG_UC("[Hook] lstat('%s') -> res %d (errno=%d)\n", path.c_str(), res, errno);
    int64_t ret = res;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_fstat(EmulatorVM *vm) {
    uint64_t guest_fd = 0, stat_buf_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guest_fd);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &stat_buf_ptr);
    int64_t res = -1;
    auto it = vm->fd_map.find((int)guest_fd);
    if (it != vm->fd_map.end() && stat_buf_ptr != 0) {
        struct stat host_st;
        if (fstat(it->second, &host_st) == 0) {
            StatLinux linux_st = {0};
            linux_st.st_dev = (uint64_t)host_st.st_dev;
            linux_st.st_ino = (uint64_t)host_st.st_ino;
            linux_st.st_mode = (uint32_t)host_st.st_mode;
            linux_st.st_nlink = (uint32_t)host_st.st_nlink;
            linux_st.st_uid = (uint32_t)host_st.st_uid;
            linux_st.st_gid = (uint32_t)host_st.st_gid;
            linux_st.st_rdev = (uint64_t)host_st.st_rdev;
            linux_st.st_size = (int64_t)host_st.st_size;
#if defined(_WIN32) || defined(_MSC_VER)
            linux_st.st_blksize = 4096;
            linux_st.st_blocks = (linux_st.st_size + 511) / 512;
#else
            linux_st.st_blksize = (int32_t)host_st.st_blksize;
            linux_st.st_blocks = (int64_t)host_st.st_blocks;
#endif
#if defined(__APPLE__) || defined(__MACH__)
            linux_st.st_atime = (int64_t)host_st.st_atimespec.tv_sec;
            linux_st.st_atime_nsec = (uint64_t)host_st.st_atimespec.tv_nsec;
            linux_st.st_mtime = (int64_t)host_st.st_mtimespec.tv_sec;
            linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtimespec.tv_nsec;
            linux_st.st_ctime = (int64_t)host_st.st_ctimespec.tv_sec;
            linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctimespec.tv_nsec;
#elif defined(_WIN32)
            linux_st.st_atime = (int64_t)host_st.st_atime;
            linux_st.st_atime_nsec = 0;
            linux_st.st_mtime = (int64_t)host_st.st_mtime;
            linux_st.st_mtime_nsec = 0;
            linux_st.st_ctime = (int64_t)host_st.st_ctime;
            linux_st.st_ctime_nsec = 0;
#else
            linux_st.st_atime = (int64_t)host_st.st_atim.tv_sec;
            linux_st.st_atime_nsec = (uint64_t)host_st.st_atim.tv_nsec;
            linux_st.st_mtime = (int64_t)host_st.st_mtim.tv_sec;
            linux_st.st_mtime_nsec = (uint64_t)host_st.st_mtim.tv_nsec;
            linux_st.st_ctime = (int64_t)host_st.st_ctim.tv_sec;
            linux_st.st_ctime_nsec = (uint64_t)host_st.st_ctim.tv_nsec;
#endif
            uc_mem_write(vm->uc, stat_buf_ptr, &linux_st, sizeof(linux_st));
            res = 0;
        }
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &res);
}

static void hook_errno_location(EmulatorVM *vm) {
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &vm->errno_addr);
}

static void hook_system_property_get(EmulatorVM *vm) {
    uint64_t name_ptr = 0, val_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &name_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &val_ptr);
    std::string name;
    char c = 0;
    if (name_ptr) {
        while (uc_mem_read(vm->uc, name_ptr++, &c, 1) == UC_ERR_OK && c != '\0') name.push_back(c);
    }
    std::string prop_val = "";
    if (name == "ro.build.version.sdk") prop_val = kAndroidProperties.sdk_version;
    else if (name == "ro.build.version.release") prop_val = kAndroidProperties.release;
    else if (name == "ro.product.model") prop_val = kAndroidProperties.model;
    else if (name == "ro.product.brand") prop_val = kAndroidProperties.brand;
    else if (name == "ro.product.name") prop_val = kAndroidProperties.name;
    else if (name == "ro.product.device") prop_val = kAndroidProperties.device;
    else if (name == "ro.product.manufacturer") prop_val = kAndroidProperties.manufacturer;
    else if (name == "ro.build.fingerprint") prop_val = kAndroidProperties.fingerprint;

    if (val_ptr != 0) {
        std::vector<uint8_t> buf(92, 0);
        memcpy(buf.data(), prop_val.c_str(), (std::min)((size_t)91, prop_val.length()));
        uc_mem_write(vm->uc, val_ptr, buf.data(), 92);
    }
    int64_t ret = (int64_t)prop_val.length();
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_arc4random(EmulatorVM *vm) {
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    uint64_t rnd = (uint64_t)arc4random();
#else
    static thread_local std::random_device rd;
    static thread_local std::mt19937 gen(rd());
    uint64_t rnd = (uint64_t)gen();
#endif
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &rnd);
}

static void hook_gettimeofday(EmulatorVM *vm) {
    uint64_t tv_ptr = 0, tz_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &tv_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &tz_ptr);
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (tv_ptr) {
        uint64_t tv_sec = (uint64_t)tv.tv_sec;
        uint64_t tv_usec = (uint64_t)tv.tv_usec;
        uc_mem_write(vm->uc, tv_ptr, &tv_sec, 8);
        uc_mem_write(vm->uc, tv_ptr + 8, &tv_usec, 8);
    }
    int64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_getauxval(EmulatorVM *vm) {
    uint64_t type = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &type);
    uint64_t val = 0;
    if (type == 6  ) val = 4096;
    else if (type == 16  ) val = 0xff;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &val);
}

static void hook_dlopen(EmulatorVM *vm) {
    uint64_t handle = 0x50000000;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &handle);
}

static void hook_dlsym(EmulatorVM *vm) {
    uint64_t handle = 0, sym_name_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &handle);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &sym_name_ptr);
    std::string sym_name;
    char c = 0;
    if (sym_name_ptr) {
        while (uc_mem_read(vm->uc, sym_name_ptr++, &c, 1) == UC_ERR_OK && c != '\0') sym_name.push_back(c);
    }
    uint64_t addr = get_vm_symbol_address(vm, sym_name);
    if (!addr) {
        addr = vm->register_import(sym_name);
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &addr);
}

static void hook_cxa_guard_acquire(EmulatorVM *vm) {
    uint64_t guard_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guard_ptr);
    uint8_t first_byte = 0;
    if (guard_ptr) {
        uc_mem_read(vm->uc, guard_ptr, &first_byte, 1);
    }
    int64_t ret = (first_byte == 0) ? 1 : 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_cxa_guard_release(EmulatorVM *vm) {
    uint64_t guard_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &guard_ptr);
    uint8_t one = 1;
    if (guard_ptr) {
        uc_mem_write(vm->uc, guard_ptr, &one, 1);
    }
    int64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void hook_cxa_allocate_exception(EmulatorVM *vm) {
    uint64_t size = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &size);
    uint64_t ptr = vm->heap.alloc(size + 128);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ptr);
}

static void hook_dynamic_cast(EmulatorVM *vm) {
    uint64_t sub = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &sub);
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &sub);
}

static void hook_strtoll(EmulatorVM *vm) {
    uint64_t nptr = 0, endptr = 0, base = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &nptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &endptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &base);

    std::string str;
    char c = 0;
    if (nptr) {
        while (uc_mem_read(vm->uc, nptr++, &c, 1) == UC_ERR_OK && c != '\0') str.push_back(c);
    }

    char *host_end = nullptr;
    int64_t val = strtoll(str.c_str(), &host_end, (int)base);
    if (endptr != 0 && host_end != nullptr) {
        size_t consumed = host_end - str.c_str();
        uint64_t final_end_addr = (nptr - str.length() - 1) + consumed;
        uc_mem_write(vm->uc, endptr, &final_end_addr, sizeof(final_end_addr));
    }
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &val);
}

static void hook_strtod(EmulatorVM *vm) {
    uint64_t nptr = 0, endptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &nptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &endptr);

    std::string str;
    char c = 0;
    if (nptr) {
        while (uc_mem_read(vm->uc, nptr++, &c, 1) == UC_ERR_OK && c != '\0') str.push_back(c);
    }

    char *host_end = nullptr;
    double val = strtod(str.c_str(), &host_end);
    if (endptr != 0 && host_end != nullptr) {
        size_t consumed = host_end - str.c_str();
        uint64_t final_end_addr = (nptr - str.length() - 1) + consumed;
        uc_mem_write(vm->uc, endptr, &final_end_addr, sizeof(final_end_addr));
    }
    uint8_t d0_val[16] = {0};
    memcpy(d0_val, &val, sizeof(double));
    uc_reg_write(vm->uc, UC_ARM64_REG_Q0, d0_val);
}

static void hook_android_log_print(EmulatorVM *vm) {
    uint64_t prio = 0, tag_ptr = 0, fmt_ptr = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_X0, &prio);
    uc_reg_read(vm->uc, UC_ARM64_REG_X1, &tag_ptr);
    uc_reg_read(vm->uc, UC_ARM64_REG_X2, &fmt_ptr);
    std::string tag, fmt;
    char c = 0;
    if (tag_ptr) {
        while (uc_mem_read(vm->uc, tag_ptr++, &c, 1) == UC_ERR_OK && c != '\0') tag.push_back(c);
    }
    if (fmt_ptr) {
        while (uc_mem_read(vm->uc, fmt_ptr++, &c, 1) == UC_ERR_OK && c != '\0') fmt.push_back(c);
    }
    LOG_UC("[Android Log %lld][%s] %s\n", (long long)prio, tag.c_str(), fmt.c_str());
    int64_t ret = 0;
    uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
}

static void import_callback_router(uc_engine *uc, uint64_t address, uint32_t size, void *user_data) {
    (void)size;
    EmulatorVM *vm = (EmulatorVM *)user_data;
    if (!vm) vm = g_active_vm;
    if (!vm) return;

    auto it = vm->import_stubs.find(address);
    if (it == vm->import_stubs.end()) {
        return;
    }

    const std::string &name = it->second;

    if (name == "malloc") hook_malloc(vm);
    else if (name == "calloc") hook_calloc(vm);
    else if (name == "realloc") hook_realloc(vm);
    else if (name == "free") hook_free(vm);
    else if (name == "strlen") hook_strlen(vm);
    else if (name == "strcmp") hook_strcmp(vm);
    else if (name == "strncmp") hook_strncmp(vm);
    else if (name == "strcpy") hook_strcpy(vm);
    else if (name == "strncpy") hook_strncpy(vm);
    else if (name == "memcpy") hook_memcpy(vm);
    else if (name == "memset") hook_memset(vm);
    else if (name == "memcmp") hook_memcmp(vm);
    else if (name == "memchr") hook_memchr(vm);
    else if (name == "open") hook_open(vm);
    else if (name == "close") hook_close(vm);
    else if (name == "read") hook_read(vm);
    else if (name == "write") hook_write(vm);
    else if (name == "ftruncate") hook_ftruncate(vm);
    else if (name == "mkdir") hook_mkdir(vm);
    else if (name == "umask") hook_umask(vm);
    else if (name == "chmod") hook_chmod(vm);
    else if (name == "lstat") hook_lstat(vm);
    else if (name == "fstat") hook_fstat(vm);
    else if (name == "__errno" || name == "__errno_location") hook_errno_location(vm);
    else if (name == "__system_property_get") hook_system_property_get(vm);
    else if (name == "arc4random") hook_arc4random(vm);
    else if (name == "gettimeofday") hook_gettimeofday(vm);
    else if (name == "getauxval") hook_getauxval(vm);
    else if (name == "dlopen") hook_dlopen(vm);
    else if (name == "dlsym") hook_dlsym(vm);
    else if (name == "__cxa_guard_acquire") hook_cxa_guard_acquire(vm);
    else if (name == "__cxa_guard_release") hook_cxa_guard_release(vm);
    else if (name == "__cxa_allocate_exception") hook_cxa_allocate_exception(vm);
    else if (name == "__cxa_begin_catch" || name == "__dynamic_cast") hook_dynamic_cast(vm);
    else if (name == "strtoll" || name == "strtol" || name == "strtoull") hook_strtoll(vm);
    else if (name == "strtod" || name == "atof") hook_strtod(vm);
    else if (name == "pthread_rwlock_init" || name == "pthread_mutex_init") {
        uint64_t lock_ptr = 0;
        uc_reg_read(vm->uc, UC_ARM64_REG_X0, &lock_ptr);
        if (lock_ptr) {
            std::vector<uint8_t> dummy_lock(64, 0);
            uc_mem_write(vm->uc, lock_ptr, dummy_lock.data(), 64);
        }
        uint64_t ret = 0;
        uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
    }
    else if (name == "__android_log_print") hook_android_log_print(vm);
    else {

        uint64_t ret = 0;
        uc_reg_write(vm->uc, UC_ARM64_REG_X0, &ret);
    }
}

static uint64_t vm_resolve_symbol(EmulatorVM *vm, const EmulatorVM::LibraryInfo &current_lib, uint32_t sym_idx) {
    if (!current_lib.symtab || !current_lib.strtab) return 0;
    Elf64_Sym sym;
    if (uc_mem_read(vm->uc, current_lib.symtab + sym_idx * sizeof(Elf64_Sym), &sym, sizeof(sym)) != UC_ERR_OK) {
        return 0;
    }

    std::string sym_name;
    if (sym.st_name < current_lib.strsz) {
        std::vector<char> name_buf(256, 0);
        uc_mem_read(vm->uc, current_lib.strtab + sym.st_name, name_buf.data(), 255);
        sym_name = name_buf.data();
    }

    if (sym_name.empty()) {
        if (sym.st_value != 0) return current_lib.base_address + (sym.st_value - current_lib.min_vaddr);
        return current_lib.base_address;
    }

    if (sym.st_value != 0 && sym.st_shndx != 0) {
        return current_lib.base_address + (sym.st_value - current_lib.min_vaddr);
    }

    auto self_it = current_lib.symbols.find(sym_name);
    if (self_it != current_lib.symbols.end()) return self_it->second;

    for (const auto &lib : vm->loaded_libraries) {
        auto it = lib.symbols.find(sym_name);
        if (it != lib.symbols.end()) return it->second;
    }

    std::string converted = sym_name;
    size_t pos = converted.find("6__ndk1");
    if (pos != std::string::npos) {
        converted.replace(pos, 7, "3__1");
    } else {
        pos = converted.find("__ndk1");
        if (pos != std::string::npos) {
            converted.replace(pos, 6, "__1");
        }
    }
    if (converted != sym_name) {
        for (const auto &lib : vm->loaded_libraries) {
            auto it = lib.symbols.find(converted);
            if (it != lib.symbols.end()) return it->second;
        }
    }

    uint8_t sym_type = sym.st_info & 0xf;
    bool is_data = (sym_type == 1  ) ||
                   sym_name.rfind("_ZTV", 0) == 0 ||
                   sym_name.rfind("_ZTI", 0) == 0 ||
                   sym_name.rfind("_ZTS", 0) == 0 ||
                   sym_name.rfind("kCF", 0) == 0 ||
                   sym_name.rfind("kAudio", 0) == 0 ||
                   sym_name.rfind("OBJC_", 0) == 0 ||
                   sym_name == "__CFConstantStringClassReference" ||
                   sym_name == "__sF" ||
                   sym_name == "environ" ||
                   sym_name == "__stack_chk_guard" ||
                   sym_name == "__ctype_";

    if (is_data) {
        auto it = vm->imported_symbols.find(sym_name);
        if (it != vm->imported_symbols.end()) return it->second;
        uint64_t dummy = vm->heap.alloc(256);
        std::vector<uint8_t> zeros(256, 0);
        uc_mem_write(vm->uc, dummy, zeros.data(), 256);
        vm->imported_symbols[sym_name] = dummy;
        return dummy;
    }

    return vm->register_import(sym_name);
}

static void apply_vm_relocations(EmulatorVM *vm, EmulatorVM::LibraryInfo &lib) {
    auto apply_table = [&](uint64_t rela_ptr, size_t sz, const char *label) {
        if (!rela_ptr || !sz) return;
        size_t count = sz / sizeof(Elf64_Rela);
        size_t applied = 0;
        Elf64_Rela r;
        for (size_t offset = 0; offset < sz; offset += sizeof(r)) {
            if (uc_mem_read(vm->uc, rela_ptr + offset, &r, sizeof(r)) != UC_ERR_OK) break;

            uint32_t type = (uint32_t)ELF64_R_TYPE(r.r_info);
            uint32_t sym_idx = (uint32_t)ELF64_R_SYM(r.r_info);
            uint64_t target_addr = lib.base_address + (r.r_offset - lib.min_vaddr);

            if (type == R_AARCH64_RELATIVE) {
                uint64_t final_val = lib.base_address + (r.r_addend - lib.min_vaddr);
                uc_mem_write(vm->uc, target_addr, &final_val, sizeof(final_val));
                applied++;
            } else if (type == R_AARCH64_JUMP_SLOT || type == R_AARCH64_GLOB_DAT || type == R_AARCH64_ABS64) {
                uint64_t sym_addr = vm_resolve_symbol(vm, lib, sym_idx);
                if (sym_addr != 0) {
                    uint64_t final_val = sym_addr + r.r_addend;
                    uc_mem_write(vm->uc, target_addr, &final_val, sizeof(final_val));
                    applied++;
                }
            }
        }
        LOG_UC("[Emulator] Applied %zu / %zu relocations for %s in '%s'\n",
               applied, count, label, lib.name.c_str());
    };

    apply_table(lib.rela, lib.relasz, "RELA");
    apply_table(lib.jmprel, lib.pltrelsz, "PLT/JMPREL");
}

bool load_library_to_vm(EmulatorVM *vm, const std::string &file_path, const std::string &so_name) {
    LOG_UC("[Emulator] Loading ELF library '%s' from '%s'...\n", so_name.c_str(), file_path.c_str());
    FILE *f = fopen(file_path.c_str(), "rb");
    if (!f) {
        LOG_UC("[Emulator] Failed to open ELF file: %s\n", file_path.c_str());
        return false;
    }

    fseek(f, 0, SEEK_END);
    size_t file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    std::vector<uint8_t> buffer(file_size);
    if (fread(buffer.data(), 1, file_size, f) != file_size) {
        fclose(f);
        return false;
    }
    fclose(f);

    if (file_size < sizeof(Elf64_Ehdr)) return false;
    const Elf64_Ehdr *ehdr = (const Elf64_Ehdr *)buffer.data();

    if (memcmp(ehdr->e_ident, "\x7f\x45\x4c\x46\x02\x01\x01", 7) != 0) {
        LOG_UC("[Emulator] Invalid ELF magic or not 64-bit ELF: %s\n", so_name.c_str());
        return false;
    }

    uint64_t min_vaddr = UINT64_MAX;
    uint64_t max_vaddr = 0;
    const Elf64_Phdr *phdrs = (const Elf64_Phdr *)(buffer.data() + ehdr->e_phoff);

    for (int i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            uint64_t seg_start = phdrs[i].p_vaddr & ~0xFFFFULL;
            uint64_t seg_end   = (phdrs[i].p_vaddr + phdrs[i].p_memsz + 0xFFFFULL) & ~0xFFFFULL;
            if (seg_start < min_vaddr) min_vaddr = seg_start;
            if (seg_end > max_vaddr) max_vaddr = seg_end;
        }
    }

    if (min_vaddr >= max_vaddr) return false;
    uint64_t total_span = max_vaddr - min_vaddr;

    uint64_t base_address = vm->library_alloc.alloc(total_span);
    LOG_UC("[Emulator] Mapped library '%s' span 0x%llx at base address: 0x%llx\n",
           so_name.c_str(), (unsigned long long)total_span, (unsigned long long)base_address);

    uc_err err = uc_mem_map(vm->uc, base_address, total_span, UC_PROT_ALL);
    if (err != UC_ERR_OK && err != UC_ERR_MAP) {
        LOG_UC("[Emulator] uc_mem_map failed for library span: %u (%s)\n", err, uc_strerror(err));
        return false;
    }

    EmulatorVM::LibraryInfo lib;
    lib.name = so_name;
    lib.base_address = base_address;
    lib.min_vaddr = min_vaddr;
    lib.max_vaddr = max_vaddr;
    lib.dynamic_address = 0;
    lib.symtab = 0;
    lib.strtab = 0;
    lib.strsz = 0;
    lib.rel = 0;
    lib.relsz = 0;
    lib.rela = 0;
    lib.relasz = 0;
    lib.jmprel = 0;
    lib.pltrelsz = 0;
    lib.init_func = 0;
    lib.init_array = 0;
    lib.init_arraysz = 0;

    for (int i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            uint64_t dest = base_address + (phdrs[i].p_vaddr - min_vaddr);
            if (phdrs[i].p_filesz > 0) {
                uc_mem_write(vm->uc, dest, buffer.data() + phdrs[i].p_offset, phdrs[i].p_filesz);
            }
            if (phdrs[i].p_memsz > phdrs[i].p_filesz) {
                uint64_t bss_size = phdrs[i].p_memsz - phdrs[i].p_filesz;
                std::vector<uint8_t> bss_zeros(bss_size, 0);
                uc_mem_write(vm->uc, dest + phdrs[i].p_filesz, bss_zeros.data(), bss_size);
            }
        } else if (phdrs[i].p_type == PT_DYNAMIC) {
            lib.dynamic_address = base_address + (phdrs[i].p_vaddr - min_vaddr);
        }
    }

    if (lib.dynamic_address) {
        size_t dyn_offset = 0;
        while (true) {
            Elf64_Dyn dyn;
            if (uc_mem_read(vm->uc, lib.dynamic_address + dyn_offset, &dyn, sizeof(dyn)) != UC_ERR_OK) break;
            dyn_offset += sizeof(dyn);
            if (dyn.d_tag == DT_NULL) break;

            uint64_t val = (uint64_t)dyn.d_un.d_val;
            uint64_t ptr = (val >= min_vaddr) ? (base_address + (val - min_vaddr)) : (base_address + val);

            switch (dyn.d_tag) {
                case DT_SYMTAB: lib.symtab = ptr; break;
                case DT_STRTAB: lib.strtab = ptr; break;
                case DT_STRSZ:  lib.strsz = (size_t)val; break;
                case DT_REL:    lib.rel = ptr; break;
                case DT_RELSZ:  lib.relsz = (size_t)val; break;
                case DT_RELA:   lib.rela = ptr; break;
                case DT_RELASZ: lib.relasz = (size_t)val; break;
                case DT_JMPREL: lib.jmprel = ptr; break;
                case DT_PLTRELSZ: lib.pltrelsz = (size_t)val; break;
                case DT_INIT:   lib.init_func = ptr; break;
                case DT_INIT_ARRAY: lib.init_array = ptr; break;
                case DT_INIT_ARRAYSZ: lib.init_arraysz = (size_t)val; break;
                default: break;
            }
        }
    }

    if (lib.symtab && lib.strtab && lib.strsz) {
        size_t sym_offset = 0;
        while (true) {
            Elf64_Sym sym;
            if (uc_mem_read(vm->uc, lib.symtab + sym_offset, &sym, sizeof(sym)) != UC_ERR_OK) break;
            sym_offset += sizeof(sym);
            if (sym.st_name >= lib.strsz) continue;

            std::vector<char> name_buf(256, 0);
            uc_mem_read(vm->uc, lib.strtab + sym.st_name, name_buf.data(), 255);
            std::string sym_name = name_buf.data();
            if (sym_name.empty()) {
                if (sym_offset > sizeof(sym) * 4 && sym.st_value == 0) break;
                continue;
            }

            if (sym.st_value != 0) {
                uint64_t sym_addr = base_address + (sym.st_value - min_vaddr);
                lib.symbols[sym_name] = sym_addr;
            }
        }
    }

    vm->loaded_libraries.push_back(lib);
    return true;
}

void relocate_all_vm_libraries(EmulatorVM *vm) {
    LOG_UC("[Emulator] Relocating all %zu loaded libraries...\n", vm->loaded_libraries.size());
    for (auto &lib : vm->loaded_libraries) {
        apply_vm_relocations(vm, lib);
    }
}

void run_library_constructors(EmulatorVM *vm) {
    for (const auto &lib : vm->loaded_libraries) {
        if (lib.init_func) {
            LOG_UC("[Emulator] Calling DT_INIT at 0x%llx for '%s'...\n",
                   (unsigned long long)lib.init_func, lib.name.c_str());
            run_vm_procedure(vm, lib.init_func, {});
        }
        if (lib.init_array && lib.init_arraysz) {
            size_t count = lib.init_arraysz / 8;
            for (size_t i = 0; i < count; i++) {
                uint64_t ctor_ptr = 0;
                if (uc_mem_read(vm->uc, lib.init_array + i * 8, &ctor_ptr, 8) == UC_ERR_OK && ctor_ptr != 0) {
                    LOG_UC("[Emulator] Calling DT_INIT_ARRAY[%zu] at 0x%llx for '%s'...\n",
                           i, (unsigned long long)ctor_ptr, lib.name.c_str());
                    run_vm_procedure(vm, ctor_ptr, {});
                }
            }
        }
    }
}

uint64_t get_vm_symbol_address(EmulatorVM *vm, const std::string &name) {
    for (const auto &lib : vm->loaded_libraries) {
        auto it = lib.symbols.find(name);
        if (it != lib.symbols.end()) return it->second;
    }
    return 0;
}

int32_t run_vm_procedure(EmulatorVM *vm, uint64_t proc_addr, const std::vector<uint64_t> &args, uint64_t timeout_us, size_t max_count) {
    if (!proc_addr) return -1;
    g_active_vm = vm;

    if (timeout_us == 0) timeout_us = 0;
    if (max_count == 0) max_count = 0;

    static const int arm64_arg_regs[8] = {
        UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3,
        UC_ARM64_REG_X4, UC_ARM64_REG_X5, UC_ARM64_REG_X6, UC_ARM64_REG_X7
    };
    for (int i = 0; i < 8; i++) {
        uint64_t zero = 0;
        uc_reg_write(vm->uc, arm64_arg_regs[i], &zero);
    }
    static const int arm64_vregs[32] = {
        UC_ARM64_REG_V0,  UC_ARM64_REG_V1,  UC_ARM64_REG_V2,  UC_ARM64_REG_V3,
        UC_ARM64_REG_V4,  UC_ARM64_REG_V5,  UC_ARM64_REG_V6,  UC_ARM64_REG_V7,
        UC_ARM64_REG_V8,  UC_ARM64_REG_V9,  UC_ARM64_REG_V10, UC_ARM64_REG_V11,
        UC_ARM64_REG_V12, UC_ARM64_REG_V13, UC_ARM64_REG_V14, UC_ARM64_REG_V15,
        UC_ARM64_REG_V16, UC_ARM64_REG_V17, UC_ARM64_REG_V18, UC_ARM64_REG_V19,
        UC_ARM64_REG_V20, UC_ARM64_REG_V21, UC_ARM64_REG_V22, UC_ARM64_REG_V23,
        UC_ARM64_REG_V24, UC_ARM64_REG_V25, UC_ARM64_REG_V26, UC_ARM64_REG_V27,
        UC_ARM64_REG_V28, UC_ARM64_REG_V29, UC_ARM64_REG_V30, UC_ARM64_REG_V31
    };
    uint8_t zero16[16] = {0};
    for (int i = 0; i < 32; i++) {
        uc_reg_write(vm->uc, arm64_vregs[i], zero16);
    }

    for (size_t i = 0; i < args.size() && i < 8; i++) {
        uc_reg_write(vm->uc, arm64_arg_regs[i], &args[i]);
    }

    uint64_t stack_top = kStackAddress + kStackSize - 16;
    uc_reg_write(vm->uc, UC_ARM64_REG_SP, &stack_top);
    uc_reg_write(vm->uc, UC_ARM64_REG_LR, &kReturnAddress);
    uc_reg_write(vm->uc, UC_ARM64_REG_PC, &proc_addr);

    uint32_t first_insn = 0;
    uc_mem_read(vm->uc, proc_addr, &first_insn, 4);
    LOG_UC("[Emulator] Starting emu at 0x%llx (insn=0x%08x), SP=0x%llx, LR=0x%llx...\n",
           (unsigned long long)proc_addr, first_insn, (unsigned long long)stack_top, (unsigned long long)kReturnAddress);

    uc_err err = uc_emu_start(vm->uc, proc_addr, kReturnAddress, timeout_us, max_count);

    uint64_t pc = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_PC, &pc);
    if (err != UC_ERR_OK || pc != kReturnAddress) {
        LOG_UC("[Emulator] Execution stopped with status %d: %s at PC=0x%llx (expected 0x%llx)\n",
               (int)err, uc_strerror(err), (unsigned long long)pc, (unsigned long long)kReturnAddress);
        return -1000 - (int32_t)err;
    }

    uint32_t w0_val = 0;
    uc_reg_read(vm->uc, UC_ARM64_REG_W0, &w0_val);
    int32_t ret_val = (int32_t)w0_val;
    LOG_UC("[Emulator] run_vm_procedure exit: proc=0x%llx PC=0x%llx W0=%d err=%d\n",
           (unsigned long long)proc_addr, (unsigned long long)pc, ret_val, (int)err);
    return ret_val;
}
