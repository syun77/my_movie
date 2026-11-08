# 表示範囲の拡張（完了）

- 最終更新: 2026-11-09 JST
- 要件: 表示範囲を最大5分、または読み込んだ曲全体に指定可能にする。
- 方針: 固定範囲2〜300秒と「曲全体」の切替を共通タイムラインへ追加し、アプリ設定として保存。曲切替時は全体表示を新しい曲長へ追従。
- 状態: 固定2〜300秒・曲全体切替・保存/復元・曲長追従を実装済み。既存変更は保持。
- 整理: 表示範囲のUI同期をPlacementEditor.updateDisplayRangeへ集約。歌詞/画像の目盛り間隔はTimelineGeometry.tickIntervalへ共通化し、幅に応じて調整。
- 変更: TimelineDisplaySettings/PlacementEditor/App/TimelineGeometry/TimelineView、TimelineDisplaySettingsTests、README・設計書・AGENTS。
- 検証: 制限環境では全30件中、既存のペーストボード/メディアサービス依存2件のみ失敗。新規テスト成功。権限付き全テストは成功、ログ /tmp/my_movie-range-test-final.log。
- 最終検証: 全30テスト成功（/tmp/my_movie-range-test-final.log）、git diff --check成功。./scripts/build-app.sh成功（/tmp/my_movie-range-build-final.log）、最新dist/MV Studio.app生成・署名済み。制限環境のdsymutil失敗は権限付き実行で解消。
- 未解決障害・実行中処理なし。実GUI手動確認は未実施、AppKit自動テストで操作を検証。
- 次: 最新appを再起動し、「表示範囲」スライダーまたは「曲全体」を使用する。

# 作業進捗

## Undo/Redo実装（完了）

- 最終更新: 2026-11-09 01:03 JST
- 要件: 歌詞・画像・共通設定の編集をUndo/Redo可能にする。
- 方針: 共通のモデルスナップショット履歴、入力/マウス操作のグループ化、復元時の選択・UI・プレビュー同期と自動保存。音声/プロジェクト切替成功時は履歴をリセットする。
- 状態: EditHistory/App/StudioWindow/両Editorへ実装、README/設計/AGENTS更新。新規UndoTests 3件成功（/tmp/my_movie-undo-focused.log）。歌詞入力のグループ化、画像素材削除/置換/配置移動、スライダー、IME、保存失敗時の履歴維持、実JSON再読込を検証。
- 初回全26テストでは既存のメディアサービス/ペーストボード制限による2件失敗（/tmp/my_movie-undo-test.log）。権限のある環境で最終全テストを実行する。
- 整理フェーズ: 履歴を値型スナップショットとpast/futureへ集約。入力とマウス操作の境界を分離し、標準入力Undoとの二重管理を回避。削除復元後の選択/画像段、非同期素材確認の世代管理、起動直後の初期履歴を整理。
- 検証: 全29テスト成功（/tmp/my_movie-undo-final-test.log）。追加の管理画面テストは画像タブを表示してから開く手順へ修正済み。画像段選択の最終整理後も全29テスト成功、app生成済み。
- 最終検証: 全29テスト成功（/tmp/my_movie-undo-final-test.log）。./scripts/build-app.sh成功（/tmp/my_movie-undo-build.log）、最新dist/MV Studio.app生成・ローカル署名済み。git diff --check成功。
- 変更ファイル: Sources/MVStudio/EditHistory.swift、App.swift、StudioWindow.swift、LyricsEditor.swift、ImageEditor.swift、Scene.swift、Tests/MVStudioTests/UndoTests.swift、README.md、docs/TIMELINE.md、docs/IMAGE_TIMELINE.md、docs/ARCHITECTURE.md、AGENTS.md、PROGRESS.md。
- 制約: 履歴はメモリ内、音声/プロジェクト読込成功時にリセット。外部ファイルの変更/動画出力/表示操作は対象外。IME変換中と処理中はUndoを実行しない。実GUI手動検証は未実施、AppKitイベントと実保存の自動テストで検証。
- 次: 最新appを再起動して編集メニューまたは⌘Z/⇧⌘Zを利用する。実行中処理・未解決障害なし。

## Undo対応のコード監査（完了）

