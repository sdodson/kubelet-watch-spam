#!/usr/bin/env python3
"""batch_pods.py — split a multi-document pod YAML manifest into fixed-size
batch files.

setup_workload.sh uses this to apply pods in waves instead of all at once.
Creating all pods for a namespace simultaneously causes every node to try
starting hundreds of containers at the same moment, which can overwhelm
crio/runc (sync-socket errors from CPU contention during concurrent
container creation) badly enough that it never drains on its own.

Usage:
  python3 batch_pods.py <input.yaml> <batch_size> <output_dir> <namespace_index>

Writes <output_dir>/ns<namespace_index>_pods_batch<N>.yaml for N = 0, 1, ...
"""
import sys
import yaml


def main():
    manifest, batch_size, outdir, ns_idx = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    docs = [d for d in yaml.safe_load_all(open(manifest)) if d]
    for b, start in enumerate(range(0, len(docs), batch_size)):
        chunk = docs[start:start + batch_size]
        with open(f"{outdir}/ns{ns_idx}_pods_batch{b}.yaml", "w") as f:
            for d in chunk:
                f.write("---\n")
                yaml.dump(d, f, default_flow_style=False)


if __name__ == "__main__":
    main()
