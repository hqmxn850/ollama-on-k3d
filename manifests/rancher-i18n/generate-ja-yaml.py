#!/usr/bin/env python3
import re
import yaml

class CustomLoader(yaml.SafeLoader):
    pass
CustomLoader.add_constructor('tag:yaml.org,2002:value', lambda loader, node: loader.construct_scalar(node))

print("Loading en-us.yaml...")
with open('/home/masashi/.gemini/antigravity-cli/brain/814f7c7d-5ff1-40b3-9d38-3efe37bf5dd3/scratch/en-us.yaml', 'r', encoding='utf-8') as f:
    en_data = yaml.load(f, Loader=CustomLoader)

print("Loading legacy ja-jp.yaml...")
with open('/home/masashi/.gemini/antigravity-cli/brain/814f7c7d-5ff1-40b3-9d38-3efe37bf5dd3/scratch/ja-jp-legacy.yaml', 'r', encoding='utf-8') as f:
    legacy_ja = yaml.load(f, Loader=CustomLoader)

# 簡易的な値から日本語へのマッピング辞書を作成 (legacy から抽出)
def extract_translations(d_en, d_ja, mapping):
    if isinstance(d_en, dict) and isinstance(d_ja, dict):
        for k in d_en:
            if k in d_ja:
                extract_translations(d_en[k], d_ja[k], mapping)
    elif isinstance(d_en, str) and isinstance(d_ja, str):
        en_str = d_en.strip()
        ja_str = d_ja.strip()
        if en_str and ja_str and en_str != ja_str:
            mapping[en_str] = ja_str

phrase_map = {}
# legacy 同士の英語->日本語マッピングをロードできれば理想的だが、legacy はキーと日本語値
# legacy_ja の key: value から共通パターンを収集
for k, v in legacy_ja.items():
    if isinstance(v, str):
        # キー末尾などを参考にすることもできるが、頻出単語マップを定義
        pass

# 定番の単語・フレーズ辞書 (Rancher & K8s に最適化)
COMMON_DICT = {
    "Add": "追加",
    "All": "すべて",
    "Cancel": "キャンセル",
    "Close": "閉じる",
    "Confirm": "確認",
    "Clear": "クリア",
    "Clear All": "すべてクリア",
    "Create": "作成",
    "Delete": "削除",
    "Edit": "編集",
    "Save": "保存",
    "Back": "戻る",
    "Next": "次へ",
    "Finish": "完了",
    "Clone": "複製",
    "Download": "ダウンロード",
    "Upload": "アップロード",
    "Import": "インポート",
    "Export": "エクスポート",
    "Refresh": "更新",
    "Search": "検索",
    "Filter": "フィルター",
    "Filter namespaces": "Namespace をフィルター",
    "filter namespaces": "Namespace をフィルター",
    "Status": "ステータス",
    "State": "状態",
    "Name": "名前",
    "Description": "説明",
    "Age": "経過時間",
    "Created": "作成日時",
    "Updated": "更新日時",
    "Actions": "操作",
    "Action": "操作",
    "Active": "アクティブ",
    "Error": "エラー",
    "Warning": "警告",
    "Info": "情報",
    "Success": "成功",
    "Failed": "失敗",
    "Pending": "保留中",
    "Running": "実行中",
    "Completed": "完了",
    "Unavailable": "利用不可",
    "Unknown": "不明",
    "Disabled": "無効",
    "Enabled": "有効",
    "Enable": "有効化",
    "Disable": "無効化",
    "Yes": "はい",
    "No": "いいえ",
    "None": "なし",
    "(None)": "（なし）",
    "Default": "デフォルト",
    "Custom": "カスタム",
    "Key": "キー",
    "Value": "値",
    "Type": "タイプ",
    "Version": "バージョン",
    "Details": "詳細",
    "Overview": "概要",
    "Dashboard": "ダッシュボード",
    "Cluster Dashboard": "クラスタダッシュボード",
    "Cluster Management": "クラスタ管理",
    "Cluster Manager": "クラスタマネージャー",
    "Cluster Explorer": "クラスタエクスプローラー",
    "Continuous Delivery": "継続的デリバリー",
    "Users & Authentication": "ユーザーと認証",
    "Global Settings": "グローバル設定",
    "Marketplace": "マーケットプレイス",
    "Apps": "アプリケーション",
    "Tools": "ツール",
    "Cluster Tools": "クラスタツール",
    "Nodes": "ノード",
    "Node": "ノード",
    "Pods": "Pod",
    "Pod": "Pod",
    "Workloads": "ワークロード",
    "Deployments": "Deployment",
    "StatefulSets": "StatefulSet",
    "DaemonSets": "DaemonSet",
    "Jobs": "Job",
    "CronJobs": "CronJob",
    "Services": "Service",
    "Ingresses": "Ingress",
    "Ingress": "Ingress",
    "Service": "Service",
    "Storage": "ストレージ",
    "PersistentVolumes": "PersistentVolume",
    "PersistentVolumeClaims": "PersistentVolumeClaim",
    "StorageClasses": "StorageClass",
    "ConfigMaps": "ConfigMap",
    "Secrets": "Secret",
    "ServiceAccounts": "ServiceAccount",
    "Namespaces": "Namespace",
    "Namespace": "Namespace",
    "Certificates": "証明書",
    "Roles": "Role",
    "RoleBindings": "RoleBinding",
    "ClusterRoles": "ClusterRole",
    "ClusterRoleBindings": "ClusterRoleBinding",
    "Events": "イベント",
    "Alerts": "アラート",
    "Monitoring": "モニタリング",
    "Logging": "ロギング",
    "Backups": "バックアップ",
    "Snapshots": "スナップショット",
    "Settings": "設定",
    "Preferences": "環境設定",
    "Profile": "プロフィール",
    "Log Out": "ログアウト",
    "Log In": "ログイン",
    "Username": "ユーザー名",
    "Password": "パスワード",
    "Memory": "メモリ",
    "CPU": "CPU",
    "Capacity": "容量",
    "Used": "使用中",
    "Allocated": "割り当て済み",
    "Reserved": "予約済み",
    "Total Resources": "総リソース",
    "User avatar": "ユーザーアバター",
    "Locale selector menu": "言語選択メニュー",
    "English": "English",
    "简体中文": "简体中文",
    "Japanese": "日本語",
}