- 最終更新: 2026-11-09 00:54 JST
- 要件: すべての編集操作がUndo可能かコードで確認。実装変更は対象外。
- 結果: プロジェクト編集用Undo/Redoは未実装。Sources/Tests全体にundoManager/registerUndo/Undo/Redo/履歴実装・テストなし。編集メニューはカット/コピー/ペースト/全選択のみ。
- 確認範囲: 歌詞の追加/削除/本文/時刻/連結/ドラッグ/縁取り、画像の追加（ボタン/ドロップ/管理）/配置削除/時刻/段移動/トリム/拍拡大/個別差替/素材置換/素材削除/欠損復旧、BPM/拍開始/スペクトラム、音声・プロジェクト切替。各確定経路はモデル更新→自動保存で逆操作登録なし。
- 本文NSTextViewのallowsUndo有効化なし。数値欄のfield editorに標準の局所的な入力Undoがあっても、確定済みプロジェクト編集全体のUndoにはならない。実GUIでの標準入力挙動は未検証。
- Escはドラッグ中の仮変更取消のみ。mouseUpで確定した変更のUndoには対応しない。選択/シーク/表示範囲/タブは作品データの編集と区別。
- 変更ファイル: PROGRESS.md、AGENTS.md（知見）。アプリコードは変更なし。既存差分は保持。
- 検証: 静的な呼出経路調査、Sources/Tests全体検索、git diff --check。テスト・app再生成はコード変更なしのため実施しない。
- 未解決: Undo機能自体は未実装。次: 実装依頼があれば共通履歴、操作単位のグループ化、Undo/Redo後のUI同期・自動保存、入力フォーカス/非同期読込/プロジェクト切替の境界と回帰テストを設計する。実行中処理なし。

- 最終更新: 2026-11-09 00:55 JST
- 今回の作業: 画像クリップのレイヤー間ドラッグ移動完了。全26テスト成功、最新app生成済み。
- 直前の完了: 画像3レイヤー/配置タブ/歌詞ゴースト/画像ドロップ/画像管理を実装完了。最終全25テスト成功、最新app生成済み。
- 直前の完了: 画像ドロップと画像管理画面（削除/置換/欠損復旧）の設計追加完了。文書のみ更新、未実装。
- 直前の完了: 画像3レイヤー/配置モード/歌詞ゴーストの設計完了。文書のみ更新、実装は未着手。
- 直前の完了: 1080p（1920×1080）動画出力完了。全18テスト成功、最新app生成済み。
- 直前の完了: Command+Spaceへの変更完了。関連17テスト成功、最新app生成済み。
- 直前の完了: 入力中のControl+Space再生切替を実装完了。関連17テスト成功、最新app生成済み。
- 直前の完了事項: 拡大タイムライン表示範囲の保存/復元完了。関連17テスト成功、最新app生成済み。
- 直前の完了: 非入力時Spaceで再生/停止、入力時Escでフォーカス解除を実装完了。関連16テスト成功、最新app生成済み。
- 直前の作業: 現在位置を開始/終了にする2ボタン削除完了。関連15テスト成功、最新app生成済み。
- 前回の作業: 16分音符スナップ完了。全17テスト成功、最新app生成済み。
- 現在の状態: 16分音符スナップ付きタイムラインで区間編集。現在位置から開始/終了を指定するボタンは削除済み。

## レイヤー間ドラッグ移動

- 要件: 画像クリップをレイヤー間で移動できること。
- TimelineView.swift: 本体を別行へドラッグすると、ImageTrack.updatingを使って開始/終了/演出を保持した段移動。同じ段なら従来の左右移動。端トリムは所属段を維持。
- 仮配置/移動先行のハイライト、衝突の赤枠/禁止カーソル、衝突/行外では原状復帰、Esc取消、mouseUp最終位置の再評価を追加。
- 整理フェーズ: 段移動の検証は既存モデル操作に集約し、仮状態と確定を分離。無効位置で直前の有効候補を誤保存しないようdraftを原状復帰する。README/設計/AGENTSも更新。
- ImageEditorTests.swiftにAppKitイベントの回帰テストを追加。段移動の時刻/演出保持、保存前プレビュー、衝突拒否、Esc/範囲外取消、端トリムを検証。全26テスト成功（/tmp/my_movie-layer-drag-test.log）。git diff --check成功。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-layer-drag-build.log）。実行中の処理/障害なし。次: app再起動後に画像クリップ本体を別の行へドラッグして段移動する。実GUIでの段移動は未検証、AppKitイベントの自動テストで確認済み。

## 画像タイムライン実装（完了）

