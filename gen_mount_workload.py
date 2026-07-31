#!/usr/bin/env python3
"""
gen_mount_workload.py — Generate a pod workload that mounts a mix of unique
and common secrets/configmaps so that kubelet creates native watch
connections to the kube-apiserver, with payload sizes representative of
real-world large secrets/configmaps.

Per namespace:
  - One COMMON secret, shared by every pod, holding N_COMMON_SECRET_FILES
    keys of random data at COMMON_SECRET_FILE_SIZE bytes each (default:
    7 files x 10KiB = ~70KiB secret — sized to match a customer-reported
    73,744-byte secret).
  - N_COMMON_CMS COMMON configmaps, each shared by every pod, holding one
    key of random data at COMMON_CM_FILE_SIZE bytes (default: 256KiB —
    matching a customer report of configmaps in excess of 256KB).
  - N_UNIQUE_SECRETS UNIQUE secrets per pod (default: 2), each holding
    N_UNIQUE_KV short key/value pairs (default: 10).
  - N_UNIQUE_CMS UNIQUE configmaps per pod (default: 2), each holding
    N_UNIQUE_KV short key/value pairs (default: 10).
  - N_UNIQUE_LARGE_SECRETS UNIQUE large secrets per pod (default: 0), each a
    single file of UNIQUE_LARGE_SECRET_SIZE bytes (default: 128KiB).
  - N_UNIQUE_LARGE_CMS UNIQUE large configmaps per pod (default: 0), each a
    single file of UNIQUE_LARGE_CM_SIZE bytes (default: 128KiB).
  - N_UNIQUE_LARGE_CMS2 a second, independently-sized group of UNIQUE large
    configmaps per pod (default: 0), each a single file of
    UNIQUE_LARGE_CM2_SIZE bytes. Lets you mix two different large-configmap
    sizes on the same pod (e.g. one 32KiB and one 8KiB) instead of forcing
    every large configmap on a pod to be the same size.

Unlike the common secret/configmaps, unique-large objects don't benefit from
per-node dedup — every pod's large secret/configmap is distinct, so a node
hosting P pods pays P separate large-payload watches instead of one shared
watch. This stresses per-pod watch payload size instead of per-namespace.

Because the common secret/configmaps are shared, each kubelet only needs a
single watch per common object regardless of how many pods on that node
reference it — but the object's full body (all N_COMMON_SECRET_FILES /
COMMON_CM_FILE_SIZE bytes) is what gets re-fetched on every watch reconnect,
once per node. The unique per-pod secret is small, but multiplies by pod
count, giving a mix of "few large objects" and "many small objects" watch
pressure like a real cluster.

Usage:
  # Generate manifests (secrets + cms + pods) for one namespace
  python3 gen_mount_workload.py --pods 240 --namespace mount-spam-0 > workload.yaml
  kubectl apply -f workload.yaml

  # Delete everything
  python3 gen_mount_workload.py --pods 240 --namespace mount-spam-0 --delete | kubectl delete -f -
"""

import argparse
import random
import string
import sys
import yaml  # requires pyyaml; fall back to manual if unavailable

RANDOM_CHARS = string.ascii_letters + string.digits


def random_string(n):
    return "".join(random.choices(RANDOM_CHARS, k=n))


def random_label_token(prefix, n):
    """A random string of exactly n chars, alnum-only so it's always a valid
    Kubernetes label/annotation key or value (first/last char alnum)."""
    suffix_len = max(0, n - len(prefix))
    return (prefix + random_string(suffix_len))[:n]


def gen_pod_labels(n, token_len):
    return {random_label_token(f"podlbl{i}-", token_len):
            random_label_token("v", token_len) for i in range(n)}


def gen_pod_annotations(n, token_len):
    return {random_label_token(f"podannotation{i}-", token_len):
            random_label_token("v", token_len) for i in range(n)}


def gen_pod_env(n, size):
    return [{"name": f"BIG_ENV_VAR_{i}", "value": random_string(size)} for i in range(n)]


