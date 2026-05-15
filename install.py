#!/usr/bin/env python3
# AI経営者プラグイン インストールスクリプト（Mac / Linux用）
# 使い方: ターミナルに以下をそのままコピペしてください
#
#   curl -fsSL https://raw.githubusercontent.com/joshicrea/ai-keieisha-installer/master/install.py | python3
#
# 認証方式: 販売者がGitHubで購入者のメアドをコラボレーターに追加済み。
# 購入者は自分のGitHubアカウントでログイン（gh auth login --web）するだけでアクセス可能。
# PAT発行は不要。
import sys, os, json, urllib.request, zipfile, shutil, tempfile, pathlib, datetime, re, subprocess, platform

sys.stdout.reconfigure(encoding="utf-8")

print()
print("AI経営者プラグインをインストールしています...")
print()

def cmd_exists(name):
    return shutil.which(name) is not None

# --- GitHub CLI (gh) の確認・インストール ---
if not cmd_exists("gh"):
    print("GitHub CLI (gh) をインストールしています...")
    system = platform.system()
    if system == "Darwin":
        if not cmd_exists("brew"):
            print("エラー: Homebrew が見つかりません。https://brew.sh からインストールしてください。")
            sys.exit(1)
        subprocess.run(["brew", "install", "gh"], check=False)
    elif system == "Linux":
        # Debian/Ubuntu系想定
        print("Linux環境では gh の手動インストールが必要です。")
        print("https://github.com/cli/cli/blob/trunk/docs/install_linux.md を参照してください。")
        sys.exit(1)
    else:
        print(f"エラー: 未対応のOS: {system}")
        sys.exit(1)
    if not cmd_exists("gh"):
        print("エラー: GitHub CLI のインストールに失敗しました。")
        sys.exit(1)
    print("[OK] GitHub CLI インストール完了")

# --- GitHub 認証確認 ---
auth_status = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
if auth_status.returncode != 0:
    print()
    print("GitHubへのログインが必要です。")
    print("次の手順で進めてください:")
    print("  1. このあと表示される8桁のコードをコピー")
    print("  2. 自動で開くブラウザでコードを貼り付け")
    print("  3. 「Authorize github」をクリック")
    print()
    result = subprocess.run(["gh", "auth", "login", "--web", "--git-protocol", "https", "--hostname", "github.com"])
    if result.returncode != 0:
        print("エラー: GitHub認証に失敗しました。")
        sys.exit(1)

# --- トークンを取得（ghが保持しているもの・PATではない） ---
PAT = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True).stdout.strip()
if not PAT:
    print("エラー: gh auth token の取得に失敗しました。")
    sys.exit(1)

# --- パス設定 ---
HOME_DIR     = pathlib.Path.home()
CLAUDE_DIR   = HOME_DIR / ".claude"
PLUGINS_DIR  = CLAUDE_DIR / "plugins"
PLUGIN_NAME  = "joshicrea-ai-keieisha"
DATA_DIRNAME = "ai-keieisha"
CACHE_DIR    = PLUGINS_DIR / "cache" / "joshicrea" / PLUGIN_NAME
DATA_DIR     = CLAUDE_DIR / DATA_DIRNAME
CACHE_DIR.mkdir(parents=True, exist_ok=True)
DATA_DIR.mkdir(parents=True, exist_ok=True)

HEADERS = {
    "Authorization": f"token {PAT}",
    "User-Agent":    "joshicrea-ai-keieisha-installer",
    "Accept":        "application/vnd.github.v3+json",
}

# --- 最新コミット取得 ---
print("[1/4] プラグイン本体をダウンロード...")
API_URL = "https://api.github.com/repos/joshicrea/ai-keieisha/commits/master"
try:
    req = urllib.request.Request(API_URL, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=30) as resp:
        commit_info = json.loads(resp.read().decode("utf-8"))
    full_sha  = commit_info["sha"]
    short_sha = full_sha[:12]
except Exception as e:
    print(f"GitHubへの接続に失敗しました: {e}")
    print("GitHubアカウントが joshicrea/ai-keieisha のコラボレーターに招待されているか確認してください。")
    print("招待メールが届いている場合は GitHub上で承認してから再実行してください。")
    sys.exit(1)

INSTALL_PATH = CACHE_DIR / short_sha

if INSTALL_PATH.exists():
    print(f"  すでに最新版がダウンロード済み ({short_sha})")
else:
    ZIP_URL = f"https://api.github.com/repos/joshicrea/ai-keieisha/zipball/master"
    tmp_dir  = pathlib.Path(tempfile.mkdtemp())
    zip_path = tmp_dir / "ai-keieisha.zip"

    try:
        req = urllib.request.Request(ZIP_URL, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=120) as resp, open(zip_path, "wb") as out:
            shutil.copyfileobj(resp, out)
    except Exception as e:
        print(f"ダウンロードに失敗しました: {e}")
        sys.exit(1)

    ext_dir = tmp_dir / "extract"
    ext_dir.mkdir()
    with zipfile.ZipFile(zip_path, "r") as zf:
        zf.extractall(ext_dir)

    extracted = next(ext_dir.iterdir())
    shutil.move(str(extracted), str(INSTALL_PATH))
    shutil.rmtree(tmp_dir, ignore_errors=True)

    print(f"  ダウンロード完了 ({short_sha})")