- 承認済み設計を実装。ImageTrack.swift（3段/素材/配置/置換/削除/スナップ検証）、ImageAssetStore.swift（非同期・上限付き画像キャッシュ）、ImageEditor.swift、ImageAssetManager.swift、PlacementEditor.swiftを追加。
- 共通TimelineView.swiftへ歌詞/画像モード、歌詞ゴースト、3段ドラッグ/端トリム、外部ファイルドロップを接続。LyricSnapGridをTimelineSnapGridへ改名。
- ProjectFile version 3、単一image/pulse経路を除去。画像ごとの拍拡大、共通SceneRenderer、VideoExporterの各フレームの有効画像読込、AppのUI/保存/プレビューへ接続。
- 新規ImageTrackTests/ImageEditorTestsを追加し全25テスト成功（/tmp/my_movie-images-test-full.log）。素材置換/欠損復旧/未配置保持/衝突拒否/ドロップ座標/IME等既存操作/タブ不正入力拒否を検証。実MP4で上段画像の表示区間・1080p/30fps・音声/歌詞・画像ゼロ出力を確認。
- 整理: 単一画像/pulse経路を除去、非同期処理の世代確認、素材キャッシュ/プレビュー照合キー/入力終了の責務を整理。README/設計書/AGENTSを現仕様へ更新。プログラムによる画面PNGを目視確認（/tmp/my_movie-images-app.png、-editor.png、-manager.png、-timeline.png）。
- 初回リリースapp生成成功（/tmp/my_movie-images-release.log）。別bundle IDの/tmp/MV Images Check.appで合成素材のv3プロジェクトを起動し、画像3段/歌詞ゴースト/画像管理のサムネイル・使用箇所/歌詞タブ切替をCUAで確認、検証用アプリ終了済み。
- 最終整理: アクセシビリティのモード表記と削除素材のサムネイル解放を追加。最終全25テスト成功（/tmp/my_movie-images-test-final.log）、BPM変更で既存配置が変わらないことも確認。git diff --checkと文書リンク確認成功。
- AppKitのdraggingEntered→prepareForDragOperation→performDragOperation経路もテスト済み。最終全25テスト成功（/tmp/my_movie-images-test-final.log）。./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-images-release-final.log）。git diff --check成功。
- 実行中の処理/障害なし。次: 最新appを再起動し、音声読込→画像・演出タブ→画像配置/画像管理を利用する。保存形式はversion 3、version 2からの自動移行なし。大規模な素材数/長時間動画の性能は未計測。

## 画像ドロップと画像管理の追加設計

- ユーザー要件: ボタンに加えて「画像・演出」タイムラインへのドロップで読込。管理画面で画像を削除/置換し、欠損画像も置換できること。
- docs/IMAGE_TIMELINE.mdに外部ファイルドロップ（行/横座標から配置、16分音符スナップ、読込と配置の一括確定）と画像管理画面（一覧/使用箇所/未配置登録/削除/置換/欠損復旧）を追加。
- 管理画面の素材置換は全使用クリップへ反映、配置インスペクターの差替は選択クリップのみ。使用中素材削除は関連配置の削除確認を行い、元ファイルは残す。
- 整理フェーズ: 未参照素材の自動整理案を廃止し、未配置素材を保存/復元する設計へ統一。素材削除/配置削除、全体置換/個別差替、登録済み素材への統合、非同期キャッシュの世代管理を区別。実装対象と受入条件も更新。
- README/docs/TIMELINE.md/docs/ARCHITECTURE.mdからの概要参照とAGENTS.mdの知見を更新。
- git diff --check成功、文書のローカルリンク存在確認成功。文書のみの変更のためテスト再実行・app再生成は不要。実行中処理/障害なし。
- 次: 実装指示後はImageTrackの素材登録/削除/置換と配置の一括変更を先に実装し、共通読込経路へボタン・ドロップ・管理画面を接続する。

## 画像レイヤーと配置モードの設計

