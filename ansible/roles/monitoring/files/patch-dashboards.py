#!/usr/bin/env python3
"""
Patch Grafana dashboards (both template files and live ConfigMaps in Kubernetes) so that:
1. "timezone" is set to "Asia/Tokyo"
2. All unresolved datasource variables (${DS_...}, $DS_..., $datasource, etc.) are resolved to {"type": "prometheus", "uid": "prometheus"}
3. "datasource" entries in panels/targets are normalized to the Prometheus datasource
4. Templating datasource variables (type: "datasource") and __inputs are removed
5. Templating variable $cluster is normalized with default value to prevent 'No Data' in single-cluster environments
6. Instance variable query filter (cluster="$cluster") is relaxed to prevent empty instance dropdowns
7. K8s / etcd / ingress / kubelet queries with missing/unmatched labels are patched with robust fallbacks
"""
import subprocess
import json
import re
import glob
import os
import sys

CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "mycluster")

def patch_expr(expr, panel_title=""):
    if not isinstance(expr, str) or not expr.strip():
        return expr, False

    orig = expr

    # 1. etcd: job="kube-etcd" -> job=~"kube-etcd|k8s-controlplane-metrics-proxy"
    if 'job="kube-etcd"' in expr:
        expr = expr.replace('job="kube-etcd"', 'job=~"kube-etcd|k8s-controlplane-metrics-proxy"')

    # 2. k8s components: component="k3s-server" フィルタの削除 (K3s workqueue_depth 等に component ラベルが存在しないため)
    if 'component="k3s-server"' in expr:
        expr = re.sub(r'component="k3s-server",\s*', '', expr)
        expr = re.sub(r',\s*component="k3s-server"', '', expr)
        expr = expr.replace('component="k3s-server"', '')

    # 3. Ingress Controller Connections: NGINX Ingress メトリクスから Traefik 接続メトリクスへのフォールバック
    if 'nginx_ingress_controller_nginx_process_connections' in expr:
        if 'state="reading"' in expr:
            expr = f"({expr}) or sum(traefik_open_connections{{protocol=\"TCP\"}}) or sum(traefik_open_connections)"
        elif 'state="waiting"' in expr:
            expr = f"({expr}) or (0 * sum(traefik_open_connections))"
        elif 'state="writing"' in expr:
            expr = f"({expr}) or sum(traefik_open_connections{{entrypoint=\"websecure\"}})"
        elif 'state="accepted"' in expr or 'state="handled"' in expr:
            expr = f"({expr}) or sum(ceil(increase(traefik_entrypoint_requests_total[$__rate_interval])))"

    # 4. Storage Operation Error Rate: エラー 0 件時に No Data になるのを防ぎ 0 を表示
    if 'storage_operation_errors_total' in expr and 'storage_operation_duration' not in expr:
        expr = f"({expr}) or (0 * sum(rate(storage_operation_duration_seconds_bucket{{job=\"kubelet\"}}[$__rate_interval])) by (instance))"

    # 5. Multi-Cluster joinByField: "cluster" の補正
    # sum(...) by (cluster) で cluster ラベルが存在しない場合に label_replace で cluster を補完
    if 'by (cluster)' in expr and 'label_replace' not in expr:
        expr = f"({expr}) or label_replace(({expr}), \"cluster\", \"{CLUSTER_NAME}\", \"\", \"\")"

    # 6. KubeVirt VMI メトリクス: VM 0台 (非稼働時) に No Data になるのを防ぎ vector(0) を補完
    if ('kubevirt_vmi_cpu_usage_seconds_total' in expr or \
        'kubevirt_vmi_memory_used_bytes' in expr or \
        'kubevirt_vmi_storage_read_traffic_bytes_total' in expr or \
        'kubevirt_vmi_storage_write_traffic_bytes_total' in expr or \
        'kubevirt_vmi_network_receive_bytes_total' in expr or \
        'kubevirt_vmi_network_transmit_bytes_total' in expr) and 'vector(0)' not in expr:
        expr = f"({expr}) or vector(0)"

    # 7. Fluentbit / Fluentd メトリクス: 非稼働時 (ログ未収集時) に No Data になるのを防ぎ vector(0) を補完
    if ('fluentbit_' in expr or 'fluentd_' in expr) and 'vector(0)' not in expr:
        expr = f"({expr}) or vector(0)"

    # 8. Network Saturation (Drops Receive/Transmit): != 0 フィルタによる No Data (通常時ドロップ 0) を防止
    if ('node_network_receive_drop_' in expr or 'node_network_transmit_drop_' in expr):
        if '!= 0' in expr:
            expr = re.sub(r'\s*!=\s*0', '', expr)

    # 9. Rancher Backup & Restore メトリクス: 未実行時 (バックアップ 0 件時) に No Data になるのを防ぎ vector(0) を補完
    if ('rancher_backup_' in expr or 'rancher_backups_' in expr or 'rancher_restore_' in expr) and 'vector(0)' not in expr:
        expr = f"({expr}) or vector(0)"

    # 10. Rancher Performance Debugging メトリクス: steve_api / k8s_proxy / lasso エラー時に No Data になるのを防ぎ vector(0) を補完
    if ('steve_api_' in expr or 'k8s_proxy_' in expr or 'lasso_controller_total_handler_execution' in expr) and 'vector(0)' not in expr:
        expr = f"({expr}) or vector(0)"

    return expr, expr != orig