def gen_secret_unique(name, namespace, n_kv, kv_value_len=24):
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app": "mount-spam", "mount-spam/kind": "unique-secret"}},
        "type": "Opaque",
        "stringData": {f"key{i}": random_string(kv_value_len) for i in range(n_kv)},
    }


def gen_configmap_unique(name, namespace, n_kv, kv_value_len=24):
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app": "mount-spam", "mount-spam/kind": "unique-configmap"}},
        "data": {f"key{i}": random_string(kv_value_len) for i in range(n_kv)},
    }


def gen_secret_unique_large(name, namespace, file_size):
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app": "mount-spam", "mount-spam/kind": "unique-large-secret"}},
        "type": "Opaque",
        "stringData": {"file.bin": random_string(file_size)},
    }


def gen_configmap_unique_large(name, namespace, file_size, kind="unique-large-configmap"):
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app": "mount-spam", "mount-spam/kind": kind}},
        "data": {"file.bin": random_string(file_size)},
    }


def gen_secret_common(name, namespace, n_files, file_size):
    return {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app": "mount-spam", "mount-spam/kind": "common-secret"}},
        "type": "Opaque",
        "stringData": {f"file{i}.bin": random_string(file_size) for i in range(n_files)},
    }


def gen_configmap_common(name, namespace, file_size):
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app": "mount-spam", "mount-spam/kind": "common-configmap"}},
        "data": {"file.bin": random_string(file_size)},
    }


def gen_pod(pod_index, unique_secret_names, unique_cm_names,
            unique_large_secret_names, unique_large_cm_names, unique_large_cm2_names,
            common_secret_name, common_cm_names,
            prefix, namespace, image, cpu_req, mem_req,
            n_labels, n_annotations, label_token_len, n_env_vars, env_var_size):
    volume_mounts = []
    volumes = []

    for j, sname in enumerate(unique_secret_names):
        vname = f"unique-secret-{j}"
        volume_mounts.append({"name": vname, "mountPath": f"/run/secrets/unique-{j}",
                               "readOnly": True})
        volumes.append({"name": vname, "secret": {"secretName": sname}})

    for j, cname in enumerate(unique_cm_names):
        vname = f"unique-cm-{j}"
        volume_mounts.append({"name": vname, "mountPath": f"/run/cm/unique-{j}",
                               "readOnly": True})
        volumes.append({"name": vname, "configMap": {"name": cname}})

    for j, sname in enumerate(unique_large_secret_names):
        vname = f"unique-large-secret-{j}"
        volume_mounts.append({"name": vname, "mountPath": f"/run/secrets/unique-large-{j}",
                               "readOnly": True})
        volumes.append({"name": vname, "secret": {"secretName": sname}})

    for j, cname in enumerate(unique_large_cm_names):
        vname = f"unique-large-cm-{j}"
        volume_mounts.append({"name": vname, "mountPath": f"/run/cm/unique-large-{j}",
                               "readOnly": True})
        volumes.append({"name": vname, "configMap": {"name": cname}})

    for j, cname in enumerate(unique_large_cm2_names):
        vname = f"unique-large-cm2-{j}"
        volume_mounts.append({"name": vname, "mountPath": f"/run/cm/unique-large2-{j}",
                               "readOnly": True})
        volumes.append({"name": vname, "configMap": {"name": cname}})

    volume_mounts.append({"name": "common-secret", "mountPath": "/run/secrets/common",
                           "readOnly": True})
    volumes.append({"name": "common-secret", "secret": {"secretName": common_secret_name}})

    for j, cname in enumerate(common_cm_names):
        vname = f"common-cm-{j}"
        volume_mounts.append({"name": vname, "mountPath": f"/run/cm/common-{j}",
                               "readOnly": True})
        volumes.append({"name": vname, "configMap": {"name": cname}})

    labels = {"app": "mount-spam"}
    labels.update(gen_pod_labels(n_labels, label_token_len))

    return {
        "apiVersion": "v1",
        "kind": "Pod",
        "metadata": {
            "name": f"{prefix}-pod-{pod_index}",
            "namespace": namespace,
            "labels": labels,
            "annotations": gen_pod_annotations(n_annotations, label_token_len),
        },
        "spec": {
            "restartPolicy": "Always",
            "terminationGracePeriodSeconds": 0,
            "containers": [{
                "name": "sleep",
                "image": image,
                "imagePullPolicy": "IfNotPresent",
                "command": ["sleep", "infinity"],
                "env": gen_pod_env(n_env_vars, env_var_size),
                "resources": {
                    "requests": {"cpu": cpu_req, "memory": mem_req},
                    "limits":   {"memory": mem_req},
                },
                "volumeMounts": volume_mounts,
                "securityContext": {"allowPrivilegeEscalation": False,
                                    "runAsNonRoot": True,
                                    "runAsUser": 1000},
            }],
            "volumes": volumes,
            "securityContext": {"runAsNonRoot": True},
            # OVN-Kubernetes's per-node pod subnet (~509-519 usable IPs on a
            # default /23) is smaller than a typical maxPods=750. The default
            # scheduler doesn't know that, so without an explicit spread
            # constraint it can stack pods past a node's real IP capacity
            # while other nodes sit idle. Steer toward even distribution by
            # pod count instead. ScheduleAnyway (not DoNotSchedule): with
            # nodeTaintsPolicy defaulting to Ignore, tainted control-plane
            # nodes count as permanently-empty domains, which makes a hard
            # DoNotSchedule constraint unsatisfiable as soon as any worker
            # exceeds maxSkew relative to them.
            "topologySpreadConstraints": [{
                "maxSkew": 10,
                "topologyKey": "kubernetes.io/hostname",
                "whenUnsatisfiable": "ScheduleAnyway",
                "labelSelector": {"matchLabels": {"app": "mount-spam"}},
            }],
        },
    }


