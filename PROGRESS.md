# 作業進捗

- 最終更新: 2026-11-08 21:39 JST
- 現在の状態: 終了時クラッシュを修正。回帰テスト9件成功、実アプリの閉じる操作確認、最新app生成済み。

## 目的・ユーザーの要件

- Swift＋AppKitで画像と音声からMVを作るツールを実装する。
- 拍に同期したアニメーションと帯域ごとの可視化を簡単に利用できること。
- 今回は設計を基に機能を絞ったツールを作成する。
- コード修正後は追加指示なしで起動用appを生成する。

## 終了時クラッシュの修正

- ユーザー添付レポート: 最後のウィンドウを閉じた後、applicationShouldTerminate内のmakeFirstResponderでEXC_BAD_ACCESS。NSWindowの自動解放とSwift側の所有の競合を確認。
- `App.swift`: isReleasedWhenClosed=falseを設定。NSWindowDelegateで閉じる前に保存/処理中チェック。共通prepareToCloseへ集約し、SceneSettingsのUI読取と保存を分離。終了時はタイマー無効化・音声停止。テスト用にProjectStorageを注入可能とし、ユーザーの復元設定とテストを分離。
- `AppLifecycleTests.swift`: 実ウィンドウを閉じautoreleasepool後に保持を確認し、終了判定を呼ぶ回帰テストを追加。
- 全9テスト成功（`/tmp/my_movie-exit-test.log`）。releaseビルド成功（`/tmp/my_movie-exit-release.log`）。`dist/MV Studio.app`更新済み。
- 別bundle IDの `/tmp/MV Exit Check.app` をCUAで起動・閉じるボタンで終了し、プロセス消失を確認。検証後のDiagnosticReportsに新規MVStudioクラッシュなし（最新はユーザー報告時の21:36:51）。既存ユーザーアプリは操作していない。
- 整理フェーズで終了前の状態確認を共通化し、二重の明示的保存を除去。`git diff --check`成功。実行中のテスト/ビルドなし。

## 歌詞の自動反映

- ユーザー要件: 「歌詞を適用」を押さず編集を反映する。
- `LyricsEditor.swift`: 適用ボタンを削除。本文・開始/終了のdelegate通知から検証・即時反映・自動保存を実行。IME変換中は保留。確定モデル更新時に本文/時刻欄を書き換えず、カーソルと入力文字列を維持。
- `Lyrics.swift`: 全文削除を反映できるよう空本文を許可。区間検証は維持。
- `LyricsEditorTests.swift`: 自動反映・全文削除・カーソル維持・時刻空欄からの復帰・IME変換保留を追加検証。
- 整理フェーズ: 現在位置取込と自動反映を同じ検証経路へ集約。同内容の保存通知を抑制し、無効入力から元の値に戻した際のエラー表示も解除。
- 全8テスト成功（`/tmp/my_movie-auto-lyrics-test.log`）。最終整理後の編集テスト2件も成功（`/tmp/my_movie-auto-lyrics-final-test.log`）。最新版appビルドログは `/tmp/my_movie-auto-lyrics-release.log`。
- README、設計書、AGENTSを更新。`git diff --check`を確認。GUIでの実入力は今回未検証。

## 再生位置からの区間指定

- 要件: テロップ表示の開始・終了を現在の再生位置から指定可能にする。
- `LyricsEditor.swift`: 「現在位置を開始に」「現在位置を終了に」を追加。選択した歌詞へ編集欄の本文・区間とともに即時適用し、既存の検証/保存コールバックを利用。不正区間は保存しない。
- `App.swift`: ボタン押下時に音声を一時停止し、AVAudioPlayerの現在位置を取得してプレビューと再生ヘッドを同期。
- 整理フェーズ: 開始/終了の取込処理を共通化。一覧の確定時再選択とユーザー選択を分離し、適用時に開始へ戻る意図しないシークを解消。
- `LyricsEditorTests.swift`: 開始/終了設定、即時変更通知、逆転/曲末超過の拒否、編集中無効状態、確定時にシークしないことを検証。
- README、タイムライン設計、AGENTSを更新。テスト7件成功（`/tmp/my_movie-capture-test.log`）、releaseビルド成功（`/tmp/my_movie-capture-release.log`）。`git diff --check`成功。
- 最新 `dist/MV Studio.app` を生成。実行中のビルド/テストなし。今回の追加ボタンはAppKitコントローラのテストで確認し、GUIでの実音声の再生操作は未検証。

