# ABTrackPTPad

[English README](README.en.md)

Amazon Basics TK053(Windows Precision Touchpad 準拠の Bluetooth トラックパッド。公式には macOS 非対応)を、
macOS でマルチタッチジェスチャ付きトラックパッドとして使うためのメニューバー常駐アプリです。

- 動作確認環境: macOS 26.5 / Apple Silicon
- 対象デバイス: `amazonbasics_touchpad`(VID `0x248A` / PID `0x8208`)
- 配布形態: ソースのみ(自分でビルド)。Apple の署名・公証はしていません

## できること

| 操作 | 動作 |
|---|---|
| 1 本指 | カーソル移動 |
| 1 本指タップ / 物理クリック | 左クリック |
| タップ → すぐ押さえて移動 | ドラッグ |
| 2 本指タップ / 2 本指で物理クリック | 右クリック |
| 2 本指スワイプ | スクロール(慣性あり) |
| 2 本指ピンチ | ズーム |
| 3 本指タップ | 中クリック |
| 3〜4 本指 上 / 下 | Mission Control / App Exposé |
| 3〜4 本指 左右 | Space 切替 |

設定はすべてアプリ内で行い、**MacBook 内蔵トラックパッドの設定とは独立**しています。

## インストール

必要なもの: Xcode Command Line Tools(Xcode 本体は不要)

```sh
xcode-select --install                          # 未導入の場合
git clone https://github.com/knkz1114/ABTrackPTPad.git
cd ABTrackPTPad
./make-signing-cert.sh                          # 自己署名のコード署名証明書を作成(初回のみ、後述)
CODESIGN_IDENTITY=ABTrackPTPad-dev ./install.sh # ビルド → /Applications/ABTrackPTPad.app → 起動
```

`./install.sh` だけでも動きますが(ad-hoc 署名)、その場合は再ビルドのたびに権限の付け直しが必要になります。

### 権限の許可(初回)

起動するとアプリが **アクセシビリティ** を要求します。
システム設定 > プライバシーとセキュリティ > アクセシビリティ で `ABTrackPTPad` を ON にしてください。
「入力監視」にはアプリが表示されないことがありますが、アクセシビリティの許可で HID へのアクセスも認められます。

macOS は起動中のプロセスに後から付けた権限を反映しないため、アプリは許可を検知すると自動で再起動します。

### トラックパッドの接続

1. アプリを起動しておく
2. トラックパッドの電源を **OFF → ON**(または Bluetooth を切断 → 再接続)
3. 接続後すぐにパッドをなぞる

パッドは接続直後の数秒間だけ PTP モードへの切り替えを受け付けるようです。アプリは接続を検知した瞬間に切り替えを行い、
切り替わらない場合は 2 秒ごとに最大 10 回やり直しますが、アプリを後から起動した場合は電源を入れ直してください。

メニューバーのアイコンが塗りつぶしの手になり、「権限」タブが「PTP モードで動作中」になれば完了です。

### アンインストール

```sh
./install.sh uninstall
```

システム設定のアクセシビリティ項目は手動で削除してください。

## 使い方

メニューバーの手のアイコン → 「設定…」で設定ウィンドウが開きます。

**ジェスチャ タブ**

- 軌跡の速さ
- タップでクリック / タップしてからドラッグ / 2 本指タップで右クリック
- ナチュラルなスクロール(指の動きに内容が追従)/ スクロールの速さ
- 3 本指スワイプの左右・上下の向き反転
- ログイン時に起動
- 言語(システムに従う / 日本語 / English)— 即時切替

変更は即時反映されます。

**権限 タブ**

- アクセシビリティ / 入力監視の許可状況、「許可を要求」「システム設定を開く」
- トラックパッドの接続状態(未接続 / マウスモード / PTP モードで動作中)、レポート受信数、HID を開けない場合のエラー
- 診断: 「生レポートを記録する」を ON にすると直近 10 秒の生 HID レポートをメモリに保持し、「診断ログを保存」で `~/Downloads/ABTrackPTPad-diag-<日時>.log` に書き出します(既定は OFF)

アプリのログは `~/Library/Logs/ABTrackPTPad.log` にあります。

## 再ビルドと署名について

