# App icon

Icon Composerで作成した、白背景・青いタスクカード・白いチェックのアイコンです。
通常表示とダーク表示の両方に `System Light` の背景を明示指定しています。
OSの色合い指定（Tinted / Clear）ではシステムの外観処理が適用されます。

編集元は [`AppIcon.icon`](../../Greminder/Resources/AppIcon.icon) です。
内部の `Assets` に3枚の1024×1024 SVGレイヤーを含みます。
影・光沢・半透明の処理はIcon Composerで設定し、SVGには焼き込んでいません。

![Icon Composerから書き出したプレビュー](AppIcon-preview.png)

## アプリへの反映

- iOS / macOSの両ターゲットで同じ `.icon` をリソースとしてコンパイルします。
- `project.yml` にもファイルと `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` を定義しています。
- `scripts/package-macos.sh` のMacプレビューでも、同じ `.icon` を `actool` でコンパイルし、生成されたアイコン名をInfo.plistへ反映します。
- PNGは確認用です。アプリは `.icon` を使用します。デザインを更新した際はIcon ComposerのFile → ExportでPNGも更新してください。

組み込み方法: [Apple — Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
