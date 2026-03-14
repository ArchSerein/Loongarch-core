#!/usr/bin/env python3
"""
Convert C preprocessor macros to Bluespec/Verilog macros.

This script converts C-style preprocessor directives to Bluespec/Verilog-style
macro definitions. It handles:
- #define -> `define conversion
- #ifdef/#ifndef/#endif -> `ifdef/`ifndef/`endif
- #include -> `include
- Hex value conversion: 0x... -> 32'h...
- Decimal value handling
- Function-like macros
"""

import re
import argparse
import sys
from pathlib import Path


def load_config_values(config_path: str) -> dict:
    """
    Load config values from .config file.
    Returns a dict mapping config name to its value (or 'y' for boolean enabled).
    """
    config_values = {}
    if not config_path or not Path(config_path).exists():
        return config_values

    with open(config_path, "r") as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith("#"):
                continue
            # Parse CONFIG_NAME=value
            if "=" in line:
                key, value = line.split("=", 1)
                config_values[key] = value
    return config_values


def convert_hex_value(value: str) -> str:
    """Convert C hex literal (0x...) to Verilog hex literal (32'h...)."""
    # Match hex patterns like 0x1, 0xa04d5838, etc.
    hex_pattern = r"^0x([0-9a-fA-F]+)$"

    match = re.match(hex_pattern, value.strip())
    if match:
        hex_digits = match.group(1)
        # Determine width based on number of hex digits
        num_digits = len(hex_digits)
        # Each hex digit is 4 bits, calculate minimum width (power of 2)
        if num_digits <= 2:
            width = 8
        elif num_digits <= 4:
            width = 16
        elif num_digits <= 8:
            width = 32
        else:
            width = 64
        return f"{width}'h{hex_digits}"

    return value


def convert_decimal_value(value: str) -> str:
    """Convert decimal value to Verilog format if needed."""
    value = value.strip()

    # Already hex
    if value.startswith("0x") or value.startswith("0X"):
        return convert_hex_value(value)

    # Check if it's a decimal number
    if re.match(r"^\d+$", value):
        return value  # Verilog accepts bare decimal numbers

    # Check for expressions or other values
    return value


def convert_define_line(line: str, default_width: int = 32, config_values: dict = None) -> str:
    """Convert a #define line to `define line."""
    if config_values is None:
        config_values = {}
    # Preserve trailing newline/whitespace
    stripped_line = line.rstrip()
    trailing = line[len(stripped_line) :]

    # Pattern for simple #define MACRO value
    simple_pattern = r"^\s*#define\s+(\w+)\s+(.+)$"

    # Pattern for function-like macros #define MACRO(args) value
    func_pattern = r"^\s*#define\s+(\w+)\s*\(([^)]*)\)\s*(.*)$"

    # Try function-like macro first
    func_match = re.match(func_pattern, stripped_line)
    if func_match:
        macro_name = func_match.group(1)
        args = func_match.group(2)
        value = func_match.group(3)
        converted_value = convert_value(value, default_width, config_values, macro_name)
        return f"`define {macro_name}({args}) {converted_value}{trailing}"

    # Try simple macro
    simple_match = re.match(simple_pattern, stripped_line)
    if simple_match:
        macro_name = simple_match.group(1)
        value = simple_match.group(2)
        converted_value = convert_value(value, default_width, config_values, macro_name)
        if converted_value == "":
            return f"`define {macro_name}{trailing}"
        return f"`define {macro_name} {converted_value}{trailing}"

    # Handle empty #define (just defined, no value)
    empty_pattern = r"^\s*#define\s+(\w+)\s*$"
    empty_match = re.match(empty_pattern, stripped_line)
    if empty_match:
        macro_name = empty_match.group(1)
        return f"`define {macro_name}{trailing}"

    return line


def convert_value(value: str, default_width: int = 32, config_values: dict = None, macro_name: str = None) -> str:
    """Convert a value from C to Verilog format."""
    if config_values is None:
        config_values = {}
    value = value.strip()

    # Check if this macro is set to y/n in .config
    if macro_name and macro_name in config_values:
        config_val = config_values[macro_name]
        if config_val == "y" or config_val == "n":
            return ""

    # Hex literal
    if value.startswith("0x") or value.startswith("0X"):
        return convert_hex_value(value)

    # Decimal literal
    if re.match(r"^\d+$", value):
        # Could wrap in width, but Verilog accepts bare decimals
        return value

    # String literal - keep as is
    if value.startswith('"') and value.endswith('"'):
        return value

    # Character literal
    if value.startswith("'") and value.endswith("'"):
        return value

    # Expression or other - keep as is but might need adjustment
    return value