macOS の権限(TCC)はアプリの署名に紐づきます。ad-hoc 署名はビルドごとに変わるため、
**再ビルドすると別のアプリとみなされ、権限を付け直す必要があります**。

`make-signing-cert.sh` はログインキーチェーンに自己署名のコード署名証明書 `ABTrackPTPad-dev` を作ります。
これで署名すると署名が固定され、再ビルドしても権限が維持されます。

```sh
./make-signing-cert.sh                            # 初回のみ
CODESIGN_IDENTITY=ABTrackPTPad-dev ./install.sh   # 以後のビルド・インストール
```

証明書はこの Mac の中だけで有効です(配布用の署名ではありません)。

## トラブルシューティング

| 症状 | 確認すること |
|---|---|
| カーソルが動かない | 「権限」タブでアクセシビリティが許可済みか。`IOHIDManagerOpen failed: 0xe00002e2` は未許可 |
| 許可したのに動かない | アプリを終了して起動し直す(通常は自動で再起動します) |
| 再ビルド後に動かなくなった | ad-hoc 署名で権限が外れています。古い項目を削除して再許可するか、`CODESIGN_IDENTITY` を使う |
| 「マウスモード(PTP 切替待ち)」のまま切り替わらない | 下の Q&A を参照 |
| パッドがマウスとしても動かない | アプリ停止中にパッドが PTP モードのまま残っています。アプリを起動するか、パッドの電源を入れ直す |
| 3 本指スワイプだけ効かない | macOS のアップデートで非公開イベント形式が変わった可能性。Issue で報告してください |

### Q&A: 「権限」タブが「接続 — マウスモード(PTP 切替待ち)」のまま切り替わらない

**Q. カーソルは動くのに、2 本指スクロールやジェスチャが効かず、権限タブが「マウスモード」のままです。**

A. パッドがマウスモードで動いており、PTP モードへの切り替えが通っていません。次の順に試してください。

1. **パッドの電源を OFF → ON する**(アプリは起動したまま)。
   パッドは接続直後の数秒間しか切り替えを受け付けないため、アプリより後にパッドを接続する必要があります。
   再ペアリングした直後も同様に電源を入れ直してください。
2. それでも変わらない場合は `~/Library/Logs/ABTrackPTPad.log` を確認します。正常時は接続のたびに次の 3 行が並びます。
   ```
   read feature 4 (THQA): 0x0 len=257
   set feature 3 = 0 then 3 (PTP mode): 0x0 / 0x0
   digitizer reports active (21 bytes)
   ```
   - `read feature 4` や `set feature 3` が `0x0` 以外(例: `0xe00002e2`)→ 権限の問題です。アクセシビリティを確認してください。
   - `PTP check N: … no digitizer reports yet` が続き、`first report id=1` が出る → パッドが切り替えを無視しています。1 に戻って電源を入れ直してください。
   - `first report id` 自体が出ない → 触っていないか、パッドが別のデバイス(チャンネル)に接続しています。Bluetooth ボタンでこの Mac のチャンネルを選んでください。
3. Bluetooth の設定でパッドを削除して再ペアリングし、ペアリング完了後にもう一度電源を入れ直してください。
4. 上記で解決しない場合は、権限タブの「生レポートを記録する」を ON にして操作し、保存したログとアプリのログを添えて Issue を作成してください。

## 仕組み

- パッドの HID ディスクリプタには Report 1(マウス)と Report 2(デジタイザ、最大 4 本指の絶対座標)がある
- macOS に接続すると Report 1 しか送られてこない(マウスモード)
- 標準 PTP の Input Mode(usage 0x52)は無いが、**Feature Report 4(Windows の THQA 認証ブロブ)を読み出したうえで Feature Report 3 に 0x03 を書くと PTP モードに切り替わり Report 2 が流れ始める**
  (ファームウェアは THQA 読み出しで「PTP 対応ホスト」と判断し、Feature 3 を Input Mode として使っている。
  接続し直すとマウスモードに戻るため、接続のたびに再設定する。切り替わらない場合は 2 秒ごとに最大 10 回やり直す)
- macOS は HID デジタイザ型タッチパッドをネイティブには解釈しないため、`IOHIDManager` でデバイスを占有してレポートを自前で解釈し、
  カーソル移動・クリック・スクロール・ピンチ・DockSwipe の CGEvent を合成する
