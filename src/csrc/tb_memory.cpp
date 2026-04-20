#include "tb_memory.hpp"
#include <cstdio>
#include <cstdlib>
#include <vector>

#define BYTES2WORD(data0, data1, data2, data3) \
    (data3 << 24) | (data2 << 16) | (data1 << 8) | data0

bool Memory::isConfregAddress(std::uint32_t addr) {
    return (addr & 0xffff0000u) == kConfregVirtPrefix ||
           (addr & 0xffff0000u) == kConfregPhysPrefix;
}

bool Memory::isUart16550Address(std::uint32_t addr) {
    return (addr & 0xfffffff8u) == kUart16550VirtBase ||
           (addr & 0xfffffff8u) == kUart16550PhysBase;
}

bool Memory::isLiointcAddress(std::uint32_t addr) {
    return addr >= kLiointcPhysBase && addr < kLiointcPhysBase + kLiointcSize;
}

bool Memory::isLs1cMmioAddress(std::uint32_t addr) {
    return addr >= kLs1cMmioPhysBase && addr < kLs1cMmioPhysBase + kLs1cMmioSize;
}

bool Memory::isPmemAddress(std::uint32_t addr) {
    std::uint32_t seg = addr >> 24;
    return seg < (1u << (kTbPmemAddrWidth - 24)) ||
           seg == 0x80 ||
           seg == 0xa0;
}

std::size_t Memory::pmemOffset(std::uint32_t addr) {
    std::uint32_t seg = addr >> 24;
    return (seg == 0x80 || seg == 0xa0) ? (addr & 0x1ffffffful) : addr;
}

std::uint32_t Memory::alignWord(std::uint32_t addr) {
    return addr & ~0x3u;
}

bool Memory::isDeviceAddress(std::uint32_t addr) const {
    return (isConfregAddress(addr) && mmio.isDeviceAddress(static_cast<std::uint16_t>(addr & 0xffffu))) ||
           isUart16550Address(addr) ||
           isLiointcAddress(addr) ||
           isLs1cMmioAddress(addr);
}

void Memory::openUartLog() {
    if (uart_simu_ == nullptr) {
        uart_simu_ = std::fopen("/root/Loongarch-core/src/build/uart_log.txt", "wb");
    }
}

std::uint8_t Memory::uart16550ReadByte(std::uint32_t addr) const {
    std::uint32_t reg = addr & 0x7u;
    if (reg == 5u) {
        // THRE | TEMT: transmit FIFO is always ready in the testbench model.
        return 0x60u;
    }
    return uart16550_[reg];
}

void Memory::uart16550WriteByte(std::uint32_t addr, std::uint8_t value) {
    std::uint32_t reg = addr & 0x7u;
    uart16550_[reg] = value;
    // Offset 0 is the transmit holding register when DLAB is clear.
    if (reg == 0u && (uart16550_[3] & 0x80u) == 0u) {
        std::cout.put(static_cast<char>(value));
        std::cout.flush();
        if (uart_simu_ != nullptr) {
            std::fwrite(&value, 1, 1, uart_simu_);
        }
    }
}

std::uint8_t Memory::liointcReadByte(std::uint32_t addr) const {
    (void)addr;
    return 0;
}

void Memory::liointcWriteByte(std::uint32_t addr, std::uint8_t value) {
    (void)addr;
    (void)value;
}

std::uint8_t Memory::ls1cMmioReadByte(std::uint32_t addr) const {
    (void)addr;
    return 0;
}

void Memory::ls1cMmioWriteByte(std::uint32_t addr, std::uint8_t value) {
    (void)addr;
    (void)value;
}

