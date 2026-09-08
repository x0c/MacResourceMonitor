#!/usr/bin/env bash
# Mac Resource Monitor macOS 一条命令发版：
#   Release 构建 -> 重签 Sparkle 内嵌件 -> Developer ID 签名自检 -> 苹果公证 -> 装订票据
#   -> 生成 Sparkle 签名更新包与 appcast -> 打 dmg -> 公证 dmg -> 装订
#   -> 提交 / 打 tag / 推送私有 origin
#   -> 把当前树的干净快照推到 GitHub（不把私有开发史推上去）
#   -> GitHub Release（dmg + 更新 zip）-> Homebrew cask -> 匿名终检
#
# 用法：
#   scripts/publish-release.sh              完整发版
#   scripts/publish-release.sh --local-only 只做到「本地产出已公证的 dmg」，不碰 git 与 GitHub
#
# 前置条件（缺任何一项脚本会直接报错退出）：
#   1. 钥匙串里有 "Developer ID Application" 证书及其私钥
#   2. 本地配置 `scripts/publish-local.env`（未入库，模板见 `publish-local.env.example`）
#   3. gh 已登录且有目标仓库权限（--local-only 时不需要）
#
# 可重复执行：tag / Release 已存在时走更新路径，不会中断。

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly SCHEME="MacResourceMonitor"
readonly APP_BUNDLE="Mac Resource Monitor"
readonly ASSET_STEM="Mac-Resource-Monitor"
readonly REPO="x0c/MacResourceMonitor"
readonly REPO_WEB="https://github.com/${REPO}"
readonly FEED_URL="https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
readonly CASK_NAME="mac-resource-monitor"
readonly TAP_REPO="x0c/homebrew-tap"
local_env="${ROOT_DIR}/scripts/publish-local.env"
[[ -f "${local_env}" ]] && source "${local_env}"
readonly NOTARY_KEY="${NOTARY_KEY:?缺少公证密钥文件路径（NOTARY_KEY），见 scripts/publish-local.env.example}"
readonly NOTARY_KEY_ID="${NOTARY_KEY_ID:?缺少公证 Key ID（NOTARY_KEY_ID）}"
readonly NOTARY_ISSUER="${NOTARY_ISSUER:?缺少公证 Issuer ID（NOTARY_ISSUER)}"
readonly SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:?缺少 Sparkle 签名账号（SPARKLE_ACCOUNT）}"
readonly SIGN_IDENTITY="Developer ID Application"
readonly BUILD_DIR="${ROOT_DIR}/build"
readonly APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/Release/${APP_BUNDLE}.app"
readonly NOTARY_POLL_INTERVAL=30
readonly NOTARY_TIMEOUT=3600

local_only=false
[[ "${1:-}" == "--local-only" ]] && local_only=true