def normalize_dashboard(d_json):
    changed = False

    # 1. Timezone
    if d_json.get("timezone") != "Asia/Tokyo":
        d_json["timezone"] = "Asia/Tokyo"
        changed = True

    # 2. Clear __inputs
    if d_json.get("__inputs"):
        d_json["__inputs"] = []
        changed = True

    # 3. Filter templating datasource variables & normalize cluster/instance variables
    if "templating" in d_json and "list" in d_json["templating"]:
        new_list = []
        for t in d_json["templating"]["list"]:
            name = str(t.get("name", ""))
            t_type = str(t.get("type", ""))
            if t_type == "datasource" or name.startswith("DS_"):
                changed = True
            else:
                # cluster 変数の正規化 (単一クラスタで空になり全パネルが No Data になるのを防ぐ)
                if name == "cluster":
                    q = str(t.get("query", ""))
                    if "label_values" in q or not t.get("current") or t.get("current") == "None":
                        t["type"] = "custom"
                        t["query"] = ""
                        t["current"] = {"selected": True, "text": "default", "value": ""}
                        t["options"] = [{"selected": True, "text": "default", "value": ""}]
                        changed = True
                # instance 変数の正規化 (cluster="$cluster" の空フィルタによる未取得を防止)
                if name == "instance":
                    q = str(t.get("query", ""))
                    if 'cluster="$cluster"' in q or 'cluster=~' in q:
                        new_q = re.sub(r',?\s*cluster=~?"\$cluster",?', '', q)
                        if new_q != q:
                            t["query"] = new_q
                            changed = True
                new_list.append(t)
        if len(new_list) != len(d_json["templating"]["list"]):
            d_json["templating"]["list"] = new_list
            changed = True

    # 4. Recursively fix datasources
    def fix_val(val):
        nonlocal changed
        if isinstance(val, str):
            if val.startswith("${DS_") or val.startswith("$DS_") or val in ["prometheus", "Prometheus", "$datasource", "${datasource}"] or val.startswith("$datasource"):
                changed = True
                return {"type": "prometheus", "uid": "prometheus"}
        elif isinstance(val, dict):
            uid = str(val.get("uid", ""))
            t = str(val.get("type", ""))
            if uid.startswith("${DS_") or uid.startswith("$DS_") or uid in ["prometheus", "Prometheus", "WAYOn0FGz", "", "$datasource", "${datasource}"] or t in ["prometheus", "Prometheus"]:
                if val.get("type") != "prometheus" or val.get("uid") != "prometheus":
                    val["type"] = "prometheus"
                    val["uid"] = "prometheus"
                    changed = True
        return val

    def traverse_ds(obj):
        nonlocal changed
        if isinstance(obj, dict):
            for k in list(obj.keys()):
                if k == "datasource":
                    obj[k] = fix_val(obj[k])
                else:
                    traverse_ds(obj[k])
        elif isinstance(obj, list):
            for item in obj:
                traverse_ds(item)

    traverse_ds(d_json)

    # 5. String-level fallback for any lingering ${DS_...}, $DS_..., or $datasource
    raw = json.dumps(d_json, indent=2, ensure_ascii=False)
    new_raw = re.sub(r'"datasource":\s*"(\$\{DS_[^"]+\}|\$DS_[^"]+|\$\{datasource\}|\$datasource)"', '"datasource": {"type": "prometheus", "uid": "prometheus"}', raw)
    new_raw = re.sub(r'"datasource":\s*\{\s*"type":\s*"[^"]*",\s*"uid":\s*"(?:\$\{datasource\}|\$datasource)"\s*\}', '"datasource": {"type": "prometheus", "uid": "prometheus"}', new_raw)
    if new_raw != raw:
        changed = True
        d_json = json.loads(new_raw)

    # 6. パネル targets の PromQL 式の自動補正
    def patch_panels(panels):
        nonlocal changed
        for p in panels:
            p_title = str(p.get("title", ""))
            for tg in p.get("targets", []):
                if "expr" in tg:
                    new_expr, expr_changed = patch_expr(tg["expr"], p_title)
                    if expr_changed:
                        tg["expr"] = new_expr
                        changed = True
            if "panels" in p:
                patch_panels(p["panels"])

    patch_panels(d_json.get("panels", []))

    return d_json, changed