def emit(obj):
    """Write a YAML document to stdout."""
    print("---")
    # Simple manual YAML for speed (avoids pyyaml dependency for huge outputs)
    try:
        print(yaml.dump(obj, default_flow_style=False).rstrip())
    except NameError:
        import json
        # Fallback: emit as JSON (kubectl accepts it)
        print(json.dumps(obj))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pods", type=int, default=240,
                        help="Number of pods in this namespace (default 240)")
    parser.add_argument("--unique-secrets", type=int, default=2,
                        help="Unique secrets per pod (default 2)")
    parser.add_argument("--unique-cms", type=int, default=2,
                        help="Unique configmaps per pod (default 2)")
    parser.add_argument("--unique-kv", type=int, default=10,
                        help="Short key/value pairs in each unique secret/configmap (default 10)")
    parser.add_argument("--unique-kv-len", type=int, default=24,
                        help="Length in chars of each unique secret/configmap value (default 24)")
    parser.add_argument("--unique-large-secrets", type=int, default=0,
                        help="Unique large (single-file) secrets per pod (default 0)")
    parser.add_argument("--unique-large-secret-size", type=int, default=128 * 1024,
                        help="Size in bytes of each unique large secret's file (default 131072 = 128KiB)")
    parser.add_argument("--unique-large-cms", type=int, default=0,
                        help="Unique large (single-file) configmaps per pod (default 0)")
    parser.add_argument("--unique-large-cm-size", type=int, default=128 * 1024,
                        help="Size in bytes of each unique large configmap's file (default 131072 = 128KiB)")
    parser.add_argument("--unique-large-cms2", type=int, default=0,
                        help="A second, independently-sized group of unique large configmaps per pod (default 0)")
    parser.add_argument("--unique-large-cm2-size", type=int, default=8 * 1024,
                        help="Size in bytes of each second-group unique large configmap's file (default 8192 = 8KiB)")
    parser.add_argument("--common-secret-files", type=int, default=7,
                        help="Number of files in the shared common secret (default 7)")
    parser.add_argument("--common-secret-file-size", type=int, default=10 * 1024,
                        help="Size in bytes of each common secret file (default 10240 = 10KiB)")
    parser.add_argument("--common-cms", type=int, default=2,
                        help="Number of shared common configmaps (default 2)")
    parser.add_argument("--common-cm-file-size", type=int, default=256 * 1024,
                        help="Size in bytes of each common configmap's file (default 262144 = 256KiB)")
    parser.add_argument("--prefix",    default="mount-spam",
                        help="Name prefix (default mount-spam)")
    parser.add_argument("--namespace", default="default",
                        help="Namespace (default default)")
    parser.add_argument("--image",
                        default="registry.access.redhat.com/ubi9/ubi-minimal:latest",
                        help="Container image for the sleep pod")
    parser.add_argument("--cpu",    default="1m",  help="CPU request per pod")
    parser.add_argument("--memory", default="8Mi", help="Memory request/limit per pod")
    parser.add_argument("--pod-labels", type=int, default=10,
                        help="Extra random labels per pod, beyond app=mount-spam (default 10)")
    parser.add_argument("--pod-annotations", type=int, default=10,
                        help="Random annotations per pod (default 10)")
    parser.add_argument("--label-token-len", type=int, default=31,
                        help="Length in chars of each label/annotation key and value "
                             "(default 31 = ~50%% of the 63-char Kubernetes label limit)")
    parser.add_argument("--env-vars", type=int, default=6,
                        help="Large environment variables per pod container (default 6)")
    parser.add_argument("--env-var-size", type=int, default=900,
                        help="Size in bytes of each large environment variable's value "
                             "(default 900)")
    parser.add_argument("--delete",  action="store_true",
                        help="Output delete manifests instead of create")
    parser.add_argument("--pods-only", action="store_true",
                        help="Only emit Pod objects (skip secrets/cms)")
    parser.add_argument("--resources-only", action="store_true",
                        help="Only emit Secret/ConfigMap objects (skip pods)")
    args = parser.parse_args()

    common_secret_name = f"{args.prefix}-secret-common"
    common_cm_names = [f"{args.prefix}-cm-common-{j}" for j in range(args.common_cms)]

    common_secret_bytes = args.common_secret_files * args.common_secret_file_size
    common_cm_bytes = args.common_cms * args.common_cm_file_size

    print(f"# Workload summary (namespace={args.namespace}):", file=sys.stderr)
    print(f"#   Pods:                    {args.pods}", file=sys.stderr)
    print(f"#   Unique secrets/pod:      {args.unique_secrets} ({args.unique_kv} short key/value pairs each)",
          file=sys.stderr)
    print(f"#   Unique configmaps/pod:   {args.unique_cms} ({args.unique_kv} short key/value pairs each)",
          file=sys.stderr)
    print(f"#   Unique large secrets/pod:   {args.unique_large_secrets} "
          f"({args.unique_large_secret_size}B each)", file=sys.stderr)
    print(f"#   Unique large configmaps/pod: {args.unique_large_cms} "
          f"({args.unique_large_cm_size}B each)", file=sys.stderr)
    print(f"#   Unique large configmaps/pod (group 2): {args.unique_large_cms2} "
          f"({args.unique_large_cm2_size}B each)", file=sys.stderr)
    print(f"#   Common secret:           1 ({args.common_secret_files} files x "
          f"{args.common_secret_file_size}B = {common_secret_bytes}B)", file=sys.stderr)
    print(f"#   Common configmaps:       {args.common_cms} (1 file x "
          f"{args.common_cm_file_size}B each = {common_cm_bytes}B total)", file=sys.stderr)
    print(f"#   Distinct watched objects (per node hosting these pods): "
          f"up to {args.pods}x({args.unique_secrets} unique secrets + {args.unique_cms} unique cms "
          f"+ {args.unique_large_secrets} unique large secrets + {args.unique_large_cms} unique large cms "
          f"+ {args.unique_large_cms2} unique large cms group 2) "
          f"+ 1 common secret + {args.common_cms} common cms",
          file=sys.stderr)
    print(f"#   Pod metadata:            {args.pod_labels} labels + {args.pod_annotations} "
          f"annotations ({args.label_token_len}-char keys/values) + {args.env_vars} env vars "
          f"({args.env_var_size}B each)", file=sys.stderr)

    if args.delete:
        # Emit bare metadata objects for deletion
        print(f"---")
        print(f"apiVersion: v1\nkind: Secret\nmetadata:\n  name: {common_secret_name}\n  namespace: {args.namespace}")
        for name in common_cm_names:
            print(f"---")
            print(f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
        for i in range(args.pods):
            for j in range(args.unique_secrets):
                name = f"{args.prefix}-secret-unique-{i}-{j}"
                print(f"---")
                print(f"apiVersion: v1\nkind: Secret\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
            for j in range(args.unique_cms):
                name = f"{args.prefix}-cm-unique-{i}-{j}"
                print(f"---")
                print(f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
            for j in range(args.unique_large_secrets):
                name = f"{args.prefix}-secret-unique-large-{i}-{j}"
                print(f"---")
                print(f"apiVersion: v1\nkind: Secret\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
            for j in range(args.unique_large_cms):
                name = f"{args.prefix}-cm-unique-large-{i}-{j}"
                print(f"---")
                print(f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
            for j in range(args.unique_large_cms2):
                name = f"{args.prefix}-cm-unique-large2-{i}-{j}"
                print(f"---")
                print(f"apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
        for i in range(args.pods):
            name = f"{args.prefix}-pod-{i}"
            print(f"---")
            print(f"apiVersion: v1\nkind: Pod\nmetadata:\n  name: {name}\n  namespace: {args.namespace}")
        return

    if not args.pods_only:
        emit(gen_secret_common(common_secret_name, args.namespace,
                                args.common_secret_files, args.common_secret_file_size))
        for name in common_cm_names:
            emit(gen_configmap_common(name, args.namespace, args.common_cm_file_size))
        for i in range(args.pods):
            for j in range(args.unique_secrets):
                emit(gen_secret_unique(f"{args.prefix}-secret-unique-{i}-{j}", args.namespace,
                                        args.unique_kv, args.unique_kv_len))
            for j in range(args.unique_cms):
                emit(gen_configmap_unique(f"{args.prefix}-cm-unique-{i}-{j}", args.namespace,
                                           args.unique_kv, args.unique_kv_len))
            for j in range(args.unique_large_secrets):
                emit(gen_secret_unique_large(f"{args.prefix}-secret-unique-large-{i}-{j}", args.namespace,
                                              args.unique_large_secret_size))
            for j in range(args.unique_large_cms):
                emit(gen_configmap_unique_large(f"{args.prefix}-cm-unique-large-{i}-{j}", args.namespace,
                                                 args.unique_large_cm_size))
            for j in range(args.unique_large_cms2):
                emit(gen_configmap_unique_large(f"{args.prefix}-cm-unique-large2-{i}-{j}", args.namespace,
                                                 args.unique_large_cm2_size, kind="unique-large-configmap-2"))

    if not args.resources_only:
        for i in range(args.pods):
            unique_secret_names = [f"{args.prefix}-secret-unique-{i}-{j}" for j in range(args.unique_secrets)]
            unique_cm_names = [f"{args.prefix}-cm-unique-{i}-{j}" for j in range(args.unique_cms)]
            unique_large_secret_names = [f"{args.prefix}-secret-unique-large-{i}-{j}"
                                          for j in range(args.unique_large_secrets)]
            unique_large_cm_names = [f"{args.prefix}-cm-unique-large-{i}-{j}"
                                      for j in range(args.unique_large_cms)]
            unique_large_cm2_names = [f"{args.prefix}-cm-unique-large2-{i}-{j}"
                                       for j in range(args.unique_large_cms2)]
            emit(gen_pod(i, unique_secret_names, unique_cm_names,
                         unique_large_secret_names, unique_large_cm_names, unique_large_cm2_names,
                         common_secret_name, common_cm_names, args.prefix, args.namespace, args.image,
                         args.cpu, args.memory,
                         args.pod_labels, args.pod_annotations, args.label_token_len,
                         args.env_vars, args.env_var_size))


if __name__ == "__main__":
    main()