log_step() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# 提交公证并轮询到出结果。submit 本身报错不当失败：
# 慢链路上长连接会断，但文件多半已被苹果受理，回头去 history 认领这一笔再轮询。
notarize_and_wait() {
  local file="$1"
  local submit_json submission_id status waited=0
  local basename_file started_at
  basename_file="$(basename "${file}")"
  started_at="$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ)"

  submit_json="$(xcrun notarytool submit "${file}" --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
    --issuer "${NOTARY_ISSUER}" --output-format json 2>/dev/null)" || submit_json=""
  submission_id="$(jq -r '.id // empty' <<<"${submit_json:-{\}}" 2>/dev/null || true)"

  if [[ -z "${submission_id}" ]]; then
    echo "本地没收到提交回执（大概率是长连接超时），去苹果侧认领刚刚这一笔提交…"
    for _ in 1 2 3 4 5; do
      sleep 10
      history_json="$(xcrun notarytool history --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
        --issuer "${NOTARY_ISSUER}" --output-format json 2>/dev/null)" || continue
      submission_id="$(jq -r --arg name "${basename_file}" --arg since "${started_at}" \
        '[.history[]? | select(.name==$name and .createdDate>=$since)] | sort_by(.createdDate) | last | .id // empty' \
        <<<"${history_json}" 2>/dev/null || true)"
      [[ -n "${submission_id}" ]] && break
    done
    [[ -n "${submission_id}" ]] \
      || die "提交公证失败且苹果侧查不到这一笔：${file}（可用 notarytool history 和同一组公证凭据自查）"
  fi
  echo "提交编号：${submission_id}（苹果排队中，慢的时候可能要几十分钟）"

  local info_out consecutive_failures=0
  while (( waited < NOTARY_TIMEOUT )); do
    sleep "${NOTARY_POLL_INTERVAL}"
    waited=$(( waited + NOTARY_POLL_INTERVAL ))
    info_out="$(xcrun notarytool info "${submission_id}" --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
      --issuer "${NOTARY_ISSUER}" --output-format json 2>&1)" || true
    status="$(jq -r '.status // empty' <<<"${info_out}" 2>/dev/null || true)"
    if [[ -z "${status}" ]]; then
      consecutive_failures=$(( consecutive_failures + 1 ))
      if (( consecutive_failures >= 5 )); then
        printf '\n'
        die "连续 5 次查不到公证状态，先排查网络再重跑。原始报错：$(head -1 <<<"${info_out}")"
      fi
      printf '?'
      continue
    fi
    consecutive_failures=0
    [[ "${status}" == "In Progress" ]] && { printf '.'; continue; }
    printf '\n'
    if [[ "${status}" == "Accepted" ]]; then
      echo "公证通过（已等待约 $(( waited / 60 )) 分钟）"
      return 0
    fi
    xcrun notarytool log "${submission_id}" --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
      --issuer "${NOTARY_ISSUER}" 2>/dev/null | head -40 || true
    die "公证被拒（状态 ${status}），详细原因见上方日志"
  done
  die "公证等待超过 $(( NOTARY_TIMEOUT / 60 )) 分钟仍无结果，稍后用 xcrun notarytool info ${submission_id} … 继续查"
}

# 把当前索引树推到 GitHub main，不携带私有仓祖先提交。
push_github_snapshot() {
  local message="$1"
  local tree parent="" commit
  git remote get-url github >/dev/null 2>&1 \
    || die "缺少 github remote（git remote add github git@github.com:${REPO}.git）"
  git add -A
  tree="$(git write-tree)"
  parent="$(git ls-remote github refs/heads/main 2>/dev/null | awk '{print $1}')"
  if [[ -n "${parent}" ]]; then
    commit="$(git commit-tree "${tree}" -p "${parent}" -m "${message}")"
  else
    commit="$(git commit-tree "${tree}" -m "${message}")"
  fi
  git -c core.hooksPath=/dev/null push github "${commit}:refs/heads/main"
  git -c core.hooksPath=/dev/null push github "${commit}:refs/tags/${tag}"
}

cd "${ROOT_DIR}"

# ---------- 0. 前置检查 ----------
log_step "检查前置条件"
grep -q "${SIGN_IDENTITY}" <<<"$(security find-identity -v -p codesigning)" \
  || die "钥匙串里没有 Developer ID Application 证书，无法对外分发（Xcode -> Settings -> Accounts -> Manage Certificates 创建）"
[[ -f "${NOTARY_KEY}" ]] || die "找不到公证密钥文件：${NOTARY_KEY}"
notary_check="$(xcrun notarytool history --key "${NOTARY_KEY}" --key-id "${NOTARY_KEY_ID}" \
  --issuer "${NOTARY_ISSUER}" 2>&1)" \
  || die "公证密钥不可用（检查密钥文件、Key ID、Issuer ID 是否匹配）。原始报错：$(head -1 <<<"${notary_check}")"
if [[ "${local_only}" == false ]]; then
  gh auth status >/dev/null 2>&1 || die "gh 未登录"
  gh repo view "${REPO}" --json visibility --jq 'select(.visibility=="PUBLIC")' >/dev/null \
    || die "${REPO} 不存在或不是公开仓库"
fi