std::uint32_t Memory::memory_dispatch_read(std::size_t addr) const {
    std::uint32_t word_addr = alignWord(static_cast<std::uint32_t>(addr));
    std::uint32_t pa = Memory::guest_to_host(word_addr);
    std::uint32_t data;
    if (isConfregAddress(word_addr)) {
        return Memory::mmio.read(word_addr & 0xffffu);
    } else if (isUart16550Address(word_addr)) {
        return BYTES2WORD(
            uart16550ReadByte(word_addr + 0),
            uart16550ReadByte(word_addr + 1),
            uart16550ReadByte(word_addr + 2),
            uart16550ReadByte(word_addr + 3));
    } else if (isLiointcAddress(word_addr)) {
        return BYTES2WORD(
            liointcReadByte(word_addr + 0),
            liointcReadByte(word_addr + 1),
            liointcReadByte(word_addr + 2),
            liointcReadByte(word_addr + 3));
    } else if (isLs1cMmioAddress(word_addr)) {
        return BYTES2WORD(
            ls1cMmioReadByte(word_addr + 0),
            ls1cMmioReadByte(word_addr + 1),
            ls1cMmioReadByte(word_addr + 2),
            ls1cMmioReadByte(word_addr + 3));
    } else if (isPmemAddress(word_addr)) {
        std::size_t pmem_addr = pmemOffset(word_addr);
        if (pmem_addr + 3 >= Memory::pmem_.size()) {
            std::fprintf(stderr, "memory_dispatch_read: out of range addr=0x%08x pmem=0x%08lx\n",
                         word_addr, pmem_addr);
            std::abort();
        }
        data = BYTES2WORD(  Memory::pmem_[pmem_addr+0],
                            Memory::pmem_[pmem_addr+1],
                            Memory::pmem_[pmem_addr+2],
                            Memory::pmem_[pmem_addr+3]);
        if (((pmem_addr & 0x00fffff0ul) == 0x000d0010ul) || ((word_addr & 0xfffffff0ul) == 0xa0000000ul)) {
            std::fprintf(stderr, "[TMMIO] READ  addr=0x%08x data=0x%08x src=pmem paddr=0x%08lx\n", word_addr, data, pmem_addr);
        }
        #ifdef CONFIG_MTRACE
        printf("read: addr->0x%08lx data->0x%08x\n", word_addr, data);
        #endif
        return data;
    } else {
        if (pa + 3 >= Memory::words_.size()) {
            std::fprintf(stderr, "memory_dispatch_read: out of range addr=0x%08x pa=0x%08x\n",
                         word_addr, pa);
            std::abort();
        }
        data = BYTES2WORD(  Memory::words_[pa+0],
                            Memory::words_[pa+1],
                            Memory::words_[pa+2],
                            Memory::words_[pa+3]);
        if ((word_addr & 0x00fffff0ul) == 0x000d0010ul) {
            std::fprintf(stderr, "[TMMIO] READ  addr=0x%08x data=0x%08x src=words pa=0x%08x\n", word_addr, data, pa);
        }
        #ifdef CONFIG_MTRACE
        printf("read: addr->0x%08lx data->0x%08x\n", word_addr, data);
        #endif
        return data;
    }
}

void Memory::memory_dispatch_write(std::size_t addr, std::uint32_t data, std::uint8_t mask) {
    std::uint32_t word_addr = alignWord(static_cast<std::uint32_t>(addr));
    auto host_addr = Memory::guest_to_host(word_addr);
    std::uint8_t vec[4] = {
        static_cast<std::uint8_t>(data),
        static_cast<std::uint8_t>(data >> 8),
        static_cast<std::uint8_t>(data >> 16),
        static_cast<std::uint8_t>(data >> 24)
    };
    if (isConfregAddress(word_addr)) {
        Memory::mmio.write(static_cast<std::uint16_t>(word_addr & 0xffffu), data);
    } else if (isUart16550Address(word_addr)) {
        for (std::uint32_t i = 0; i < 4; i++) {
            if ((mask >> i) & 1u) {
                uart16550WriteByte(word_addr + i, vec[i]);
            }
        }
    } else if (isLiointcAddress(word_addr)) {
        for (std::uint32_t i = 0; i < 4; i++) {
            if ((mask >> i) & 1u) {
                liointcWriteByte(word_addr + i, vec[i]);
            }
        }
    } else if (isLs1cMmioAddress(word_addr)) {
        for (std::uint32_t i = 0; i < 4; i++) {
            if ((mask >> i) & 1u) {
                ls1cMmioWriteByte(word_addr + i, vec[i]);
            }
        }
    } else if (isPmemAddress(word_addr)) {
        std::size_t pmem_addr = pmemOffset(word_addr);
        if (pmem_addr + 3 >= Memory::pmem_.size()) {
            std::fprintf(stderr, "memory_dispatch_write: out of range addr=0x%08x pmem=0x%08lx\n",
                         word_addr, pmem_addr);
            std::abort();
        }
        #ifdef CONFIG_MTRACE
        printf("write: addr->0x%08lx data 0x%08x\n", word_addr, data);
        #endif
        for (std::uint32_t i = 0; i < 4; i++)
            if ((mask >> i) & 1) Memory::pmem_[pmem_addr+i] = vec[i];
        if (((pmem_addr & 0x00fffff0ul) == 0x000d0010ul) || ((word_addr & 0xfffffff0ul) == 0xa0000000ul)) {
            std::fprintf(stderr, "[TMMIO] WRITE addr=0x%08x data=0x%08x src=pmem paddr=0x%08lx mask=0x%02x\n", word_addr, data, pmem_addr, mask);
        }
    } else {
        if (host_addr + 3 >= Memory::words_.size()) {
            std::fprintf(stderr, "memory_dispatch_write: out of range addr=0x%08x pa=0x%08x\n",
                         word_addr, host_addr);
            std::abort();
        }
        #ifdef CONFIG_MTRACE
        printf("write: addr->0x%08lx data 0x%08x\n", word_addr, data);
        #endif
        for (std::uint32_t i = 0; i < 4; i++)
            if ((mask >> i) & 1) Memory::words_[host_addr+i] = vec[i];
        if ((word_addr & 0x00fffff0ul) == 0x000d0010ul) {
            std::fprintf(stderr, "[TMMIO] WRITE addr=0x%08x data=0x%08x src=words pa=0x%08x mask=0x%02x\n", word_addr, data, host_addr, mask);
        }
    }
}

std::uint32_t Memory::guest_to_host(std::uint32_t addr) const {
    std::uint32_t pa = addr - Memory::_mem_base;
    return pa;
}