- ユーザー要件: 「歌詞」「画像・演出」のタブ切替、画像最大3レイヤー、使用画像/開始/終了の指定、画像編集時に歌詞を背面の薄いゴーストとして表示。
- docs/IMAGE_TIMELINE.mdを新規作成。ユーザー指定と提案を区別し、3段それぞれの複数クリップ、同段重なり禁止/別段重なり許可、上段ほど前面、読取専用ゴースト、共通時間軸、選択/入力/ドラッグ中のモード切替を具体化。
- 配置/移動/端トリム/段移動/16分音符スナップ、既存拍拡大のクリップ単位設定、素材管理、欠損時対応、version 3、プレビュー/1080p出力、変更ファイル、実装順と受入条件を記載。
- 整理フェーズ: 今回の初期範囲と将来演出を分離。単一画像経路の廃止方針、歌詞連結を画像へ持ち込まない責務分担、ゴーストの表示/ヒットテスト、モード切替と映像合成の独立性を確認。
- README.md、docs/TIMELINE.md、docs/ARCHITECTURE.mdから新設計を参照。AGENTS.mdに未実装であることと要件/提案の区別を追記。
- git diff --check成功、変更文書のローカルリンクの存在確認成功。コード変更なしのためテスト再実行・app再生成は不要。既存コード変更は前回までの作業として保持。
- 実行中処理・障害なし。次の具体手順: 実装指示があればImageTrackのモデル/検証/保存から開始し、共通描画→タブ/タイムライン→ゴーストの順で接続する。各段階で検証/整理し、最終app生成。

## 1080p動画出力

- 要件: 1920×1080（1080p）で動画を書き出せるようにする。
- VideoExporter.swiftの出力を1920×1080/30fpsへ統一。映像生成時の目標ビットレートを12Mbpsへ設定。音声結合/共通描画は既存経路を利用。
- 整理フェーズ: 出力幅・高さ・fps・ビットレートをVideoExporterの定数へ集約し、App.swiftのUI案内も同じ定数から生成。歌詞縁取りの720p基準は見た目の倍率基準として維持。
- StudioTests.swiftで実MP4の生成・再読込による1920×1080のフレーム/トラック、30fps、音声/長さ、歌詞縁取りを検証。全18テスト成功（/tmp/my_movie-1080p-test.log）。README/docs/ARCHITECTURE.md/AGENTS更新。git diff --check成功。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-1080p-build.log）。実行中の処理・障害なし。次: app再起動後に「MP4を書き出す」で1080p動画を生成する。実GUIからの書出しは未検証、出力処理は実動画で検証済み。

## Command+Spaceへの変更

- 要件: 入力中も使う再生切替をControl+SpaceからCommand+Spaceへ変更。
- StudioWindow.swiftの修飾キー条件/変数名、KeyboardTests.swift、README、AGENTSを現仕様へ統一。
- 整理フェーズ: 旧ショートカットの条件を残さず、通常Spaceとの共通処理とリピート抑制を維持。
- 関連17テスト成功（/tmp/my_movie-command-space-test.log、メディア出力は変更外のため除外）。git diff --check成功。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-command-space-build.log）。実行中の処理・障害なし。次: app再起動後にCommand+Spaceを利用。OS側が同じキーを消費する場合はOS側の割当変更が必要と案内済み。実GUIでのキー操作は未検証。

## 入力中のControl+Space再生切替

- 要件: 文字入力中でもControl+Spaceで再生・一時停止。
- StudioWindow.swiftでControlのみ併用したSpaceを入力判定より優先して扱う。既存の再生コールバックへ集約し、通常Space・Esc・モーダル時の処理を維持。
- 整理フェーズ: 修飾キー判定を一度にまとめ、通常SpaceとControl+Spaceの発火/長押し抑制を共通化。入力確定/フォーカス変更は行わない。
- KeyboardTests.swift更新: 日本語変換中の本文・選択・フォーカス保持、数値field editor保持、非入力時Control+Space、長押し抑制を検証。
- 関連17テスト成功（/tmp/my_movie-control-space-test.log、メディア出力は変更外のため除外）。README/AGENTS更新。git diff --check成功。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-control-space-build.log）。実行中の処理・障害なし。次: appを再起動して入力中のControl+Spaceを利用する。実GUIでのキー操作は未検証。

## 拡大タイムライン表示範囲の保存

- 要件: 拡大タイムラインの「表示範囲」値を設定として保存。
- UI設定のためプロジェクトではなくアプリ共通UserDefaultsへ保存。起動時に復元し、曲切替でも維持。
- TimelineDisplaySettings.swift追加: timelineVisibleSpanキー、2〜30秒、初期12秒。不正値は保存せず、読込時は初期値へ戻す。
- LyricsEditor.swift: visibleSpanと変更通知を追加しスライダー/ラベル/描画を同期。App.swiftで起動時復元・操作時保存を接続。LyricsTimelineView.swiftの初期値も共通化。
- 整理フェーズ: 範囲と初期値を専用型へ集約。復元とユーザー操作通知を分離し、復元時の不要な保存を抑制。
- TimelineDisplaySettingsTests.swiftで設定往復、UI復元、曲切替維持、復元時の通知抑制、不正値を検証。関連17テスト成功（/tmp/my_movie-display-settings-test.log、動画出力テストは変更外のため除外）。README/docs/TIMELINE.md/AGENTS更新。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-display-settings-build.log）。git diff --check成功。実行中の処理・未解決障害なし。次: app再起動後に表示範囲を変更し、次の起動でも同じ値で表示されることを利用する。実GUIでの再起動検証は未実施。