- 3〜4 本指スワイプ(DockSwipe)は macOS 26.5 では通常の CGEvent フィールドが無視されるため、
  [joshuarli/iss](https://github.com/joshuarli/iss) と同じく、シリアライズした CGEvent の field 4205 に IOHID の生ペイロードを埋め込む
- ファームウェアの Confidence ビットは信頼できない(本物の指でも 0 になる)ため無視している。レポートは 4 スロット(21 バイト)

## 構成

```
Sources/Engine/
  Settings.swift        設定(UserDefaults 連動)
  Synth.swift           CGEvent 合成(カーソル / クリック / スクロール / ピンチ / DockSwipe)
  GestureEngine.swift   PTP レポート解釈とジェスチャ判定、慣性スクロール
  HIDDevice.swift       IOHIDManager: 占有、PTP モード切替、レポート受信、権限待ちの再試行
  Diagnostics.swift     生レポートの記録と保存
  Log.swift             ~/Library/Logs/ABTrackPTPad.log
Sources/App/
  ABTrackPTPadApp.swift メニューバー UI(SwiftUI MenuBarExtra)と設定ウィンドウ
  StatusModel.swift     権限・接続状態の監視、自動再起動、ログイン時起動
  SettingsView.swift    ジェスチャ タブ
  StatusView.swift      権限 タブ
  Localization.swift    UI 文字列の切替(L("…"))
Resources/Info.plist
Resources/en.lproj, ja.lproj   UI 文字列(英語がキー。言語を足すには <lang>.lproj/Localizable.strings を追加し L10n.available に登録)
Tests/                  GestureEngine の単体テスト(./Tests/run.sh、XCTest 不要)
build.sh                swiftc だけで .app を組み立てる
install.sh              build → /Applications → 起動 / uninstall
make-signing-cert.sh    自己署名証明書の作成
```

## 開発

```sh
./Tests/run.sh                                  # エンジンのテスト
CODESIGN_IDENTITY=ABTrackPTPad-dev ./build.sh   # build/ABTrackPTPad.app
```

`GestureEngine` は `EventSink` プロトコル経由でイベントを出すので、テストでは記録用の実装に差し替えています。

## 対応デバイスについて

**動作確認済み**: Amazon Basics TK053(Bluetooth、ファームウェア 1.0.0.1)

同じ製品の別個体なら動きます。アプリが依存しているのは個体ではなくファームウェア固有の挙動
(VID/PID、HID ディスクリプタ、Feature 4 読み出し → Feature 3 書込によるモード切替、レポート形式)だからです。

ファームウェアのバージョンは次で確認できます:

```sh
system_profiler SPBluetoothDataType | grep -A4 amazonbasics
```

**認識されない場合**(権限タブが「未接続」のまま): VID/PID が違う可能性があります。

```sh
ioreg -l -r -c IOHIDDevice | grep -B2 -A6 amazonbasics | grep -E "VendorID|ProductID"
```

表示された値(10 進)が `9354` / `33288`(= `0x248A` / `0x8208`)と違う場合は、
`Sources/Engine/HIDDevice.swift` の `vendorID` / `productID` を書き換えてビルドし直してください。
違う VID/PID で動いた場合は、機種名・ファームウェアバージョンとあわせて Issue で報告してもらえると助かります。

**未検証**: 有線モデル TK054(USB-C)、他社の Telink 製 PTP パッド(Seenda、Jelly Comb 等)。
VID/PID を合わせれば同じ手順で切り替わる可能性はありますが、Feature Report 3/4 の使い方はファームウェア次第です。

## 注意

- アプリが動いていない間は、パッドが PTP モードのままだとカーソルが動きません(再接続でマウスモードに戻ります)
- 合成イベントには非公開の CGEvent フィールドを使っているため、macOS のアップデートで動かなくなる可能性があります

## 免責

このプロジェクトは Amazon、Telink、Apple とは無関係の非公式ソフトウェアです。製品名は説明のために記載しています。
本ソフトウェアは無保証です(LICENSE 参照)。

## ライセンス

MIT License。DockSwipe イベントの構築は [joshuarli/iss](https://github.com/joshuarli/iss)(ISC License)に基づいています。
詳細は `THIRD_PARTY_LICENSES.md` を参照してください。