# 版本号双写一致性：Base.xcconfig 与 project.yml 必须相同，构建前先查（毫秒级，别浪费在构建后）
version="$(sed -n 's/^MARKETING_VERSION = //p' Configuration/Base.xcconfig | tr -d ' ')"
project_version="$(sed -n 's/^ *MARKETING_VERSION: //p' project.yml | tr -d ' ')"
build_number="$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' Configuration/Base.xcconfig | tr -d ' ')"
project_build_number="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: //p' project.yml | tr -d ' ')"
[[ -n "${version}" ]] || die "没能从 Configuration/Base.xcconfig 读出版本号"
[[ "${version}" == "${project_version}" ]] \
  || die "版本号不一致：Base.xcconfig=${version}，project.yml=${project_version}，两处必须相同"
[[ "${build_number}" =~ ^[0-9]+$ && "${build_number}" -gt 0 ]] \
  || die "内部构建号必须是正整数，当前为：${build_number}"
[[ "${build_number}" == "${project_build_number}" ]] \
  || die "内部构建号不一致：Base.xcconfig=${build_number}，project.yml=${project_build_number}，两处必须相同"
readonly version
readonly build_number
readonly tag="v${version}"
readonly dmg_path="${BUILD_DIR}/${ASSET_STEM}-${version}.dmg"
readonly update_zip_path="${BUILD_DIR}/${ASSET_STEM}-${version}.zip"
readonly sparkle_bin_dir="${BUILD_DIR}/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT
readonly work_dir

# 更新清单防回退：线上构建号高于本次就拒绝发布
if [[ "${local_only}" == false ]] \
  && curl -fsSL "${FEED_URL}" -o "${work_dir}/current-appcast.xml" 2>/dev/null; then
  current_published_build="$(xmllint --xpath 'string((//*[local-name()="version"])[1])' \
    "${work_dir}/current-appcast.xml" 2>/dev/null || true)"
  if [[ "${current_published_build}" =~ ^[0-9]+$ ]] \
    && (( build_number < current_published_build )); then
    die "拒绝回退公开更新清单：线上内部构建号 ${current_published_build}，本次为 ${build_number}"
  fi
fi
log_step "本次发布版本：${tag}（内部构建号 ${build_number}）"

# ---------- 1. 构建 ----------
log_step "生成 Xcode 工程并做 Release 构建"
xcodegen generate >/dev/null
xcodebuild -project "${SCHEME}.xcodeproj" -scheme "${SCHEME}" -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates build \
  || die "Release 构建失败"
[[ -d "${APP_PATH}" ]] || die "构建产物不存在：${APP_PATH}"
[[ -x "${sparkle_bin_dir}/generate_appcast" ]] || die "找不到 Sparkle 的 generate_appcast 工具"
[[ -x "${sparkle_bin_dir}/sign_update" ]] || die "找不到 Sparkle 的 sign_update 工具"

# ---------- 1.5 重签 Sparkle 内嵌可执行文件 ----------
# xcodebuild 只重签 Sparkle.framework 本体，framework 内部的 Updater.app / Autoupdate /
# 两个 XPC 服务仍保留 SPM 包自带的 ad-hoc 签名，苹果公证会逐个检查并打回。
# 必须按「最内层先签」的顺序用 Developer ID 重签，最后重签外层 App。
log_step "重签 Sparkle 内嵌可执行文件（Updater / Autoupdate / XPC 服务）"
sparkle_fw_dir="${APP_PATH}/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --options runtime --timestamp \
  --entitlements "${BUILD_DIR}/DerivedData/SourcePackages/checkouts/Sparkle/Downloader/Downloader.entitlements" \
  --sign "${SIGN_IDENTITY}" "${sparkle_fw_dir}/XPCServices/Downloader.xpc" \
  || die "重签 Sparkle Downloader.xpc 失败"
codesign --force --options runtime --timestamp \
  --sign "${SIGN_IDENTITY}" "${sparkle_fw_dir}/XPCServices/Installer.xpc" \
  || die "重签 Sparkle Installer.xpc 失败"
codesign --force --options runtime --timestamp \
  --sign "${SIGN_IDENTITY}" "${sparkle_fw_dir}/Updater.app" \
  || die "重签 Sparkle Updater.app 失败"
