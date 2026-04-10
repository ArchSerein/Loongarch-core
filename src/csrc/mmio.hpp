#pragma once
#include <chrono>
#include <iostream>
#include <unordered_map>
#include <cstdint>
#include <array>

#include "debug.hpp"

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
    using DeviceAddr = MemoryMap::DeviceAddr;
    using Clock = std::chrono::steady_clock;

    std::unordered_map<MemoryMap::DeviceAddr, uint32_t> registers;
    uint8_t switch_state_ = 0;
    uint16_t btn_key_state_ = 0;
    uint8_t btn_step_state_ = 0;
    mutable Clock::time_point timer_anchor_ = Clock::now();
    mutable uint32_t timer_base_ = 0;

    static uint32_t packSwitchInterleave(uint8_t switches) {
        uint32_t value = 0;
        for (int i = 0; i < 8; ++i) {
            value |= static_cast<uint32_t>((switches >> i) & 0x1u) << (i * 2);
        }
        return value;
    }

    uint32_t currentTimerValue() const {
        constexpr std::uint64_t kTimerFreqHz = 100000000ull;
        const auto elapsed = Clock::now() - timer_anchor_;
        const auto elapsed_ns =
            static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count());
        const auto ticks = elapsed_ns * kTimerFreqHz / 1000000000ull;
        return timer_base_ + static_cast<uint32_t>(ticks);
    }

    void setTimerValue(uint32_t value) {
        timer_base_ = value;
        timer_anchor_ = Clock::now();
    }

public:
    MMIOMap() {
        // Pre-bind a 32-bit variable (initialized to 0) to every valid address at startup
        for (const auto& addr : MemoryMap::kAllDeviceAddrs) {
            registers[addr] = 0;
        }
        registers[DeviceAddr::SIMU_FLAG] = 1;
        registers[DeviceAddr::OPEN_TRACE] = 1;
        registers[DeviceAddr::NUM_MONITOR] = 1;
        setTimerValue(0);
    }

    // Check using the strongly-typed enum
    bool isDeviceAddress(MemoryMap::DeviceAddr addr) const {
        return registers.find(addr) != registers.end();
    }

    bool isDeviceAddress(uint16_t rawAddr) const {
        // Cast the raw uint16_t to the enum to safely look it up in the map
        auto addrEnum = static_cast<MemoryMap::DeviceAddr>(rawAddr);
        bool is_device = isDeviceAddress(addrEnum);
        ASSERT_INFO(is_device, "rawAddr %x", rawAddr);
        return is_device;
    }

    // ----------------------------------------------------
    // Read and Write Methods (Protected by validation)
    // ----------------------------------------------------
    
    uint32_t read(uint16_t rawAddr) const {
        if (isDeviceAddress(rawAddr)) {
            const auto addr = static_cast<DeviceAddr>(rawAddr);
            switch (addr) {
                case DeviceAddr::SWITCH:
                    return switch_state_;
                case DeviceAddr::BTN_KEY:
                    return btn_key_state_;
                case DeviceAddr::BTN_STEP:
                    return btn_step_state_ & 0x3u;
                case DeviceAddr::SW_INTER:
                    return packSwitchInterleave(switch_state_);
                case DeviceAddr::TIMER:
                    return currentTimerValue();
                case DeviceAddr::VIRTUAL_UART:
                    return registers.at(addr) & 0xffu;
                case DeviceAddr::OPEN_TRACE:
                case DeviceAddr::NUM_MONITOR:
                    return registers.at(addr) & 0x1u;
                default:
                    // .at() is safe here because we just proved the address exists
                    return registers.at(addr);
            }
        }

        // Fallback for reading from unmapped memory
        std::cerr << "Warning: Read from unmapped address 0x" << std::hex << rawAddr << '\n';
        return 0; 
    }

    void write(uint16_t rawAddr, uint32_t value) {
        if (isDeviceAddress(rawAddr)) {
            const auto addr = static_cast<DeviceAddr>(rawAddr);
            switch (addr) {
                case DeviceAddr::SWITCH:
                case DeviceAddr::BTN_KEY:
                case DeviceAddr::BTN_STEP:
                case DeviceAddr::SW_INTER:
                case DeviceAddr::SIMU_FLAG:
                    return;
                case DeviceAddr::TIMER:
                    setTimerValue(value);
                    return;
                case DeviceAddr::IO_SIMU:
                    registers[addr] = (value << 16) | (value >> 16);
                    return;
                case DeviceAddr::VIRTUAL_UART:
                    registers[addr] = value & 0xffu;
                    std::cout.put(static_cast<char>(value & 0xffu));
                    std::cout.flush();
                    return;
                case DeviceAddr::OPEN_TRACE:
                    registers[addr] = value != 0;
                    return;
                case DeviceAddr::NUM_MONITOR:
                    registers[addr] = value & 0x1u;
                    return;
                default:
                    registers[addr] = value;
                    return;
            }
        } else {
            // Fallback for writing to unmapped memory
            std::cerr << "Warning: Write to unmapped address 0x" << std::hex << rawAddr << '\n';
        }
    }

    void setSwitchState(uint8_t value) {
        switch_state_ = value;
    }

    void setBtnKeyState(uint16_t value) {
        btn_key_state_ = value;
    }

    void setBtnStepState(uint8_t value) {
        btn_step_state_ = value & 0x3u;
    }
};
