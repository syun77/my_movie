# Spine初期実装設計：atlas・移動/回転・凸形/凹形マスク

更新: 2026-11-14。状態: A〜Dの初期機能を実装。検証結果は末尾。

ユーザー指定の最初の目標を、atlas化されたテクスチャの読み込み、単純な移動・回転アニメーション、凸形・凹形のポリゴンマスクとする。以下の方式・既定値・検証順は設計判断であり、動作確認済みの実装ではない。全体構想は [SPINE_TIMELINE.md](SPINE_TIMELINE.md) に残し、本書を最初の実装範囲と優先順位の基準とする。

## 1. 初期段階の到達点

提供されたJSON・atlas・PNGを参照してキャラクターを復元し、アニメーションを1つ選んで再生・停止・任意時刻へシークできるようにする。凸形の目のマスクと凹形の首マスクを、変形に追従させながら正しく描く。専用の小規模検証画面から始め、描画経路が合格した後で既存タイムラインへ接続する。

初期検証は物理OFF・速度1倍・default skin・normal blendとする。単純なアニメーションの評価に公式ランタイムを使い、JSON補間やatlasパーサーを独自に再実装しない。マスクの分割・クリッピングも公式処理を使う。公式ランタイムの機能が利用できても、初期UIの機能を増やす理由にはしない。

| 初期に必要 | 後段へ送る |
| --- | --- |
| Spine 4.3 JSON、atlas、PNGページの参照・検証 | .skelの入力UIと受入試験 |
| atlasの回転・trim・元画像寸法・PMA・Linearフィルター | 特殊blendとtint blackの描画対応 |
| region、ウェイト付きmeshの描画、親子ボーン変換 | メッシュのdeformキー、IK/path/その他制約を使うモデルの受入試験 |
| translate/translatex/translatey、rotate、linear/stepped/Bezier補間 | モデル内部の編集、複数アニメーション混合 |
| ウェイト付き/なしの凸形・凹形clipping | マスク形状編集、ソフトマスク、穴・反転マスク・自己交差ポリゴン |
| 単一アニメーション選択、再生/停止/シーク、ループ/終端保持 | 物理ON、速度編集、共通追加演出との全組合せ検証 |

セットアップポーズのscale/shear・継承方式は公式ボーン変換へ渡す。移動/回転だけに絞るためにセットアップ値まで捨てない。初期対象外の描画機能が選択skin/animationに必要なら、素材名と機能を示して拒否する。特殊blendをnormalへ置き換えるなどの黙った近似はしない。

## 2. 提供サンプルの確認結果

入力は `testdata-blink-v2-neck-merged.json`、`spine.atlas`、`spine.png`。ユーザー提供の原本は参照だけとし、再出力・修正・リポジトリへのコピーは行っていない。JSON内の文字列やメタデータは素材データとして扱う。

| 項目 | 静的調査結果 |
| --- | --- |
| export version | 4.3.26 |
| 構造 | 15 bones、66 slots、default skin 1つ |
| attachments | region 32、mesh 9、clipping 25 |
| メッシュ | 9個すべてweighted、論理頂点合計13,554 |
| 目のマスク | 左右各12個、各4頂点、weighted、convex:true |
| 首のマスク | neck_clip、9頂点、unweighted、凹形、end=head |
| atlas | PNG 1ページ、1701×1776、10 regions、Linear/Linear、pma:true |
| region配置 | rotate:90とtrim offsetsあり。元画像寸法は主に1671/1672×941 |
| blend | 全66 slotsがnormal（省略時の既定値を含む） |
| アニメーション | blink_natural / hair_sway / idle_natural_blink / idle_sway。すべて最終キー4秒 |
| timeline | bonesのtranslatey・rotate。サンプルにdeform/物理/制約セクションなし |

首は頂点列の連続辺の外積に正負があることから凹形を確認した。目のconvex指定はファイル内の宣言であり、全アニメーション時刻の変形後形状まで検証済みという意味ではない。上表は静的解析結果。公式ランタイムによるロード・描画は実装後にも検証し、結果を末尾へ記録した。

特に目のmeshとclippingは、各頂点をボーン番号・ローカル座標・ウェイトの列で保存している。`vertices`を常にXYペアと解釈すると破綻する。目の頂点はupper/lower lidなど複数ボーンで動くため、初期実装でも公式のweighted world vertex計算が必須となる。

