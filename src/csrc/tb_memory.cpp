#include "tb_memory.hpp"
#include <cstdio>
#include <cstdlib>
#include <vector>

#define BYTES2WORD(data0, data1, data2, data3) \
    (data3 << 24) | (data2 << 16) | (data1 << 8) | data0

std::uint32_t Memory::memory_dispatch_read(std::size_t addr) const {
    std::uint32_t pa = Memory::guest_to_host(addr);
    std::uint32_t data;
    std::uint32_t seg = static_cast<std::uint32_t>(addr >> 24);
    if ((addr >> 16) == 0xbfaf) {
        return Memory::mmio.read(addr & 0xffff);
    } else if (seg == 0x00 || seg == 0x80 || seg == 0xa0) {
        std::size_t pmem_addr = (seg == 0x80 || seg == 0xa0) ? (addr & 0x1ffffffful) : addr;
        if (pmem_addr + 3 >= Memory::pmem_.size()) {
            std::fprintf(stderr, "memory_dispatch_read: out of range addr=0x%08lx pmem=0x%08lx\n",
                         addr, pmem_addr);
            std::abort();
        }
        data = BYTES2WORD(  Memory::pmem_[pmem_addr+0],
                            Memory::pmem_[pmem_addr+1],
                            Memory::pmem_[pmem_addr+2],
                            Memory::pmem_[pmem_addr+3]);
        if (((pmem_addr & 0x00fffff0ul) == 0x000d0010ul) || ((addr & 0xfffffff0ul) == 0xa0000000ul)) {
            std::fprintf(stderr, "[TMMIO] READ  addr=0x%08lx data=0x%08x src=pmem paddr=0x%08lx\n", addr, data, pmem_addr);
        }
        #ifdef CONFIG_MTRACE
        printf("read: addr->0x%08lx data->0x%08x\n", addr, data);
        #endif
        return data;
    } else {
        if (pa + 3 >= Memory::words_.size()) {
            std::fprintf(stderr, "memory_dispatch_read: out of range addr=0x%08lx pa=0x%08x\n",
                         addr, pa);
            std::abort();
        }
        data = BYTES2WORD(  Memory::words_[pa+0],
                            Memory::words_[pa+1],
                            Memory::words_[pa+2],
                            Memory::words_[pa+3]);
        if ((addr & 0x00fffff0ul) == 0x000d0010ul) {
            std::fprintf(stderr, "[TMMIO] READ  addr=0x%08lx data=0x%08x src=words pa=0x%08x\n", addr, data, pa);
        }
        #ifdef CONFIG_MTRACE
        printf("read: addr->0x%08lx data->0x%08x\n", addr, data);
        #endif
        return data;
    }
}

void Memory::memory_dispatch_write(std::size_t addr, std::uint32_t data, std::uint8_t mask) {
    auto host_addr = Memory::guest_to_host(addr);
    std::uint8_t vec[4] = {
        static_cast<std::uint8_t>(data),
        static_cast<std::uint8_t>(data >> 8),
        static_cast<std::uint8_t>(data >> 16),
        static_cast<std::uint8_t>(data >> 24)
    };
    std::uint32_t seg = static_cast<std::uint32_t>(addr >> 24);
    if ((addr >> 16) == 0xbfaf) {
        Memory::mmio.write(addr & 0xffff, data);
    } else if (seg == 0x00 || seg == 0x80 || seg == 0xa0) {
        std::size_t pmem_addr = (seg == 0x80 || seg == 0xa0) ? (addr & 0x1ffffffful) : addr;
        if (pmem_addr + 3 >= Memory::pmem_.size()) {
            std::fprintf(stderr, "memory_dispatch_write: out of range addr=0x%08lx pmem=0x%08lx\n",
                         addr, pmem_addr);
            std::abort();
        }
        #ifdef CONFIG_MTRACE
        printf("write: addr->0x%08lx data 0x%08x\n", addr, data);
        #endif
        for (std::uint32_t i = 0; i < 4; i++)
            if ((mask >> i) & 1) Memory::pmem_[pmem_addr+i] = vec[i];
        if (((pmem_addr & 0x00fffff0ul) == 0x000d0010ul) || ((addr & 0xfffffff0ul) == 0xa0000000ul)) {
            std::fprintf(stderr, "[TMMIO] WRITE addr=0x%08lx data=0x%08x src=pmem paddr=0x%08lx mask=0x%02x\n", addr, data, pmem_addr, mask);
        }
    } else {
        if (host_addr + 3 >= Memory::words_.size()) {
            std::fprintf(stderr, "memory_dispatch_write: out of range addr=0x%08lx pa=0x%08x\n",
                         addr, host_addr);
            std::abort();
        }
        #ifdef CONFIG_MTRACE
        printf("write: addr->0x%08lx data 0x%08x\n", addr, data);
        #endif
        for (std::uint32_t i = 0; i < 4; i++)
            if ((mask >> i) & 1) Memory::words_[host_addr+i] = vec[i];
        if ((addr & 0x00fffff0ul) == 0x000d0010ul) {
            std::fprintf(stderr, "[TMMIO] WRITE addr=0x%08lx data=0x%08x src=words pa=0x%08x mask=0x%02x\n", addr, data, host_addr, mask);
        }
    }
}

std::uint32_t Memory::guest_to_host(std::uint32_t addr) const {
    std::uint32_t pa = addr - Memory::_mem_base;
    return pa;
}
