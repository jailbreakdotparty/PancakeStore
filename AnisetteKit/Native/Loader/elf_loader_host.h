//
//  elf_loader_host.h
//  AnisetteKit
//
//  Created by Magesh K on 17/08/26.
//  Copyright © 2026 Magesh K. All rights reserved.
//

#ifndef ELF_LOADER_HOST_H
#define ELF_LOADER_HOST_H

#include <stdint.h>
#include <stddef.h>
#include <string>
#include <vector>
#include <map>
#include "anisette_base.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_OSX

#include <stdio.h>

#define LOG(...) anisetteCoreLog(__VA_ARGS__)

class ElfLoader {
public:
    void* base_addr;
    void* data_addr;
    size_t total_size;
    size_t code_size;
    size_t data_size;
    std::map<std::string, void*> exports;
    std::vector<ElfLoader*> siblings;

    const void* rela_ptr;
    size_t rela_sz;
    const void* rel_ptr;
    size_t rel_sz;
    const void* jmprel_ptr;
    size_t pltrel_sz;
    uint64_t pltrel_kind;
    Elf64_Sym* sym_tab;
    const char* str_tab;
    size_t sym_cnt;

    struct SegmentInfo {
        uintptr_t vaddr;
        size_t memsz;
        uint32_t flags;
    };
    std::vector<SegmentInfo> segments;

    ElfLoader();
    ~ElfLoader();

    void add_sibling(ElfLoader* sib);
    void relocate();
    bool load(const std::string& path);
    void* get_symbol(const char* name);
};

void* get_adi_symbol(ElfLoader* primary, ElfLoader* secondary, const char* obfuscated_key, const char* readable_fallback = nullptr);

#endif
#endif

#endif /* ELF_LOADER_HOST_H */