codesign --force --options runtime --timestamp \
  --sign "${SIGN_IDENTITY}" "${sparkle_fw_dir}/Autoupdate" \
  || die "重签 Sparkle Autoupdate 失败"
codesign --force --options runtime --timestamp \
  --sign "${SIGN_IDENTITY}" "${APP_PATH}/Contents/Frameworks/Sparkle.framework" \
  || die "重签 Sparkle.framework 失败"
codesign --force --options runtime --timestamp \
  --sign "${SIGN_IDENTITY}" "${APP_PATH}" \
  || die "重签 ${APP_BUNDLE}.app 失败"
sparkle_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' MacResourceMonitor/Info.plist 2>/dev/null || true)"
[[ -n "${sparkle_public_key}" ]] || die "Info.plist 缺少 Sparkle 更新公钥"
[[ "$("${sparkle_bin_dir}/generate_keys" --account "${SPARKLE_ACCOUNT}" -p 2>/dev/null)" == "${sparkle_public_key}" ]] \
  || die "钥匙串里的 Sparkle 更新签名密钥缺失或与应用公钥不匹配"

# ---------- 2. 签名自检 ----------
log_step "校验签名、加固运行时与权限清单"
sign_info="$(codesign -dv --verbose=2 "${APP_PATH}" 2>&1)"
entitlements="$(codesign -d --entitlements - "${APP_PATH}" 2>/dev/null || true)"
grep -q "Authority=${SIGN_IDENTITY}" <<<"${sign_info}" \
  || die "产物不是 Developer ID 签名，检查 project.yml 的 Release 配置"
grep -q "flags=.*runtime" <<<"${sign_info}" \
  || die "产物没开加固运行时，苹果公证会打回"
if grep -q "get-task-allow" <<<"${entitlements}"; then
  die "产物带调试权限 get-task-allow，苹果公证会打回（检查 CODE_SIGN_INJECT_BASE_ENTITLEMENTS）"
fi
# 嵌套辅助程序逐个核对签发者与时间戳：deep 校验只看结构，拦不住 adhoc 签名
for nested in "${sparkle_fw_dir}/XPCServices/Downloader.xpc" \
              "${sparkle_fw_dir}/XPCServices/Installer.xpc" \
              "${sparkle_fw_dir}/Updater.app" \
              "${sparkle_fw_dir}/Autoupdate"; do
  nested_info="$(codesign -dv --verbose=2 "${nested}" 2>&1)"
  grep -q "Authority=${SIGN_IDENTITY}" <<<"${nested_info}" \
    || die "嵌套组件不是 Developer ID 签名：${nested}"
  grep -q "Timestamp=" <<<"${nested_info}" \
    || die "嵌套组件缺安全时间戳：${nested}"
done

# ---------- 3. 公证应用本体 ----------
log_step "提交苹果公证（应用本体），通常 1-5 分钟"
rm -f "${BUILD_DIR}/${ASSET_STEM}-notarize.zip"
ditto -c -k --keepParent "${APP_PATH}" "${BUILD_DIR}/${ASSET_STEM}-notarize.zip"
notarize_and_wait "${BUILD_DIR}/${ASSET_STEM}-notarize.zip"

log_step "把公证票据装订进应用"
xcrun stapler staple "${APP_PATH}" || die "装订票据失败"

# ---------- 4. 生成 Sparkle 更新包与清单 ----------
log_step "生成 Sparkle 签名更新包与 appcast"
release_notes_file="${work_dir}/release-notes.md"
cat > "${release_notes_file}" <<EOF
Mac Resource Monitor ${version}

- Click the menu-bar rings for the CPU and memory list, or click upload/download for the matching network-activity list.
- Network activity refreshes every second, stays in step with the menu-bar readings, and never opens to a blank panel.
- The active connection is detected automatically; right-click Show Network Speed hides or restores the readings and remembers the choice.
EOF

appcast_dir="${work_dir}/appcast"
mkdir -p "${appcast_dir}"
rm -f "${update_zip_path}"
ditto -c -k --keepParent "${APP_PATH}" "${update_zip_path}"
ditto "${update_zip_path}" "${appcast_dir}/${ASSET_STEM}-${version}.zip"
if [[ -f appcast.xml ]]; then
  ditto appcast.xml "${appcast_dir}/appcast.xml"