## Space再生切替とEsc入力終了

- 要件: 文字入力中以外はSpaceで再生/停止、文字入力中はEscで入力フォーカス解除。
- StudioWindow.swift追加、App.swiftのメインウィンドウに採用。再生ボタンと同じtogglePlayへ接続し、音声未読込/処理中の無効状態を共有。
- 入力中判定はeditable NSTextView（数値欄のfield editorも含む）。EscはunmarkText後にmakeFirstResponder(nil)で通常の入力終了・保存経路を使用。Space入力、シート/モーダル、修飾キー、既存タイムラインのEsc取消を維持。
- 整理フェーズ: キー処理をウィンドウに集約し、個々の入力欄/タイムラインへの重複実装やイベントモニターを不要とした。
- KeyboardTests.swift: 通常Space、長押し、本文への空白挿入、日本語変換中Esc、数値field editor解除、解除後Spaceを実イベントで検証。
- メディア出力以外の16テスト成功（/tmp/my_movie-keyboard-test.log）。README/AGENTS更新。git diff --check成功。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-keyboard-build.log）。実行中の処理・未解決の障害なし。次: appを再起動し、Space再生と入力欄でのEscを利用する。実音声を使ったGUIでのキー操作は未検証。

## 現在位置からの区間指定ボタンの削除

- ユーザー要件: タイムラインで調整できるため「現在位置を開始に」「現在位置を終了に」を削除。
- LyricsEditor.swiftから2ボタン・専用アクション・取込処理を削除。整理フェーズで不要なコンテナも廃止し、連結チェックを詳細欄へ直接配置。
- onCapturePlaybackTimeは新規追加とドラッグ開始の一時停止に必要なため保持。
- LyricsEditorTests.swiftの削除機能専用テストを除去し、LyricSnapTests.swiftは新規追加のスナップ検証へ整理。README、docs/TIMELINE.md、AGENTS.mdを現仕様へ更新。
- 動画出力以外の15テスト成功（/tmp/my_movie-remove-capture-test.log）。今回の変更に無関係なメディア出力テストは除外。git diff --check成功。
- ./scripts/build-app.sh成功、最新dist/MV Studio.app生成済み（/tmp/my_movie-remove-capture-build.log）。実行中の処理・未解決の障害なし。次の手順: appを再起動してタイムラインから区間を調整する。

## 16分音符スナップ（完了）

- 最終更新: 2026-11-08 23:42 JST。ユーザー要件: BPMに合わせ歌詞テロップの位置を16分音符単位に揃え、新規作成にも適用する。
- LyricSnapGrid.swiftを追加し、15/BPM秒・拍開始原点で最近傍/許容範囲内のグリッド点を計算。フレーム丸めを廃止。
- LyricsChaining.swift、LyricsTimelineView.swift、LyricsEditor.swift、App.swiftに接続。新規開始/終了、ドラッグ、現在位置取込、時刻入力に適用。BPM変更/復元を同期し、既存配置は保持。
- 連結追加は親の終了を維持。本体移動/後続追従の長さも保持。ドラッグは境界内の点へ制限し、点がない場合は反映しない。
- 整理フェーズ: グリッド計算を専用型へ集約、入力欄の編集中の表示維持と編集終了時の確定時刻表示を分離。README、docs/TIMELINE.md、AGENTS.mdを更新。
- LyricSnapTests.swiftで非整数BPM・非ゼロ拍開始・新規/連結/ドラッグ/曲末/UI取込を検証。TimelineTests.swiftの最小長期待値をスナップ仕様へ更新。
- 全17テスト成功: /tmp/my_movie-snap-test-full.log。制限環境の動画出力失敗は権限のある実行で解消。
- ./scripts/build-app.sh成功: /tmp/my_movie-snap-release.log。制限環境のdsymutil失敗は権限のある実行で解消。最新dist/MV Studio.app生成済み。git diff --check成功。
- 実行中の処理なし。今回の実音声によるGUI操作は未検証。次の手順: 最新appを再起動し、BPM/拍開始を設定して新規追加と端ドラッグを確認する。