def patch_templates():
    template_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "templates")
    files = glob.glob(os.path.join(template_dir, "grafana-dashboard-*.yaml.j2"))
    print(f"--- Patching {len(files)} template files in {template_dir} ---")
    for fp in sorted(files):
        content = open(fp, "r", encoding="utf-8").read()
        match = re.search(r"({% raw %})(.*?)({% endraw %})", content, re.DOTALL)
        if not match:
            continue
        header = content[:match.start(2)]
        json_str = match.group(2).strip()
        footer = content[match.end(2):]
        
        try:
            d_json = json.loads(json_str)
        except Exception as e:
            print(f"  [ERROR] {os.path.basename(fp)} JSON parse error: {e}")
            continue

        cleaned, changed = normalize_dashboard(d_json)
        if changed:
            json_formatted = json.dumps(cleaned, indent=2, ensure_ascii=False)
            indented = "\n".join("    " + line if line.strip() else line for line in json_formatted.splitlines())
            new_content = f"{header}\n{indented}\n    {footer}"
            with open(fp, "w", encoding="utf-8") as f:
                f.write(new_content)
            print(f"  [UPDATED] {os.path.basename(fp)}")
        else:
            print(f"  [NO CHANGE] {os.path.basename(fp)}")

def get_target_directory(ns, name, annotations):
    existing = annotations.get("k8s-sidecar-target-directory")
    if existing:
        return existing
    if "fleet" in name:
        return "Fleet"
    if "fluent" in name or "logging" in name:
        return "Logging"
    if "ingress" in name or "network" in name:
        return "Networking"
    if "storage" in name or "persistentvolume" in name or "volume" in name:
        return "Storage"
    if "postgresql" in name or "postgres" in name:
        return "PostgreSQL"
    if "alertmanager" in name:
        return "Alerting"
    if name.startswith("rancher-default-dashboards-k8s") or name.startswith("kube-prometheus-stack-k8s") or name.startswith("kube-prometheus-stack-nodes") or name.startswith("kube-prometheus-stack-namespace") or name.startswith("kube-prometheus-stack-pod") or name.startswith("kube-prometheus-stack-workload") or name.startswith("kube-prometheus-stack-kubelet"):
        return "Kubernetes"
    if name.startswith("rancher-"):
        return "Rancher"
    if name.startswith("kube-prometheus-stack"):
        return "Monitoring"
    return "General"

def patch_live_configmaps():
    print("--- Patching live ConfigMaps in Kubernetes ---")
    res = subprocess.run(["kubectl", "get", "configmap", "-A", "-l", "grafana_dashboard=1", "-o", "json"], capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Error listing configmaps: {res.stderr}", file=sys.stderr)
        return

    data = json.loads(res.stdout)
    updated_count = 0

    for item in data.get("items", []):
        ns = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        metadata = item.setdefault("metadata", {})
        annotations = metadata.setdefault("annotations", {})
        cm_data = item.get("data", {})
        cm_changed = False
        new_data = {}

        # フォルダ分類アノテーションの自動付与
        target_dir = get_target_directory(ns, name, annotations)
        if annotations.get("k8s-sidecar-target-directory") != target_dir:
            annotations["k8s-sidecar-target-directory"] = target_dir
            cm_changed = True

        for k, v in cm_data.items():
            if k.endswith(".json"):
                try:
                    d_json = json.loads(v)
                    cleaned, changed = normalize_dashboard(d_json)
                    if changed:
                        new_data[k] = json.dumps(cleaned, indent=2, ensure_ascii=False)
                        cm_changed = True
                    else:
                        new_data[k] = v
                except Exception:
                    new_data[k] = v
            else:
                new_data[k] = v

        if cm_changed:
            item["data"] = new_data
            payload = json.dumps(item)
            p_res = subprocess.run(["kubectl", "apply", "-f", "-"], input=payload, text=True, capture_output=True)
            if p_res.returncode == 0:
                print(f"  [UPDATED] {ns}/{name} -> folder: {target_dir}")
                updated_count += 1
            else:
                print(f"  [FAILED] {ns}/{name}: {p_res.stderr.strip()}", file=sys.stderr)

    print(f"Summary: {updated_count} live ConfigMap(s) updated")

if __name__ == "__main__":
    patch_templates()
    patch_live_configmaps()