fi

"${sparkle_bin_dir}/generate_appcast" \
  --account "${SPARKLE_ACCOUNT}" \
  --download-url-prefix "${REPO_WEB}/releases/download/${tag}/" \
  --embed-release-notes \
  --link "${REPO_WEB}" \
  --versions "${build_number}" \
  --maximum-versions 10 \
  -o "${appcast_dir}/appcast.xml" \
  "${appcast_dir}" >/dev/null \
  || die "生成 Sparkle appcast 失败"
xmllint --noout "${appcast_dir}/appcast.xml" || die "Sparkle appcast 不是合法 XML"
grep -q "sparkle:edSignature=" "${appcast_dir}/appcast.xml" \
  || die "Sparkle appcast 缺少 EdDSA 更新签名"
"${sparkle_bin_dir}/sign_update" --account "${SPARKLE_ACCOUNT}" --verify "${appcast_dir}/appcast.xml" >/dev/null \
  || die "Sparkle appcast 完整性校验失败：拒绝发布未经签名或已被改写的更新清单"
# 版本说明必须内嵌（外链文件若被引用，必须与 appcast 一并入库并在终检核对长度）
if grep -q "releaseNotesLink" "${appcast_dir}/appcast.xml"; then
  die "appcast 引用了外链版本说明；请确认说明文件已随 appcast 一并提交，并核对 sparkle:length"
fi

# ---------- 5. 打 dmg ----------
log_step "打包 dmg"
stage_dir="${work_dir}/dmg"
mkdir -p "${stage_dir}"
ditto "${APP_PATH}" "${stage_dir}/${APP_BUNDLE}.app"
ln -s /Applications "${stage_dir}/Applications"
rm -f "${dmg_path}"
diskutil image create from "${stage_dir}" "${dmg_path}" \
  --format UDZO --volumeName "${APP_BUNDLE} ${version}" >/dev/null 2>&1 \
  || hdiutil create -volname "${APP_BUNDLE} ${version}" -srcfolder "${stage_dir}" \
    -ov -format UDZO "${dmg_path}" >/dev/null \
  || die "打 dmg 失败"

log_step "公证 dmg 并装订票据"
notarize_and_wait "${dmg_path}"
xcrun stapler staple "${dmg_path}" || die "dmg 装订票据失败"

log_step "模拟首次打开做最终校验"
grep -q "accepted" <<<"$(spctl -a -vvv -t install "${APP_PATH}" 2>&1)" \
  || die "Gatekeeper 校验未通过，别人机器上仍会被拦"
xcrun stapler validate "${dmg_path}" >/dev/null || die "dmg 票据校验失败"
echo "✓ 已产出可双击直接打开的 dmg：${dmg_path}"

if [[ "${local_only}" == true ]]; then
  log_step "已按 --local-only 结束，未推送、未发布"
  exit 0
fi

ditto "${appcast_dir}/appcast.xml" appcast.xml

# ---------- 6. 提交与打 tag（私有 origin） ----------
log_step "提交改动并打 tag"
git add -A
if ! git diff --cached --quiet; then
  git -c core.hooksPath=/dev/null commit -m "chore: 发布 ${tag}"
else
  echo "工作区无改动，跳过提交"
fi
if git rev-parse "${tag}" >/dev/null 2>&1; then
  echo "tag ${tag} 已存在，沿用"
else
  git tag -a "${tag}" -m "${tag}"
fi
git push origin main
git push origin "${tag}"

# ---------- 7. 公开仓快照 + GitHub Release ----------
log_step "把当前树快照推到 GitHub（不含私有开发史）"
push_github_snapshot "Release ${tag}"

# 禁止 create 时带附件：uploads.github.com 会 404，Release 可能留下空壳或根本不存在。
log_step "发布 GitHub Release（先建空再传 dmg + 更新 zip）"
if ! gh release view "${tag}" --repo "${REPO}" >/dev/null 2>&1; then
  gh release create "${tag}" --repo "${REPO}" \
    --title "${tag}" --notes-file "${release_notes_file}" \
    || die "创建 GitHub Release 失败"
