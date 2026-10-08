# naituan-preview

奶团小屋（[starity777-byte/naituan](https://github.com/starity777-byte/naituan)）的**分支预览**，仅供试玩，不是正式版。

- 列表页：https://starity777-byte.github.io/naituan-preview/
- 每个分支在 `/<分支名>/` 目录下，例如 https://starity777-byte.github.io/naituan-preview/hide-seek-levels/
- 内容由 `preview.sh <分支名>` 自动生成，不要手改。

## 存档隔离

预览和正式版在同一个域名下（starity777-byte.github.io），浏览器存储是共用的。所以生成预览时会：

1. 把副本里所有 localStorage / sessionStorage 键和 IndexedDB 数据库名改成 `preview:<分支名>:<原名>`
   （每个预览目录里的 `preview-storage-keys.txt` 写着具体改了哪些）；
2. 在副本的 index.html 最前面加一段保险脚本：漏网的存储键也会自动加前缀，并禁止注册 Service Worker；
3. manifest 的 scope / start_url 只指向预览目录本身；
4. 去掉 51.LA 统计，不给正式版统计添数；
5. 左上角加一个小小的「预览：分支名」角标。

所以在预览里怎么玩都不会碰到正式存档。正式仓库本身从不被修改。

## 更新 / 新增 / 删除预览

```bash
/workspace/naituan-tools/preview.sh <分支名>
/workspace/naituan-tools/preview.sh --remove <分支名>
```

推送后 GitHub Pages 一般 1～3 分钟生效。