JSONとatlasは同名ではない。JSONを選択後、atlasが自動発見できなければ `spine.atlas` を明示選択できるようにする。JSONのimages/audioパスは制作情報であり、atlas読込の代わりにpartsフォルダを要求したり、素材内音声を再生したりしない。

## 3. 責務とデータの流れ

```text
JSON + atlas + PNG
  → SpineAssetLoader（依存検証・revision・ページ情報）
  → SpineRuntime / SpineBridge（4.3の検証コミットに固定）
  → SpinePoseProvider（skin + animation + 要求時刻、物理OFF）
  → 公式SkeletonRenderer / clipping（world vertices、凹形分割、UV補間）
  → SpineDrawPacket（Swift所有の頂点/index/順序付きコマンド）
  → SpineMetalRenderer（透明中間面へnormal描画）
  → 検証画面、後にMetalSceneRendererの既存段合成
```

- SpineAssetLoader: skeleton/atlasの内容とPNGを一式として検証し、全成功時だけ公開する。PNG寸法とatlas寸法、region参照を検査。パスのフォルダ外参照や壊れた画像を拒否する。
- SpineRuntime/Bridge: C++所有・エラー変換・TextureLoaderのページID対応を担当。Swiftから生ポインターを保存せず、描画packetをコピーする。
- SpinePoseProvider: 専用直列ワーカー上でassetとinstanceを所有。skin/animationごとのセットアップ状態から任意時刻を評価し、前回の表示順やattachment選択を残さない。
- SpineDrawPacket: asset revision、評価時刻、world-space bounds、ページID、Float座標/UV/RGBA、UInt32 index、index範囲を持つコマンド列。不正index・非有限値・予算超過をMetalへ渡す前に検査する。
- SpineMetalRenderer: ページtexture/samplerの管理と三角形描画。クリッピング済みコマンドを受け取り、独自マスクの形状判断はしない。コマンド順を保つ。

ランタイム所有ポインターをactor境界へ渡さず、GPU完了までpacket・ページtexture・中間面を保持する。複数ページにも対応できるページID方式とするが、最初の確認は提供された1ページで行う。

## 4. atlasの復元規則

atlas全体をTextureLoaderで読み、各regionはUVで参照する。regionごとのCGImage切出しと再パックは行わない。

1. ページPNGを一度デコードし、atlasが指定するPMA属性と寸法を保持する。PNGの見た目が黒いかどうかで透過方式を推測しない。
2. `bounds`はパックされた領域、`rotate`は格納時の回転、`offsets`はtrim前の元画像内配置として公式ランタイムへ渡す。
3. attachmentのwidth/height・ローカル変換とregionの元寸法から四隅を復元する。trim後の711×370などを、そのまま元の1671×941へ引き伸ばさない。
4. regionの回転補正とSpine Y上向き→映像Y下向きの変換は責務を分け、それぞれ1回だけ行う。回転regionのUVを独自に二重補正しない。
5. pageのfilter/wrap指定からsamplerを作る。省略値は公式atlas解釈に従い、sampleごとに独自既定値を変えない。

初期の描画はnormalだけを保証する。色処理は全体設計12.4の線形PMA方式を使い、ページがPMAの場合は符号値上でPMA解除→線形化→再PMAの順を守る。透明・白・黒・市松背景で境界を比較し、GPU upload時の追加PMA処理がないことを確認する。

## 5. 移動・回転と任意時刻評価

単一の選択アニメーションを、親子ボーン変換を含めて公式APIで評価する。ボーンの移動/回転は素材内部、共通クリップの移動/回転は素材全体に対する外側の変換とする。

検証画面では0〜D秒の時刻、再生/停止、ループ、アニメーション選択を表示する。数値時刻はDragValueFieldを使う。ループ時はt mod D、非ループはmin(t,D)、D=0は0。物理OFFで要求時刻を直接評価し、固定ステップへの量子化は行わない。linear/stepped/Bezierは公式補間を使う。30fpsの入力キーでも中間時刻を評価できることを確認する。

毎回同じ基準から評価し、hair_swayからblink_naturalへ切り替えた際に髪の回転が残らないようにする。アニメーション選択変更では検証画面の時刻を0に戻す。初期確認はblink_natural→hair_sway→idle_natural_blinkの順とし、アニメーション名をコードへ固定しない。