## 歌詞・縁取りの実装

- 要件: 歌詞テロップに縁取りを設定できること。既存コードには歌詞実装がなかったため、開始/終了秒と本文を編集する最小の歌詞一覧も追加。
- `Lyrics.swift`: 区間モデル/検証、全歌詞共通の縁取り色・太さ0〜12px、Core Textによるストローク→白本文の共通描画。
- `LyricsEditor.swift`: 歌詞追加/削除、選択・シーク、本文/時刻の適用、縁取り色・太さの即時変更。
- `App.swift`, `Scene.swift`, `VideoExporter.swift`: UIと共通描画・出力・自動保存を接続。スペクトラムOFFでも歌詞を表示。別音声へ新規切替時に歌詞をリセット。
- `ProjectFile.swift`: version 2でlyricsを保存・検証。旧形式はエラー表示し、ユーザーが選択した場合のみバックアップして新規作成。
- `LyricsTests.swift`, `StudioTests.swift`: 区間/設定検証、縁取り色・太さのピクセル比較、0で無効、保存往復、MP4再読込で緑の縁取りを検証。
- 整理フェーズで歌詞編集UIとモデル/描画を別ファイルへ分離。描画の状態を保存・復元し、背景/スペクトラム/歌詞の責務を独立。README・設計・AGENTSを現仕様へ更新。
- テスト6件成功: `/tmp/my_movie-outline-test.log`。描画画像 `/tmp/my_movie-outline-preview.png` を目視確認。
- リリースビルド成功: `/tmp/my_movie-outline-release.log`。`dist/MV Studio.app`更新済み。
- 別bundle IDの `/tmp/MV Outline Check.app` で初期UIを確認。既存のユーザーアプリは終了させていない。GUIでの素材選択からの一連の操作は未検証。
- `git diff --check`成功。実行中のビルド/テストなし。

## 作業指示の更新

- `AGENTS.md` に、コード修正・検証・整理後は `./scripts/build-app.sh` で最新appを生成し、成功を確認するルールを追加。
- 文書のみの変更は再生成対象外とし、失敗時の記録・報告も明記。既存の検証・整理ルールとの重複と整合性を確認。
- 今回は指示文書のみの変更のためビルドは実行しない。`git diff --check` で検証。

## タイムライン設計の完了事項

- ユーザー要件: タイムラインを設計し、初期段階では歌詞テロップ用の文字を並べられるようにする。
- `docs/TIMELINE.md`: 歌詞1トラック/区間クリップ、UI、時間精度、重なり制約、スナップ、編集コマンド/Undo、自動保存、Core Text描画、既存プレビュー/出力への接続、変更ファイル、実装順、検証計画を作成。
- README・全体設計・AGENTSに参照と要件を反映。
- 整理フェーズで永続モデルと一時編集状態、確定と仮編集、初期機能と将来拡張を分離。音声切替、プロジェクトversion、文字の重なり、既存レンダラーの早期returnを確認し設計に反映。
- 文書のみの変更。コードテストは再実行せず、参照先の存在と `git diff --check` を確認。

## 自動保存の追加要件と完了事項

