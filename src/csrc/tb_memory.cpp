#include "tb_memory.hpp"
#include <cstdio>
#include <vector>

#define BYTES2WORD(data0, data1, data2, data3) \
    (data3 << 24) | (data2 << 16) | (data1 << 8) | data0

static void append_uint32(std::vector<uint8_t>& vec, uint32_t value, bool little_endian = true) {
    if (little_endian) {
        vec.push_back(static_cast<uint8_t>(value));
        vec.push_back(static_cast<uint8_t>(value >> 8));
        vec.push_back(static_cast<uint8_t>(value >> 16));
        vec.push_back(static_cast<uint8_t>(value >> 24));
    } else {
        vec.push_back(static_cast<uint8_t>(value >> 24));
        vec.push_back(static_cast<uint8_t>(value >> 16));
        vec.push_back(static_cast<uint8_t>(value >> 8));
        vec.push_back(static_cast<uint8_t>(value));
    }
} 
std::uint32_t Memory::memory_dispatch_read(std::size_t addr) const {
    std::uint32_t pa = Memory::guest_to_host(addr);
    std::uint32_t data;
    switch (addr >> 16) {
        case 0xbfaf:
            return Memory::mmio.read(addr & 0xffff);
        default:
            data = BYTES2WORD(  Memory::words_[pa+0],
                                Memory::words_[pa+1],
                                Memory::words_[pa+2],
                                Memory::words_[pa+3]);
            printf("read: addr->0x%08lx data->0x%08x\n", addr, data);
            return data;
    }
}

void Memory::memory_dispatch_write(std::size_t addr, std::uint32_t data, std::uint8_t mask) {
    auto paddr = Memory::guest_to_host(addr);
    std::vector<std::uint8_t> vec(4);
    switch (addr >> 16) {
        case 0xbfaf:
            Memory::mmio.write(addr&0xffff, data);
        default:
            printf("write: addr->0x%08lx data 0x%08x\n", addr, data);
            append_uint32(vec, data);
            for (std::uint32_t i = 0; i < 4; i++)
                Memory::words_[paddr+i] = vec[i];
            break;
    }
}

std::uint32_t Memory::guest_to_host(std::uint32_t addr) const {
    std::uint32_t pa = addr - Memory::_mem_base;
    return pa;
}