# --- 古いバージョン（最新2世代以外）をクリーンアップ ---
existing = sorted(
    [d for d in CACHE_DIR.iterdir() if d.is_dir()],
    key=lambda p: p.stat().st_mtime,
    reverse=True
)
for old_ver in existing[2:]:
    print(f"  古いバージョンを削除: {old_ver.name}")
    shutil.rmtree(old_ver, ignore_errors=True)

# --- installed_plugins.json 更新 ---
print()
print("[2/4] Claude Code にプラグイン登録...")

PLUGINS_DIR.mkdir(parents=True, exist_ok=True)
INSTALLED_JSON = PLUGINS_DIR / "installed_plugins.json"
KEY = f"{PLUGIN_NAME}@joshicrea"
now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if INSTALLED_JSON.exists():
    with open(INSTALLED_JSON, encoding="utf-8") as f:
        installed = json.load(f)
else:
    installed = {"version": 2, "plugins": {}}

installed.setdefault("plugins", {})[KEY] = [{
    "scope":        "user",
    "installPath":  str(INSTALL_PATH),
    "version":      short_sha,
    "installedAt":  now_iso,
    "lastUpdated":  now_iso,
    "gitCommitSha": full_sha,
}]
with open(INSTALLED_JSON, "w", encoding="utf-8") as f:
    json.dump(installed, f, indent=2, ensure_ascii=False)

# --- settings.json 更新 ---
SETTINGS_JSON = CLAUDE_DIR / "settings.json"
if SETTINGS_JSON.exists():
    with open(SETTINGS_JSON, encoding="utf-8") as f:
        settings = json.load(f)
else:
    settings = {}
settings.setdefault("enabledPlugins", {})[KEY] = True
with open(SETTINGS_JSON, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
print("  プラグイン登録完了")

# --- プレースホルダー置換 ---
print()
print("[3/4] プラグイン内のプレースホルダーを実パスに置換...")
replacements = {
    "{{KEIEISHA_PLUGIN_ROOT}}": str(INSTALL_PATH),
    "{{KEIEISHA_BASE_DIR}}":    str(DATA_DIR),
}
for root, _, files in os.walk(INSTALL_PATH):
    for fn in files:
        if not fn.endswith((".md", ".json", ".txt")):
            continue
        fp = pathlib.Path(root) / fn
        try:
            content = fp.read_text(encoding="utf-8")
        except Exception:
            continue
        new = content
        for k, v in replacements.items():
            new = new.replace(k, v)
        if new != content:
            fp.write_text(new, encoding="utf-8")
print("  プレースホルダー置換完了")

# --- Unix: hooks/session-start に実行権を付与 ---
import stat
hook_script = INSTALL_PATH / "hooks" / "session-start"
if hook_script.exists():
    st = hook_script.stat()
    hook_script.chmod(st.st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

# --- ユーザーデータ準備 ---
print()
print("[4/4] ユーザーデータ領域を準備...")
(DATA_DIR / "ナレッジ").mkdir(parents=True, exist_ok=True)

status_file = DATA_DIR / ".setup-status"
if not status_file.exists():
    status_file.write_text("in_progress", encoding="utf-8")

profile_file = DATA_DIR / "user-profile.md"
if not profile_file.exists():
    profile_file.write_text(
        "# AI経営者 ユーザープロフィール\n\n"
        "<!-- セッション開始時に Claude が自動で記入します -->\n\n"
        "name:\nbusiness:\nsetup_date:\n",
        encoding="utf-8"
    )
print("  ユーザーデータ準備完了")

# --- 検証 ---
claude_md = INSTALL_PATH / "CLAUDE.md"
verify_ok = True
if not claude_md.exists():
    print(f"エラー: CLAUDE.md が見つかりません: {claude_md}")
    verify_ok = False
else:
    cm = claude_md.read_text(encoding="utf-8")
    if "{{KEIEISHA_PLUGIN_ROOT}}" in cm or "{{KEIEISHA_BASE_DIR}}" in cm:
        print("エラー: CLAUDE.md のプレースホルダー置換が不完全です")
        verify_ok = False
if not verify_ok:
    print()
    print("インストールに問題が発生しました。もう一度試してください。")
    sys.exit(1)

# --- 完了 ---
print()
print("==========================================")
print("インストール完了！")
print()
print("次の手順:")
print("  1. Claude Code を完全に閉じる")
print("  2. Claude Code を再度開く")
print("  3. チャットに「はじめまして」と送るとセットアップが始まります")
print("     （AI秘書セットアップ済みなら呼び名・事業内容が自動引き継ぎされます）")
print()