def convert_line(line: str, default_width: int = 32, config_values: dict = None) -> str:
    """Convert a single line from C to Bluespec format."""
    if config_values is None:
        config_values = {}
    stripped = line.strip()

    # Skip empty lines and comments
    if not stripped:
        return line
    if stripped.startswith("//"):
        return line
    if stripped.startswith("/*") or stripped.startswith("*"):
        return line

    # Preserve original indentation
    indent_match = re.match(r"^(\s*)", line)
    indent = indent_match.group(1) if indent_match else ""
    trailing = (
        line.rstrip()[len(line.rstrip(" \t").rstrip()) :]
        if line.rstrip() != line
        else ""
    )

    # Actually, let's just work with the stripped version and preserve newlines
    rstripped = line.rstrip("\n")
    newline_count = len(line) - len(rstripped)
    trailing_newlines = "\n" * newline_count

    # #define -> `define
    if stripped.startswith("#define"):
        result = convert_define_line(rstripped, default_width, config_values)
        return result + trailing_newlines

    # For other directives, preserve the line structure
    result_line = line

    # #ifdef -> `ifdef
    if stripped.startswith("#ifdef"):
        result_line = re.sub(r"#ifdef", "`ifdef", line)

    # #ifndef -> `ifndef
    elif stripped.startswith("#ifndef"):
        result_line = re.sub(r"#ifndef", "`ifndef", line)

    # #endif -> `endif
    elif stripped.startswith("#endif"):
        result_line = re.sub(r"#endif", "`endif", line)

    # #else -> `else
    elif stripped.startswith("#else"):
        result_line = re.sub(r"#else", "`else", line)

    # #elif -> `elsif
    elif stripped.startswith("#elif"):
        result_line = re.sub(r"#elif", "`elsif", line)

    # #include -> `include
    elif stripped.startswith("#include"):
        # Convert #include "file" to `include "file"
        # and #include <file> to `include "file" (Bluespec uses quotes)
        result_line = re.sub(r"#include\s*<([^>]+)>", r'`include "\1"', line)
        result_line = re.sub(r"#include", "`include", result_line)

    # #undef -> `undef
    elif stripped.startswith("#undef"):
        result_line = re.sub(r"#undef", "`undef", line)

    return result_line


def convert_file(
    input_path: str, output_path: str = None, default_width: int = 32, config_path: str = None
) -> str:
    """
    Convert a C header file to Bluespec macro file.

    Args:
        input_path: Path to input C header file
        output_path: Path to output file (optional, prints to stdout if not provided)
        default_width: Default bit width for numeric values
        config_path: Path to .config file for y/n value handling

    Returns:
        Converted content as string
    """
    config_values = load_config_values(config_path)

    with open(input_path, "r") as f:
        lines = f.readlines()

    converted_lines = []
    in_multiline_comment = False

    for line in lines:
        # Handle multiline comments
        if "/*" in line:
            in_multiline_comment = True
        if "*/" in line:
            in_multiline_comment = False
            converted_lines.append(line)
            continue
        if in_multiline_comment:
            converted_lines.append(line)
            continue

        converted_lines.append(convert_line(line, default_width, config_values))

    content = "".join(converted_lines)

    if output_path:
        with open(output_path, "w") as f:
            f.write(content)
        print(f"Converted {input_path} -> {output_path}")

    return content


def get_output_path(input_path: str) -> str:
    """
    Generate output path from input path by changing extension.
    .h -> .bsv (Bluespec source file)
    """
    path = Path(input_path)
    return str(path.with_suffix(".bsv"))


def main():
    parser = argparse.ArgumentParser(
        description="Convert C preprocessor macros to Bluespec/Verilog macros"
    )
    parser.add_argument("input", help="Input C header file")
    parser.add_argument(
        "-o", "--output", help="Output file (default: same path with .bsv extension)"
    )
    parser.add_argument(
        "-w",
        "--width",
        type=int,
        default=32,
        help="Default bit width for hex values (default: 32)",
    )
    parser.add_argument(
        "-c",
        "--config",
        help="Path to .config file for y/n value handling",
    )
    parser.add_argument(
        "-p",
        "--print",
        action="store_true",
        dest="print_output",
        help="Print output to stdout instead of file",
    )

    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        print(f"Error: Input file '{args.input}' not found", file=sys.stderr)
        sys.exit(1)

    # Determine output path
    if args.print_output:
        output_path = None
    elif args.output:
        output_path = args.output
    else:
        output_path = get_output_path(args.input)

    content = convert_file(args.input, output_path, args.width, args.config)

    if args.print_output:
        print(content)


if __name__ == "__main__":
    main()
