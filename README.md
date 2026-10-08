# naituan-preview

奶团小屋（[starity777-byte/naituan](https://github.com/starity777-byte/naituan)）的**分支预览**，仅供试玩，不是正式版。

- 列表页：https://starity777-byte.github.io/naituan-preview/
- 每个打开中的 PR 的分支在 `/<分支名>/` 下，例如 https://starity777-byte.github.io/naituan-preview/hide-seek-levels/
- 这里的预览目录全部由脚本自动生成，不要手改。

## 自动更新

`.github/workflows/preview.yml` 每 10 分钟（以及手动触发 / 修改脚本时）运行 `scripts/build-preview.sh`：

1. 读取 naituan 所有打开中的 PR（只处理同仓库分支，fork 来的 PR 为安全起见不做预览）；
2. 分支有新提交才重建该预览（已构建的提交记在 `<分支>/preview-info.txt`）；
3. PR 合并或关闭、分支被删后，对应预览目录自动删除；
4. 重新生成列表页，有变化才提交推送。GitHub Pages 从本仓库 `main` 分支根目录发布。

正式仓库 naituan 只被读取，从不被修改。

## 存档隔离

预览和正式版在同一个域名（starity777-byte.github.io）下，浏览器存储是共用的，所以副本里：

1. 所有 localStorage / sessionStorage 键、IndexedDB 库名、Cache Storage 名都加 `-preview` 后缀
   （如 `naituan-house-v1` → `naituan-house-v1-preview`，备份键随之变成 `naituan-house-v1-preview-backup`；
   `naituan-life-photos-v1` → `naituan-life-photos-v1-preview`）。每个预览目录的 `preview-storage-keys.txt` 列出了具体改动；
2. index.html 最前面有一段保险脚本：漏网的存储名运行时也会自动加 `-preview`，并禁止注册 Service Worker；
3. manifest 的 scope / start_url 只指向预览目录本身；
4. 访问统计脚本整个去掉，`NaituanStats` 变成空实现；
5. 所有页面 `noindex`，根目录 robots.txt 禁止收录；
6. 顶部一条红色「预览版 · 分支名」提示条（不挡点击）。

## 手动运行

```bash
gh workflow run preview.yml -R starity777-byte/naituan-preview              # 立刻在 GitHub 上跑一次
gh workflow run preview.yml -R starity777-byte/naituan-preview -f force=true # 全部重建
bash scripts/build-preview.sh   # 本地生成（需要 gh 已登录或 GH_TOKEN），之后自己 commit + push
```
