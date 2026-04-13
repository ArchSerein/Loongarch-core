#!/usr/bin/env python3
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

def main():
    if len(sys.argv) < 4:
        print("Usage: gen_bsv_deps.py <bdir> <search_paths_colon_sep> <top_bsv_files...>")
        sys.exit(1)

    bdir = sys.argv[1]
    search_paths = sys.argv[2].split(':')
    top_files = sys.argv[3:]

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

    for src, deps in all_deps.items():
        src_bo = to_bo(src)
        dep_bos = [to_bo(d) for d in deps]
        if dep_bos:
            print(f"{src_bo}: {' '.join(dep_bos)}")
        # Each .bo also depends on its .bsv
        print(f"{src_bo}: {src}")

if __name__ == "__main__":
    main()
