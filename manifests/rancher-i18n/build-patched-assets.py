#!/usr/bin/env python3
import json
import os
import sys
import yaml

class CustomLoader(yaml.SafeLoader):
    pass
CustomLoader.add_constructor('tag:yaml.org,2002:value', lambda loader, node: loader.construct_scalar(node))

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
JA_YAML_PATH = os.path.join(SCRIPT_DIR, "ja.yaml")
INDEX_ORIG_PATH = sys.argv[1] if len(sys.argv) > 1 else os.path.join(SCRIPT_DIR, "dist/index.orig.js")
OUT_DIR = os.path.join(SCRIPT_DIR, "dist")
os.makedirs(OUT_DIR, exist_ok=True)

# 1. 日本語辞書 JSON を Webpack チャンク JS に変換
print("1. Loading ja.yaml and generating Webpack chunk...")
with open(JA_YAML_PATH, "r", encoding="utf-8") as f:
    ja_data = yaml.load(f, Loader=CustomLoader)

ja_json = json.dumps(ja_data, ensure_ascii=False, separators=(',', ':'))
chunk_js = f'(self["webpackChunkdashboard"]=self["webpackChunkdashboard"]||[]).push([[9018],{{63398(e){{const a=[{ja_json}];e.exports=a.length<=1?a[0]:a}}}}]);\n'

chunk_file = os.path.join(OUT_DIR, "zh-hans-yaml.ja2026.js")
with open(chunk_file, "w", encoding="utf-8") as f:
    f.write(chunk_js)
print(f"Generated {chunk_file} ({len(chunk_js)} bytes)")

# 2. index.js をパッチ
print(f"2. Patching {INDEX_ORIG_PATH}...")
with open(INDEX_ORIG_PATH, "r", encoding="utf-8") as f:
    c = f.read()

# チャンクハッシュ置換: 9018:"6ede47cb" -> 9018:"ja2026"
if '9018:"6ede47cb"' in c:
    c = c.replace('9018:"6ede47cb"', '9018:"ja2026"')

# 言語ラベル置換: "zh-hans":"简体中文" -> "zh-hans":"日本語", "en-us":"English" -> "en-us":"日本語"
if '"zh-hans":"简体中文"' in c:
    c = c.replace('"zh-hans":"简体中文"', '"zh-hans":"日本語"')
if '"en-us":"English"' in c:
    c = c.replace('"en-us":"English"', '"en-us":"日本語"')

# デフォルト言語置換: t={default:p, -> t={default:"zh-hans",
if 't={default:p,' in c:
    c = c.replace('t={default:p,', 't={default:"zh-hans",')

# 定数置換: const u="none",p="en-us" -> const u="none",p="zh-hans" (デフォルト・フォールバック言語を日本語に固定)
if 'const u="none",p="en-us"' in c:
    c = c.replace('const u="none",p="en-us"', 'const u="none",p="zh-hans"')

# init ロジック置換: ユーザー設定に関わらず日本語に完全固定
old_init = 'let o=s["prefs/get"]("locale");'
new_init = 'let o="zh-hans";'
if old_init in c:
    c = c.replace(old_init, new_init)

# switchTo ロジック置換: 外部からの切り替え要求が来ても常に日本語に固定
old_switch = 'async switchTo({state:e,rootState:t,commit:a,dispatch:s,getters:o},r){'
new_switch = 'async switchTo({state:e,rootState:t,commit:a,dispatch:s,getters:o},r){r="zh-hans";'
if old_switch in c:
    c = c.replace(old_switch, new_switch)

# setSelected ロジック置換: 言語設定・lang属性を ja/zh-hans に固定
old_set_sel = 'setSelected(e,t){t===u?document.querySelector("html").removeAttribute("lang"):document.querySelector("html").setAttribute("lang",t),e.selected=t}'
new_set_sel = 'setSelected(e,t){t="zh-hans";document.querySelector("html").setAttribute("lang","ja"),e.selected=t}'
if old_set_sel in c:
    c = c.replace(old_set_sel, new_set_sel)

index_file = os.path.join(OUT_DIR, "index.ja2026.js")
with open(index_file, "w", encoding="utf-8") as f:
    f.write(c)
print(f"Generated {index_file} ({len(c)} bytes)")

print("Done building patched assets!")