- 音声読込フォルダへの自動保存と、次回起動時の自動復元を実装。
- `ProjectFile.swift`: バージョン付きJSON、素材参照、設定検証、atomic保存、最後に保存したURLの記録を分離。
- `App.swift`: 音声読込・画像変更・設定確定・終了時の保存。起動時と同じ音声の再選択時に復元。画像欠損時は参照を保持して再選択可能、音声/JSON読込失敗時は既存プロジェクトを上書きしない。
- `Scene.swift`: 設定をCodable化。README/設計書も現仕様へ更新。
- `ProjectStorageTests.swift`: 設定復元、次回起動参照、同一フォルダ移動、外部画像参照、上書き、無効設定/保存失敗/壊れたJSONを検証。
- 整理フェーズで永続化をUIから分離し、音声選択と起動復元を共通の読込処理へ集約。
- 全4テスト成功（`/tmp/my_movie-project-test.log`）。更新アプリのreleaseビルド成功（`/tmp/my_movie-project-release.log`）。`git diff --check`成功。GUI上での再起動往復は未実施。

## 基本実装の完了事項・変更したファイル

- `Package.swift`: macOS 14以降の実行可能アプリとテスト。Swift 6ツール、Swift 5言語モード。
- `Sources/MVStudio/App.swift`, `Entry.swift`: AppKit UI、画像/音声選択、音声再生、シーク、BPM/開始位置/強さ調整、帯域表示ON/OFF、進捗・キャンセル。
- `Sources/MVStudio/AudioAnalyzer.swift`: 2048点DFT、32対数帯域、ステレオパワー平均、平滑化、バックグラウンド解析。
- `Sources/MVStudio/Scene.swift`: 時刻ベースの拍パルス、帯域補間、共通Core Graphics描画。
- `Sources/MVStudio/VideoExporter.swift`: 720p/30fps H.264生成、元音声とのMP4結合、キャンセル、一時出力から保存先への確定。
- `Tests/MVStudioTests/StudioTests.swift`: DSP、時刻評価、音声付き出力の検証。
- `scripts/build-app.sh`: releaseビルド・appパッケージ化・ローカル署名。`dist/MV Studio.app` を生成。
- README、設計書、AGENTS、gitignoreを実装に合わせて更新。
- 整理フェーズでUI・解析・描画・書出しの責務を分離し、プレビューと出力の重複を共通描画へ集約。進捗クロージャの参照も整理。

## 検証内容・結果

- Xcode 27.2 / Swift 6.4.2でdebug/releaseビルド。
- XCTest 3件成功: 拍/開始位置・補間、無音、逆相ステレオ1kHz検出、音声付きMP4の生成・トラック/長さ/映像フレームの読込。
- 制限環境ではエンコード失敗。権限のある実行環境で成功を確認。
- CUAで実際のアプリ起動と初期画面を確認。素材選択・BPM・開始位置・強さ・スペクトラム・再生・書出しの表示と初期有効状態を確認。
- `git diff --check` 成功。
- ログ: `/tmp/my_movie-test-final.log`（3件成功）、`/tmp/my_movie-release.log`（最終ビルド）。

## 未解決事項・制約

- トランジェント検出、BPM自動推定、複数画像、Undoは未実装。保存は素材参照方式で、素材同梱は未実装。
- 実曲を使ったGUIでの一連の操作、長時間素材の性能、厳密な音画同期・色差の計測は未実施。
- アプリはローカル署名。配布用の公証は未実施。
- Core GraphicsとAVAudioPlayerで最小構成を採用。Metalと文書ベース構成は今後の目標設計。

## 次に実行する具体的な手順

- 更新した `dist/MV Studio.app` を使い、ユーザー素材で編集した後の終了と次回の復元を確認する。
- ドラッグ式タイムライン、tickモデル、Undo、枠超過警告は今後の実装対象。現状の本文は枠に入り切らない場合に末尾が表示されないため、短いフレーズを使う。
- 旧version 1プロジェクトの設定自動移行は未対応。新規作成時の別名バックアップを利用する。
