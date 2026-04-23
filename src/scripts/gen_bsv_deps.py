#!/usr/bin/env python3
import argparse
import os
import re
import sys

def get_deps(file_path, search_paths):
    deps = set()
    with open(file_path, 'r') as f:
        content = f.read()
        # Find imports: import Package::*;
        imports = re.findall(r'import\s+([\w\d_]+)\s*::\*', content)
        for imp in imports:
            # Look for imp.bsv in search paths
            for sp in search_paths:
                bsv_path = os.path.join(sp, f"{imp}.bsv")
                if os.path.exists(bsv_path):
                    deps.add(os.path.abspath(bsv_path))
                    break
        # Find includes: `include "file.bsv"
        includes = re.findall(r'`include\s+"([^"]+)"', content)
        for inc in includes:
            for sp in search_paths:
                inc_path = os.path.join(sp, inc)
                if os.path.exists(inc_path):
                    deps.add(os.path.abspath(inc_path))
                    break
    return deps

def make_var(name, values):
    if not name:
        return
    if not values:
        print(f"{name} :=")
        return
    print(f"{name} := \\")
    for idx, value in enumerate(values):
        suffix = " \\" if idx != len(values) - 1 else ""
        print(f"  {value}{suffix}")

def main():
    parser = argparse.ArgumentParser(
        description="Generate BSV .bo dependencies for Make."
    )
    parser.add_argument(
        "--order-var",
        help="Emit a Make variable with .bo files sorted by ascending dependency count.",
    )
    parser.add_argument("bdir")
    parser.add_argument("search_paths_colon_sep")
    parser.add_argument("top_bsv_files", nargs="+")
    args = parser.parse_args()

    bdir = args.bdir
    search_paths = [os.path.abspath(p) for p in args.search_paths_colon_sep.split(':') if p]
    top_files = args.top_bsv_files

    # Map from absolute path to .bo file in bdir
    def to_bo(path):
        name = os.path.basename(path).replace('.bsv', '.bo')
        return os.path.join(bdir, name)

    processed = set()
    to_process = [os.path.abspath(f) for f in top_files]
    all_deps = {}

    while to_process:
        curr = to_process.pop()
        if curr in processed:
            continue
        processed.add(curr)
        deps = get_deps(curr, search_paths)
        all_deps[curr] = deps
        for d in deps:
            if d not in processed:
                to_process.append(d)

    visiting = set()
    dep_set_cache = {}

    def transitive_deps(src):
        if src in dep_set_cache:
            return dep_set_cache[src]
        if src in visiting:
            return set()
        visiting.add(src)
        deps = all_deps.get(src, set())
        result = set(deps)
        for dep in deps:
            result.update(transitive_deps(dep))
        visiting.remove(src)
        dep_set_cache[src] = result
        return result

    def dep_order_key(src):
        return (
            len(transitive_deps(src)),
            len(all_deps.get(src, set())),
            os.path.basename(src),
        )

    ordered_srcs = sorted(all_deps, key=dep_order_key)
    ordered_bos = [to_bo(src) for src in ordered_srcs]
    make_var(args.order_var, ordered_bos)

    for src in ordered_srcs:
        deps = all_deps[src]
        src_bo = to_bo(src)
        dep_bos = [to_bo(d) for d in sorted(deps, key=dep_order_key)]
        if dep_bos:
            print(f"{src_bo}: {' '.join(dep_bos)}")
        # Each .bo also depends on its .bsv
        print(f"{src_bo}: {src}")

if __name__ == "__main__":
    main()