本体統合後は主音声時刻tとクリップ開始sから `u=sourceIn+(t-s)` を計算する。検証画面の時計をアプリ再生時計へ持ち込まない。外側のクリップ操作・キー・保存は既存の経路へ接続する。

## 6. 凸形・凹形マスク

マスクはSpineのclipping attachmentの「ポリゴン内側だけを表示する」意味とする。凹形は輪郭がへこんだ単純ポリゴンであり、穴あきや外側を残す反転マスクとは区別する。

公式の描画/クリッピング処理に次を委ねる。

1. 描画順でclipping attachmentに到達したら、現在ポーズからworld verticesを計算してクリッピングを開始する。weighted頂点もこの段階で評価する。
2. 凹形は公式の分割処理へ渡す。全頂点を扇形に結ぶ方式や凸包への置換は使わない。convexフラグだけに依存した独自高速化も初期には追加しない。
3. 続くregion/meshの三角形を切り、交点のUVを補間する。マスク後にテクスチャを貼り直して伸縮させない。
4. end slotの描画を含めて適用し、そのslotの処理後に解除する。描画対象が空のslotでも終了判定を省略しない。
5. skeleton終了時にも解除し、次フレーム・次クリップ・次レイヤーへ状態を持ち越さない。

マスク形状をPNGやCIImageへ焼く方式、slotごとのMetal stencil管理は初期には不要。CPU側でクリッピング済み三角形を生成し、Metalでは通常のtexture付き三角形として描く。複数マスクの独自ネスト規則を追加せず公式仕様へ従う。

サンプルではneck_clip→headで首の切り抜きを終了し、その後の目や髪へ影響させない。目はclip_N→interior_Nの組を順番に処理し、まぶた等の後続meshへマスクを漏らさない。マスク自身のcolorは編集表示用であり映像にポリゴン色を描かない。

初期はMSAAなしの共通描画で正確性を確認する。切断辺のエイリアスは別項目として記録し、形状漏れと区別する。必要な場合は中間面のMSAA化を評価してから採用する。

## 7. 実装・検証の順序

| 段階 | 実装内容 | 合格条件 |
| --- | --- | --- |
| A 読込・静止表示 | 4.3固定、C境界、atlas/PNG、region/weighted mesh、normal | 提供モデルのsetup poseを復元。回転・trim・PMAに破綻がない。マスク未接続の表示は診断用と明記 |
| B 移動・回転 | 任意時刻、親子変換、単一アニメーション、切替 | blink/hair/idleが動く。順再生とランダムシークの同時刻で頂点一致、切替後に残留なし |
| C マスク | weighted凸形・unweighted凹形、終了slot、UV補間 | 目24個と首1個の境界、瞬き、首の凹部、後続slotへの解除が正しい |
| D 本体接続 | 3段配置、主音声同期、同じ描画でMP4、参照保存/Undo/コピー | 同じ時刻でプレビュー/出力が一致。欠損/取消/再読込時に古い結果を採用しない |

最初の技術検証の完了はA〜C。ユーザーが通常の制作で使える初期機能の完了はDまでとする。Dでは物理UIと速度編集を公開せず、内部値はphysicsEnabled=false・speed=1に固定する。後段機能を先に追加してA〜Cの合否を遅らせない。

初期段階はSPINE_TIMELINE.mdのG1と、normal/atlas/region/weighted mesh/clipに絞ったG2、物理OFFのG3を必須とする。物理ON・全blend・16倍性能を含むG4は後段の条件であり、A〜Cの前提にしない。Dでは通常モデルで3段1080p/30fpsの負荷とメモリを測定する。保存形式は本体へ接続するDでversion 8へ更新し、検証画面だけの段階でプロジェクト形式を変更しない。

## 8. 受入試験と観測項目

提供データに加えて、最小fixture（矩形/凹形L字、非対称の目印入りatlas、親子2ボーン）を用意する。提供PNGを改変せず、fixtureは別素材として作る。

- atlas: 90度回転、trim offsets、全10 region参照、PMA境界、別名atlas、ページ欠損、寸法不一致。後に2ページfixtureでページ切替を確認する。
- 動き: 0/4秒、瞬きの1.533333〜1.866667秒、キー中間時刻、回転の正負、親ボーンの移動/回転、アニメーション変更、後方シーク、ループ境界を確認する。
- マスク: 目の開/閉/途中、首の凹部、weighted頂点の移動、end slot自体の切断、end後の無関係なslot、空end slot、フレーム間の状態初期化を確認する。
- 形状: 凸形と凹形fixtureで内部/外部のピクセルを検査する。凹部が塗られないことと、クリッピング後の画像の目印がずれないことを確認する。
- 負荷: 切断前後の頂点/三角形数、CPUのpose/clip時間、GPU描画時間、CPU/GPUメモリを測定する。元モデルの13,554頂点だけで予算を見積もらない。
- 比較: 同一モデル/skin/animation/時刻で公式ランタイムに準拠した参照描画と比較する。参照画像を入手するまで「Spine Editorと一致」は未検証と記録する。

