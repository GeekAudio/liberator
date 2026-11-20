# Liberator 中文本地化

Liberator ZH 由 GeekAudio 独立维护，基于 [Liberator 0.4.0 / v3.0.0-beta.4](https://github.com/nullmoth/liberator/releases/tag/v3.0.0-beta.4)。应用根据 macOS 的应用语言加载简体中文或繁体中文，其他语言使用上游英文文案。

- `zh-Hans.lproj/Interface.json` 与 `zh-Hant.lproj/Interface.json` 共用英文原文作为键。AppKit 弹窗、WebKit 页面、运行状态及 EFI 检查建议使用同一份译文。
- 含粗体、链接和控件的段落按完整语义翻译。`{1}`、`{2}` 等占位符对应原段落的内联元素，可以按中文语序调整位置，每个占位符保留一次。
- 运行 `python3 mac/tools/test_localizations.py` 可检查完整段落、指定分行和占位符。

## 中文排版

以下规则沿用 1401 的《中文语义与换行规范》，适用于简体、繁体和含中文的动态状态。

中文标题、正文和控件使用 macOS 的苹方简或苹方繁。日志和 EFI 配置值优先使用等宽字体，中文字符使用苹方。

1. 完整显示说明、条件、风险和结果，文字与卡片随内容增高。
2. 按内容区域的实际宽度排版。能容纳整句时保留在同一行，多句短文可同排。
3. 当前行放不下、下一行能放下时，把整句移到下一行。
4. 长句优先在完整分句后换行。条件引导词与其内容、动作与操作对象应一起阅读。
5. 尽量保持功能名、按钮名、型号、版本号和数值单位的完整性。路径、网址和命令过长时，保留全文并允许在分隔符处换行。
6. 保留明确指定的分行。两种中文的提前更新说明均把发送日志的提示另起一行。
7. 在实际窗口宽度检查页面、动态状态和中英文混排。长页面可纵向滚动，正文和按钮都能随可用空间调整。

`mac/tests/text_layout` 使用项目实际的 WebKit 页面和测试数据，验证整句同排、分句换行、信息单元和指定分行。测试会切换五个页面并注入长错误消息来检查内容是否溢出。

```sh
test_dir=$(mktemp -d)
xcrun swiftc mac/tests/text_layout/main.swift -o "$test_dir/text-layout-test"
for language in zh-Hans zh-Hant en; do
  for width in 960 1100 1440 1740; do
    "$test_dir/text-layout-test" "$PWD/mac" "$language" "$width"
  done
done
```
- `InfoPlist.strings` 提供系统权限提示的译文。更新插值文案时保留 `%@` 和 `{n}` 占位符以及 OpenCore 参数、文件名和路径。
- 界面会翻译已知的安装进度和诊断状态。原始诊断文件仍使用上游格式，供 NullMoth 排查。

在项目根目录执行以下命令可构建对应版本。传入的 pin 对应上游发布的 macOS 27 支持套件。

```sh
build_dir=$(mktemp -d)
V3_KIT_PIN="$PWD/release/beta4/v3-kit.pin" bash mac/build.sh "$build_dir"
codesign --verify --deep --strict "$build_dir/Liberator.app"
```

此构建使用本地 ad-hoc 签名。应用内的官方更新可能用上游应用替换中文构建，替换前会显示确认。
