# MV Studio

画像1枚と音声1本から、音楽に連動するMVを作るSwift＋AppKitのmacOSアプリです。

## 起動

macOS 14以降、Xcode/Swift 6以降が必要です。外部ライブラリは不要です。

```bash
./scripts/build-app.sh
open "dist/MV Studio.app"
```

生成されるアプリはローカル利用用の署名です。Xcodeで開く場合は `Package.swift` を開き、MVStudioを実行してください。

## 使い方

1. 「画像を選択…」でPNG/JPEG/TIFFを読み込みます。
2. 「音声を選択…」で音声を読み込みます。32帯域の解析が完了するまで待ちます。
3. BPM、拍の開始位置（秒）、拡大の強さを調整します。開始位置より前は拡大しません。
4. 「再生」で音声と映像を確認します。スライダーで任意の時刻へ移動できます。
5. 「スペクトラムを表示」で帯域表示を切り替えます。
6. 「MP4を書き出す」で音声全体を1280×720・30fpsのH.264/AAC動画として保存します。

音声はmacOSがデコードできるWAV/AIFF/M4A/MP3などに対応します。解析・書き出し中は設定を固定し、「キャンセル」で停止できます。出力先の既存ファイルは保存ダイアログで置換を確認した後、出力完成時に置き換えます。

## シンプル版の範囲

- 画像のアスペクト比を保持した中央配置、拍に同期した拡大パルス
- 周波数帯域の強さを表示する32本の棒状スペクトラム
- 音声付きプレビュー、シーク、動画書き出し
- 解析と描画を分離し、プレビューと出力で共通の時刻評価・描画を使用

BPMは手動指定です。トランジェント検出、BPM自動推定、複数画像・レイヤー、プロジェクト保存、Undoは今後の実装対象です。ウィンドウを閉じると編集内容は失われます。

シンプル版はCore Graphicsで描画し、AVAudioPlayerで再生します。出力は一時映像を作成してから元音声と結合します。大規模なレイヤー編集向けのMetal構成は [設計書](docs/ARCHITECTURE.md) に記載しています。

## 検証

```bash
CLANG_MODULE_CACHE_PATH=/tmp/my_movie-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/my_movie-swift-cache \
swift test --disable-sandbox --cache-path /tmp/my_movie-spm-cache
```

無音、逆相ステレオの1kHz帯域検出、拍と開始位置、補間、音声付きMP4生成・読み戻しをテストします。書き出しテストにはmacOSのメディアエンコーダへのアクセスが必要です。

構成は `Sources/MVStudio`（UI、解析、共通描画、書出し）と `Tests/MVStudioTests` に分離しています。継続的な進捗は `PROGRESS.md` を参照してください。