自己交差・退化形状・不正indexは、NaNや無限の領域をGPUへ渡さないことを確認する。公式処理の許容範囲外を独自補正して描かず、対象素材の検証エラーとして報告する。中間面は固定基準矩形を原点とし、はみ出しで中心を動かさない。

A〜C後に、world vertices/UV/clipをSwift側で重複計算していないか、C handleとGPUの所有が明確か、例外/取消が統一されているかを整理する。D後にもモデル・保存・呼出元を整理し、必要な回帰検証と最終のbuild-app.shを実行する。

## 9. 公式根拠

- [spine-cpp](https://esotericsoftware.com/spine-cpp): 読込、TextureLoader、ポーズと順序付き描画コマンド。
- [clipping attachments](https://esotericsoftware.com/spine-clipping): ウェイトによる変形、end slotを含む適用範囲、自己交差と性能。
- [4.3 API reference](https://esotericsoftware.com/spine-api-reference): weighted world vertices、ポーズ、物理OFF、ランタイム型。

提供JSONは4.3.26のため、一般JSON説明ページの別バージョン例ではなく、固定した4.3ランタイムのパーサー/描画処理を最終根拠にする。

## 10. 初期実装と確認状況

公式spine-cppは405f43295b5832e86d9df3a80beb6bc9df772312へ固定した。独立した検証画面の代わりにSpineTestsの最小fixtureと描画PNGを検証台として使用し、本体のインスペクターへ直接接続した。アニメーション・ループ・素材開始は本体で編集する。初期範囲では再評価ごとにsetup poseへ戻せるため、同一assetのSkeletonをproviderの直列環境内で再利用する。プレビュー/出力のproviderは独立し、物理状態は共有しない。

SpineAsset.swiftが保存型/packet、SpinePoseProvider.swiftが依存ロード・JSON事前検証・公式評価、SpineMetalRenderer.swiftがGPU描画を担当する。SwiftPMでC++17を指定し、ライセンスをappへコピーする。ページbytes・revisionを保持し、出力準備後は使用素材をLRUから追い出さず、予算超過で開始を拒否する。外部更新は素材管理の「再読込」で反映する。

初期UI/形式はdefault skinのみ、速度1倍、物理OFF、JSON入力。SpinePlaybackの実保存フィールドはanimationName/sourceIn/loop。速度・skin・physicsの編集と永続化は後段。基準矩形とanimation一覧はdescriptorへ保存し、実ファイルは読込時に検証する。共通変形・演出の経路は使用するが、後段を含む全組合せを検証済みとは扱わない。

提供モデルを読み、開眼/瞬きの描画PNGと3段1080p合成を目視確認した。SpineTestsで凹形L字の切断面積・内部/凹部/終了後のピクセル、ランダムシーク、保存/トリム、UI/履歴、MP4の全31フレームPTS・プレビュー比較・取消時の既存出力保持を確認する。提供モデルの試験は `MV_SPINE_SAMPLE_DIR` で任意実行する。Spine Editorからの参照画像は未提供のため、Editorとの厳密な画像一致は未検証。

arm64の開発ビルドで提供モデル3段・1080pの9時刻を測定し、CPU評価最大約16ms、GPU最大約6msだった。連続30fpsや他機種の性能保証を示す値ではない。物理ON・16倍・全blendのG4は未実施。最低対応macOS 14を指定しているが、実行検証は現在の開発Macのみ。

最終回帰検証は全90テスト成功（SpineTests 6件を含む）。GPU・AppKit・メディアサービスへアクセスできる環境で実施した。

アニメーションの切替/ポーズブレンドのオートメーションは [SPINE_AUTOMATION.md](SPINE_AUTOMATION.md) として追加実装済み。現在の保存形式はversion 9で、SpinePlaybackは再生モード・専用キーを含む。上記の初期単一再生はsingleモードとして維持する。
