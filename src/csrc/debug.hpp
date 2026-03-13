#pragma once

#include <cassert>
#define panic(fmt, ...) \
    do { \
        fprintf(stderr, "\033[1;31m[panic]\033[0m \033[1;34m[%s:%d]\033[0m " fmt "\n", __FILE__, __LINE__, ## __VA_ARGS__); \
        assert(0); \
    } while (0)

#define Log(fmt, ...) \
    do { \
        fprintf(stdout, "\033[1;34m[log-tracer]\033[0m \033[1;34m[%s:%d]\033[0m " fmt "\n", __FILE__, __LINE__, ## __VA_ARGS__); \
    } while (0)

#define Trace(filename, content) \
    do { \
        FILE *file = fopen(filename, "a"); \
        if (file != NULL) { \
            fprintf(file, "pc: %08x\n", content); \
            fclose(file); \
        } else { \
            perror("Error opening file"); \
        } \
    } while (0)

#define ASSERT_INFO(condition, fmt, ...) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "\033[1;31m[panic]\033[0m \033[1;34m[%s:%d]\033[0m " fmt "\n", __FILE__, __LINE__, ## __VA_ARGS__); \
            assert(0); \
        } \
    } while (0)