def translate_node(key_path, val):
    if isinstance(val, dict):
        new_d = {}
        for k, v in val.items():
            new_d[k] = translate_node(key_path + "." + str(k), v)
        return new_d
    elif isinstance(val, list):
        return [translate_node(key_path, x) for x in val]
    elif isinstance(val, str):
        # 特別なキーの処理
        if key_path == ".locale":
            return val
        s = val.strip()
        if s in COMMON_DICT:
            return COMMON_DICT[s]
        return val
    return val

print("Translating...")
ja_data = translate_node("", en_data)

# locale セクションをカスタマイズ
if 'locale' in ja_data:
    ja_data['locale']['ja'] = '日本語'
    ja_data['locale']['ja-jp'] = '日本語'

# nav や generic などの重要セクションをより詳細に翻訳
if 'nav' in ja_data:
    ja_data['nav']['tools'] = 'ツール'
    ja_data['nav']['clusterTools'] = 'クラスタツール'
    ja_data['nav']['backToRancher'] = 'クラスタマネージャー'
    ja_data['nav']['harvesterDashboard'] = 'Harvester ダッシュボード'
    if 'skipToContent' in ja_data['nav']:
        ja_data['nav']['skipToContent'] = 'メインコンテンツへスキップ'

if 'product' in ja_data:
    ja_data['product']['apps'] = 'アプリケーション'
    ja_data['product']['auth'] = 'ユーザーと認証'
    ja_data['product']['backup'] = 'Rancher バックアップ'
    ja_data['product']['compliance'] = 'コンプライアンス'
    ja_data['product']['ecm'] = 'クラスタマネージャー'
    ja_data['product']['explorer'] = 'クラスタエクスプローラー'
    ja_data['product']['fleet'] = '継続的デリバリー (Fleet)'
    ja_data['product']['manager'] = 'クラスタ管理'

if 'clusterIndexPage' in ja_data:
    cip = ja_data['clusterIndexPage']
    cip['header'] = 'クラスタダッシュボード'
    if 'hardwareResourceGauge' in cip:
        hrg = cip['hardwareResourceGauge']
        hrg['cores'] = 'CPU'
        hrg['pods'] = 'Pod'
        hrg['ram'] = 'メモリ'
        hrg['used'] = '使用中'
        hrg['reserved'] = '予約済み'
        hrg['allocated'] = '割り当て済み'
    if 'sections' in cip:
        sec = cip['sections']
        if 'capacity' in sec: sec['capacity']['label'] = '容量'
        if 'events' in sec: sec['events']['label'] = 'イベント'
        if 'alerts' in sec: sec['alerts']['label'] = 'アラート'
        if 'clusterMetrics' in sec: sec['clusterMetrics']['label'] = 'クラスタメトリクス'
        if 'etcdMetrics' in sec: sec['etcdMetrics']['label'] = 'Etcd メトリクス'
        if 'k8sMetrics' in sec: sec['k8sMetrics']['label'] = 'Kubernetes コンポーネントメトリクス'
        if 'nodes' in sec: sec['nodes']['label'] = '異常ノード'
        if 'certs' in sec: sec['certs']['label'] = '証明書'

# 出力
out_path = '/home/masashi/.gemini/antigravity-cli/brain/814f7c7d-5ff1-40b3-9d38-3efe37bf5dd3/scratch/ja.yaml'
with open(out_path, 'w', encoding='utf-8') as f:
    yaml.dump(ja_data, f, allow_unicode=True, sort_keys=False)

print(f"Generated {out_path} successfully!")
