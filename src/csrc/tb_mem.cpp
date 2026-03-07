#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct TbMemory {
  explicit TbMemory(std::uint32_t word_addr_width)
      : words(std::size_t{1} << word_addr_width, 0) {}

  std::vector<std::uint32_t> words;
};

std::string mem_image_path() {
  const char* from_env = std::getenv("TB_MEM_IMAGE");
  if (from_env != nullptr && *from_env != '\0') {
    return from_env;
  }
  return "build/mem.bin";
}

void load_mem_image(TbMemory& mem, const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input.is_open()) {
    std::cerr << "tb_mem: no memory image at " << path << ", starting from zeroed memory\n";
    return;
  }

  // Get file size
  input.seekg(0, std::ios::end);
  const std::size_t file_size = input.tellg();
  input.seekg(0, std::ios::beg);

  // Read binary data directly into memory (little-endian words)
  const std::size_t word_count = (file_size + 3) / 4;
  if (word_count > mem.words.size()) {
    std::cerr << "tb_mem: image too large (" << file_size << " bytes) for memory\n";
    std::exit(1);
  }

  for (std::size_t i = 0; i < word_count; ++i) {
    std::uint8_t bytes[4] = {0, 0, 0, 0};
    input.read(reinterpret_cast<char*>(bytes), 4);
    // Little-endian: LSB first
    mem.words[i] = static_cast<std::uint32_t>(bytes[0]) |
                   (static_cast<std::uint32_t>(bytes[1]) << 8) |
                   (static_cast<std::uint32_t>(bytes[2]) << 16) |
                   (static_cast<std::uint32_t>(bytes[3]) << 24);
  }
}

TbMemory& get_mem(std::uint64_t mem_ptr) {
  auto* mem = reinterpret_cast<TbMemory*>(mem_ptr);
  if (mem == nullptr) {
    std::cerr << "tb_mem: null memory pointer\n";
    std::exit(1);
  }
  return *mem;
}

}  // namespace

extern "C" std::uint64_t c_createTbMem(std::uint32_t word_addr_width) {
  if (word_addr_width >= 31) {
    std::cerr << "tb_mem: unsupported word address width " << word_addr_width << '\n';
    std::exit(1);
  }

  auto* mem = new TbMemory(word_addr_width);
  return reinterpret_cast<std::uint64_t>(mem);
}

extern "C" void c_loadTbMem(std::uint64_t mem_ptr) {
  TbMemory& mem = get_mem(mem_ptr);
  load_mem_image(mem, mem_image_path());
}

extern "C" std::uint32_t c_readTbMem(std::uint64_t mem_ptr, std::uint32_t word_addr) {
  TbMemory& mem = get_mem(mem_ptr);
  if (word_addr >= mem.words.size()) {
    std::cerr << "tb_mem: read out of range at word address 0x" << std::hex << word_addr << std::dec << '\n';
    std::exit(1);
  }
  return mem.words[word_addr];
}

extern "C" void c_writeTbMem(std::uint64_t mem_ptr, std::uint32_t word_addr, std::uint32_t data) {
  TbMemory& mem = get_mem(mem_ptr);
  if (word_addr >= mem.words.size()) {
    std::cerr << "tb_mem: write out of range at word address 0x" << std::hex << word_addr << std::dec << '\n';
    std::exit(1);
  }
  mem.words[word_addr] = data;
}
