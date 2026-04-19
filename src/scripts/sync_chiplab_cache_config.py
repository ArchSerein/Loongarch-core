#!/usr/bin/env python3

import argparse
import math
import pathlib
import re
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sync ChipLab cache macros from the authoritative src/.config."
    )
    parser.add_argument("--config", required=True, help="Path to src/.config")
    parser.add_argument("--common-mk", required=True, help="Path to ChipLab bsp/common.mk")
    return parser.parse_args()


def load_config(path: pathlib.Path) -> dict[str, int]:
    text = path.read_text()
    keys = [
        "CONFIG_ICACHE_SETS",
        "CONFIG_ICACHE_WAYS",
        "CONFIG_ICACHE_LINE_WORDS",
        "CONFIG_DCACHE_SETS",
        "CONFIG_DCACHE_WAYS",
        "CONFIG_DCACHE_LINE_WORDS",
    ]
    values: dict[str, int] = {}
    for key in keys:
        match = re.search(rf"^{re.escape(key)}=(\S+)$", text, re.MULTILINE)
        if match is None:
            raise ValueError(f"missing {key} in {path}")
        values[key] = int(match.group(1), 0)
    return values


def require_equal(name: str, lhs: int, rhs: int) -> int:
    if lhs != rhs:
        raise ValueError(
            f"ChipLab boot macros currently support one shared cache geometry, "
            f"but {name} differs between ICache ({lhs}) and DCache ({rhs})"
        )
    return lhs


def require_pow2(name: str, value: int) -> int:
    if value <= 0 or (value & (value - 1)) != 0:
        raise ValueError(f"{name} must be a positive power of two, got {value}")
    return value


def format_hex(value: int) -> str:
    return f"0x{value:x}"


def sync_common_mk(common_mk: pathlib.Path, sets: int, ways: int, line_words: int) -> bool:
    offset_width = int(math.log2(line_words)) + 2
    old_text = common_mk.read_text()
    macro_line = (
        "CFLAGS += "
        f"-Dhas_cache=1 "
        f"-Dcache_index_depth={format_hex(sets)} "
        f"-Dcache_offset_width={format_hex(offset_width)} "
        f"-Dcache_way={format_hex(ways)}"
    )
    new_text, replacements = re.subn(
        r"^CFLAGS \+= -Dhas_cache=.*$",
        macro_line,
        old_text,
        count=1,
        flags=re.MULTILINE,
    )
    if replacements != 1:
        raise ValueError(f"failed to locate cache macro line in {common_mk}")
    if new_text != old_text:
        common_mk.write_text(new_text)
        return True
    return False


def main() -> int:
    args = parse_args()
    config_path = pathlib.Path(args.config)
    common_mk_path = pathlib.Path(args.common_mk)

    values = load_config(config_path)
    sets = require_equal(
        "set count", values["CONFIG_ICACHE_SETS"], values["CONFIG_DCACHE_SETS"]
    )
    ways = require_equal(
        "way count", values["CONFIG_ICACHE_WAYS"], values["CONFIG_DCACHE_WAYS"]
    )
    line_words = require_equal(
        "line size", values["CONFIG_ICACHE_LINE_WORDS"], values["CONFIG_DCACHE_LINE_WORDS"]
    )
    require_pow2("cache line words", line_words)

    changed = sync_common_mk(common_mk_path, sets, ways, line_words)
    state = "updated" if changed else "already up to date"
    print(
        f"sync_chiplab_cache_config: {state} "
        f"(sets={format_hex(sets)}, ways={format_hex(ways)}, offset_width={format_hex(int(math.log2(line_words)) + 2)})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as err:
        print(f"sync_chiplab_cache_config: error: {err}", file=sys.stderr)
        raise SystemExit(1)
