#pragma once
#include <iostream>
#include <unordered_map>
#include <cstdint>
#include <array>

namespace MemoryMap {
    enum class DeviceAddr : uint16_t {
        CR0 = 0x8000, CR1 = 0x8010, CR2 = 0x8020, CR3 = 0x8030,
        CR4 = 0x8040, CR5 = 0x8050, CR6 = 0x8060, CR7 = 0x8070,
        
        LED = 0xF020, LED_RG0 = 0xF030, LED_RG1 = 0xF040, NUM = 0xF050,
        SWITCH = 0xF060, BTN_KEY = 0xF070, BTN_STEP = 0xF080, SW_INTER = 0xF090,
        TIMER = 0xE000,
        
        IO_SIMU = 0xFF00, VIRTUAL_UART = 0xFF10, SIMU_FLAG = 0xFF20,
        OPEN_TRACE = 0xFF30, NUM_MONITOR = 0xFF40
    };

    // Corrected to uniquely contain all 22 registers
    static constexpr std::array<DeviceAddr, 22> kAllDeviceAddrs = {
        DeviceAddr::CR0, DeviceAddr::CR1, DeviceAddr::CR2, DeviceAddr::CR3,
        DeviceAddr::CR4, DeviceAddr::CR5, DeviceAddr::CR6, DeviceAddr::CR7,
        DeviceAddr::LED, DeviceAddr::LED_RG0, DeviceAddr::LED_RG1, DeviceAddr::NUM,
        DeviceAddr::SWITCH, DeviceAddr::BTN_KEY, DeviceAddr::BTN_STEP, DeviceAddr::SW_INTER,
        DeviceAddr::TIMER,
        DeviceAddr::IO_SIMU, DeviceAddr::VIRTUAL_UART, DeviceAddr::SIMU_FLAG,
        DeviceAddr::OPEN_TRACE, DeviceAddr::NUM_MONITOR
    }; 
}

class MMIOMap {
private:
    std::unordered_map<MemoryMap::DeviceAddr, uint32_t> registers;

public:
    MMIOMap() {
        // Pre-bind a 32-bit variable (initialized to 0) to every valid address at startup
        for (const auto& addr : MemoryMap::kAllDeviceAddrs) {
            registers[addr] = 0;
        }
    }

    // Check using the strongly-typed enum
    bool isDeviceAddress(MemoryMap::DeviceAddr addr) const {
        return registers.find(addr) != registers.end();
    }

    bool isDeviceAddress(uint16_t rawAddr) const {
        // Cast the raw uint16_t to the enum to safely look it up in the map
        auto addrEnum = static_cast<MemoryMap::DeviceAddr>(rawAddr);
        return isDeviceAddress(addrEnum);
    }

    // ----------------------------------------------------
    // Read and Write Methods (Protected by validation)
    // ----------------------------------------------------
    
    uint32_t read(uint16_t rawAddr) const {
        if (isDeviceAddress(rawAddr)) {
            // .at() is safe here because we just proved the address exists
            return registers.at(static_cast<MemoryMap::DeviceAddr>(rawAddr));
        }
        
        // Fallback for reading from unmapped memory
        std::cerr << "Warning: Read from unmapped address 0x" << std::hex << rawAddr << '\n';
        return 0; 
    }

    void write(uint16_t rawAddr, uint32_t value) {
        if (isDeviceAddress(rawAddr)) {
            registers[static_cast<MemoryMap::DeviceAddr>(rawAddr)] = value;
        } else {
            // Fallback for writing to unmapped memory
            std::cerr << "Warning: Write to unmapped address 0x" << std::hex << rawAddr << '\n';
        }
    }
};