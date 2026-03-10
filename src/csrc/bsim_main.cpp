#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

#include <unistd.h>

#include "SimIndication.h"
#include "SimRequest.h"

namespace {

constexpr std::uint32_t kTbWordAddrWidth = 20;

struct TbMemory {
  TbMemory() : words(std::size_t{1} << kTbWordAddrWidth, 0) {}
  std::vector<std::uint32_t> words;
};

struct Options {
  std::string mem_image = "build/mem.bin";
  std::uint32_t start_pc = 0;
};

static SimRequestProxy* g_request = nullptr;
static volatile int g_run = 1;
static std::uint32_t g_exit_code = 1;

Options parse_args(int argc, char** argv) {
  Options opts;
  const char* from_env = std::getenv("TB_MEM_IMAGE");
  if (from_env != nullptr && *from_env != '\0') {
    opts.mem_image = from_env;
  }

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--mem-image") == 0 && (i + 1) < argc) {
      opts.mem_image = argv[++i];
      continue;
    }
    if (std::strcmp(argv[i], "--start-pc") == 0 && (i + 1) < argc) {
      opts.start_pc = static_cast<std::uint32_t>(std::strtoul(argv[++i], nullptr, 0));
      continue;
    }
    std::cerr << "unknown argument: " << argv[i] << '\n';
    std::exit(2);
  }
  return opts;
}

void check_word_addr(std::uint32_t addr, std::size_t words, const char* op) {
  if (addr >= words) {
    std::cerr << "bsim: " << op << " out of range at word address 0x"
              << std::hex << addr << std::dec << '\n';
    g_exit_code = 1;
    g_run = 0;
  }
}

void load_mem_image(TbMemory& mem, const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input.is_open()) {
    std::cerr << "bsim: no memory image at " << path
              << ", starting from zeroed memory\n";
    return;
  }

  input.seekg(0, std::ios::end);
  const std::size_t file_size = static_cast<std::size_t>(input.tellg());
  input.seekg(0, std::ios::beg);

  const std::size_t word_count = (file_size + 3) / 4;
  if (word_count > mem.words.size()) {
    std::cerr << "bsim: memory image too large (" << file_size << " bytes)\n";
    std::exit(1);
  }

  for (std::size_t i = 0; i < word_count; ++i) {
    std::uint8_t bytes[4] = {0, 0, 0, 0};
    input.read(reinterpret_cast<char*>(bytes), 4);
    mem.words[i] = static_cast<std::uint32_t>(bytes[0]) |
                   (static_cast<std::uint32_t>(bytes[1]) << 8) |
                   (static_cast<std::uint32_t>(bytes[2]) << 16) |
                   (static_cast<std::uint32_t>(bytes[3]) << 24);
  }
}

class MySimIndicationCb final : public SimIndicationWrapper {
public:
  MySimIndicationCb(unsigned int id, TbMemory& mem_ref, std::uint32_t start_pc)
      : SimIndicationWrapper(id), mem(mem_ref) {
    _mem_base = start_pc;
  }

  void halt(std::uint32_t code) override {
    g_exit_code = code;
    g_run = 0;
  }

  void putc(std::uint8_t c) override {
    std::cout << static_cast<char>(c) << std::flush;
  }

  void read_mem_req(std::uint32_t addr) override {
    std::uint32_t paddr = guest_to_host(addr);
    printf("read addr 0x%08x data 0x%08x\n", addr, mem.words[paddr]);

    check_word_addr(paddr, mem.words.size(), "read");
    if (!g_run) {
      return;
    }
    g_request->read_mem_resp(mem.words[paddr]);
  }

  void write_mem_req(std::uint32_t addr, std::uint32_t data) override {
    printf("write addr 0x%08x data 0x%08x\n", addr, data);
    std::uint32_t paddr = guest_to_host(addr);
    check_word_addr(paddr, mem.words.size(), "write");
    if (!g_run) {
      return;
    }
    mem.words[paddr] = data;
  }

private:
  TbMemory& mem;
  std::uint32_t _mem_base;

  std::uint32_t guest_to_host(std::uint32_t addr) {
    std::uint32_t pa = addr - _mem_base;
    printf("vaddr 0x%08x tranlate to pa 0x%08x\n", addr, pa);
    return pa;
  }
};

}  // namespace

int main(int argc, char** argv) {
  const Options opts = parse_args(argc, argv);

  TbMemory mem;
  load_mem_image(mem, opts.mem_image);

  std::cout << "Start BSC Connectal simulation\n";
  std::cout.flush();

  g_request = new SimRequestProxy(IfcNames_SimRequestS2H);
  auto* indication = new MySimIndicationCb(IfcNames_SimIndicationH2S, mem, opts.start_pc);
  (void)indication;

  g_request->hostToCpu(opts.start_pc);

  while (g_run != 0) {
    usleep(1000);
  }

  if (g_exit_code == 0) {
    std::cerr << "\nbsim: PASSED\n";
  } else {
    std::cerr << "\nbsim: FAILED (code=" << g_exit_code << ")\n";
  }

  return static_cast<int>(g_exit_code);
}