fi
gh release upload "${tag}" --repo "${REPO}" "${dmg_path}" "${update_zip_path}" --clobber \
  || die "上传 Release 附件失败"

# ---------- 8. Homebrew cask ----------
log_step "更新 Homebrew cask（防版本回退）"
dmg_sha="$(shasum -a 256 "${dmg_path}" | awk '{print $1}')"
tap_dir="${work_dir}/homebrew-tap"
git clone --depth 20 "git@github.com:${TAP_REPO}.git" "${tap_dir}"
cask_file="${tap_dir}/Casks/${CASK_NAME}.rb"
existing_version=""
if [[ -f "${cask_file}" ]]; then
  existing_version="$(python3 - "${cask_file}" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'version\s+"([^"]+)"', text)
print(m.group(1) if m else "")
PY
)"
fi
if [[ -n "${existing_version}" ]]; then
  python3 - "${existing_version}" "${version}" <<'PY' || die "拒绝回退 Homebrew 配方：线上 ${existing_version}，本次 ${version}"
import sys
def parse(v):
    parts = []
    for piece in v.split("."):
        n = ""
        for ch in piece:
            if ch.isdigit():
                n += ch
            else:
                break
        parts.append(int(n or "0"))
    return tuple(parts)
old, new = sys.argv[1], sys.argv[2]
raise SystemExit(0 if parse(new) >= parse(old) else 1)
PY
fi
cat > "${cask_file}" <<EOF
cask "${CASK_NAME}" do
  version "${version}"
  sha256 "${dmg_sha}"

  url "https://github.com/${REPO}/releases/download/v#{version}/${ASSET_STEM}-#{version}.dmg"
  name "${APP_BUNDLE}"
  desc "Menu bar resource table: see CPU, memory, and network use, then end apps"
  homepage "${REPO_WEB}"

  depends_on macos: :tahoe

  app "${APP_BUNDLE}.app"

  zap trash: [
    "~/Library/Preferences/top.caozc.MacResourceMonitor.plist",
  ]
end
EOF
git -C "${tap_dir}" add "Casks/${CASK_NAME}.rb"
if git -C "${tap_dir}" diff --cached --quiet; then
  echo "Homebrew 配方已是 ${version}，无需更新"
else
  git -C "${tap_dir}" -c core.hooksPath=/dev/null commit -m "mac-resource-monitor ${version}"
  git -C "${tap_dir}" push origin HEAD
fi

# ---------- 9. 匿名终检 ----------
log_step "匿名下载与更新清单终检"
curl -fsSL "${FEED_URL}" -o "${work_dir}/published-appcast.xml" \
  || die "公开 appcast 无法匿名下载"
xmllint --noout "${work_dir}/published-appcast.xml" || die "线上 appcast 不是合法 XML"
grep -q "<sparkle:version>${build_number}</sparkle:version>" "${work_dir}/published-appcast.xml" \
  || die "线上 appcast 没有当前内部构建号 ${build_number}"
"${sparkle_bin_dir}/sign_update" --account "${SPARKLE_ACCOUNT}" --verify "${work_dir}/published-appcast.xml" >/dev/null \
  || die "线上 appcast 完整性校验失败：公开更新清单未签名或传输后被改写"
curl -fsSL --range 0-0 "${REPO_WEB}/releases/download/${tag}/${ASSET_STEM}-${version}.zip" -o /dev/null \
  || die "Sparkle 更新包无法匿名下载"
curl -fsSL --range 0-0 "${REPO_WEB}/releases/download/${tag}/${ASSET_STEM}-${version}.dmg" -o /dev/null \
  || die "首次安装 dmg 无法匿名下载"

log_step "发布完成"
cat <<EOF
版本：${tag}（内部构建号 ${build_number}）
首次安装：${REPO_WEB}/releases/latest
一键安装：brew tap x0c/tap && brew install --cask ${CASK_NAME}
自动更新：${FEED_URL}
状态：安装包可匿名下载，已完成 Sparkle 签名、Developer ID 签名、苹果公证与票据装订
EOF
