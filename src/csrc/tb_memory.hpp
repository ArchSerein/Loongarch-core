#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <vector>
#include <cstdint>
#include <array>
#include "mmio.hpp"

class Memory {
public:
    static constexpr std::size_t kTbWordAddrWidth = 22;
    static constexpr std::size_t kTbPmemAddrWidth = 27;
    static constexpr std::uint32_t kConfregVirtPrefix = 0xbfaf0000u;
    static constexpr std::uint32_t kConfregPhysPrefix = 0x1faf0000u;
    static constexpr std::uint32_t kUart16550VirtBase = 0xbfe001e0u;
    static constexpr std::uint32_t kUart16550PhysBase = 0x1fe001e0u;
    static constexpr std::uint32_t kLiointcPhysBase = 0x15103000u;
    static constexpr std::size_t kLiointcSize = 0x1000u;
    static constexpr std::uint32_t kLs1cMmioPhysBase = 0x1fe00000u;
    static constexpr std::size_t kLs1cMmioSize = 0x200000u;

    Memory(MMIOMap& mmio_ref) : words_(std::size_t{1} << kTbWordAddrWidth, 0),
        pmem_(std::size_t{1} << kTbPmemAddrWidth), mmio(mmio_ref) {
        openUartLog();
    }

    ~Memory() {
        if (uart_simu_ != nullptr) {
            std::fclose(uart_simu_);
        }
    }

    void write(std::size_t addr, std::uint32_t value, std::uint8_t mask) {
        memory_dispatch_write(addr, value, mask);
    }

    std::uint32_t read(std::size_t addr) const {
        return memory_dispatch_read(addr);
    }
    std::uint32_t get_words_size() const {
        return static_cast<std::uint32_t>(std::size_t{1} << kTbWordAddrWidth);
    }

    void set_base_addr(std::uint32_t base) {
        _mem_base = base;
    }

    void init(std::vector<std::uint8_t>& buffer) {
        std::copy(buffer.begin(), buffer.end(), Memory::words_.begin());
        openUartLog();
    }

    const std::uint8_t* raw_data() const {
        return words_.data();
    }

    std::size_t raw_size() const {
        return words_.size();
    }

    bool isDeviceAddress(std::uint32_t addr) const;

private:
    std::vector<std::uint8_t> words_;
    std::vector<std::uint8_t> pmem_;
    std::FILE* uart_simu_ = nullptr;
    MMIOMap& mmio;
    std::array<std::uint8_t, 8> uart16550_{};
    std::uint32_t _mem_base;
    std::uint32_t memory_dispatch_read(std::size_t) const;
    void memory_dispatch_write(std::size_t, std::uint32_t, std::uint8_t);
    std::uint32_t guest_to_host(std::uint32_t) const;
    static bool isConfregAddress(std::uint32_t addr);
    static bool isUart16550Address(std::uint32_t addr);
    static bool isLiointcAddress(std::uint32_t addr);
    static bool isLs1cMmioAddress(std::uint32_t addr);
    static bool isPmemAddress(std::uint32_t addr);
    static std::size_t pmemOffset(std::uint32_t addr);
    static std::uint32_t alignWord(std::uint32_t addr);
    void openUartLog();
    std::uint8_t uart16550ReadByte(std::uint32_t addr) const;
    void uart16550WriteByte(std::uint32_t addr, std::uint8_t value);
    std::uint8_t liointcReadByte(std::uint32_t addr) const;
    void liointcWriteByte(std::uint32_t addr, std::uint8_t value);
    std::uint8_t ls1cMmioReadByte(std::uint32_t addr) const;
    void ls1cMmioWriteByte(std::uint32_t addr, std::uint8_t value);
};