## 目的・ユーザーの要件

- Swift＋AppKitで画像と音声からMVを作るツールを実装する。
- 拍に同期したアニメーションと帯域ごとの可視化を簡単に利用できること。
- 今回は設計を基に機能を絞ったツールを作成する。
- コード修正後は追加指示なしで起動用appを生成する。

## 拡大タイムラインとドラッグ編集

- 要件: 既存シークバーとは別に、再生位置近くを拡大し、テロップの開始/終了と現在位置を表示、マウスドラッグで調整する。
- `TimelineGeometry.swift`: 再生位置中心の表示範囲、曲頭/曲末制限、座標/時間変換、ミリ秒の時刻ラベル。
- `LyricsTimelineView.swift`: ピンクの再生ヘッド、テロップ区間・連結表示、選択、本体移動/左右端トリム、空白/目盛りでのシーク、ドラッグ中の座標固定とプレビュー、mouseUp確定、Esc取消。
- `LyricsChaining.swift`: dragging操作を追加。1/30秒単位、曲頭/曲末/隣の独立区間/最小長で制限し、後続の連結列を追従。開始端変更は終了固定、本体移動は長さ固定。
- `LyricsEditor.swift`, `App.swift`: 2〜30秒の表示範囲調整（初期12秒）、一覧/本文と選択を同期、仮描画と保存の分離、終了前の仮編集取消。既存全曲シークバーは残す。
- 整理フェーズ: 座標計算・モデル編集・NSView入力/描画を分離。確定操作は既存の検証/自動保存経路へ集約し、書出しコードは共通モデルを引き続き利用。
- `TimelineTests.swift`: 座標往復と範囲追従、連結移動、両端トリムと境界制限、実AppKitイベントによるドラッグ中の仮反映/一度の確定/Esc取消を検証。
- 全14テスト成功（`/tmp/my_movie-timeline-test.log`）。描画画像 `/tmp/my_movie-timeline-preview.png` を目視確認。
- releaseビルド成功（`/tmp/my_movie-timeline-release.log`）。`dist/MV Studio.app`更新済み。`git diff --check`成功。
- 別bundle IDの `/tmp/MV Timeline Check.app` を起動し、全体UIでシークバーと拡大タイムラインが別表示されることを確認。GUI操作中にユーザー操作による状態変更を検知したため、それ以上の操作は停止。ドラッグ自体は自動テストで検証。
- 実行中のビルド/テストなし。波形、拍スナップ、Undo、ドラッグ中の自動スクロールは未実装。

## テロップの連結追加・追従

- 要件: 再生位置がテロップに重なる場合は末尾に連結して追加し、直前の位置変更に追従。空白なら再生位置から独立して追加。
- `Lyrics.swift`: optional predecessorIDを保存し、直前のID/終了との一致を検証。
- `LyricsChaining.swift`: 連結列末尾への追加、開始移動/終了変更時の長さを保った後続追従、連結ON/OFF、削除時の直後独立化。独立クリップとの重なりや曲末超過は反映前に拒否。
- `LyricsEditor.swift`: 連結チェックと一覧の↳表示。追加時は音声の現在位置を取得し、新規歌詞へシーク。開始の直接変更は連結解除と長さ維持移動。入力精度を保つ時刻表示へ変更。
- `LyricsChainingTests.swift`: 多段追従、空白/区間境界での独立追加、切断・再連結、削除、衝突/曲末超過、不正参照、保存復元後の追従。既存UIテストも開始移動の仕様に更新。
- 整理フェーズで連結ルールをUIからモデル操作へ分離し、一括検証・反映に統一。README、設計、AGENTSを更新。
- 全11テスト成功（`/tmp/my_movie-chain-test.log`）。releaseビルド成功（`/tmp/my_movie-chain-release.log`）。`dist/MV Studio.app`更新済み。`git diff --check`成功。実行中の処理なし。
- GUIでの実音声を使った連結操作は今回未検証。

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

- 更新した `dist/MV Studio.app` を再起動し、全曲シークバーで位置を合わせ、拡大タイムラインの本体・端をドラッグしてタイミングを調整する。
- tickモデル、Undo、枠超過警告は今後の実装対象。現状の本文は枠に入り切らない場合に末尾が表示されないため、短いフレーズを使う。
- 旧version 1プロジェクトの設定自動移行は未対応。新規作成時の別名バックアップを利用する。
