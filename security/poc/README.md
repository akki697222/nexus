# LPE 実証スクリプト（NV-2026-001）

Nexus 上で、一般ユーザーから root に到達する経路を確認するためのローカル検証用スクリプトです。**自分の管理下の検証イメージ以外では実行しないでください。** 実行時の挙動はまだ検証していないため、結果はイメージとビルドに依存します。

| スクリプト | 指摘 | 前提 | 期待する結果 |
| --- | --- | --- | --- |
| `nx17_shared_api_sudo.lua` | NX-17 | 非 root ユーザー、`/usr/bin/sudo.lua` が 4755 root | `sudo` が呼び出し元を root と誤認し、パスワードなしで payload を root 実行する |
| `nx16_meta_setuid.lua` | NX-16 | 非 root ユーザー、書き込み可能なホーム | 再起動後の初回アクセスで、payload が `euid 0` で実行される |
| `nx04_event_injection.lua` | NX-04 | 非 root プロセスが、root シェルが読んでいるアクティブ端末と同時に動作している | 偽のキー入力がアクティブ端末に注入され、root シェルがその行を実行する |

## 共通の前提

- 既定の `root/boot/config.lua` では `debug` ユーザー（UID 100、パスワード `debug`）が作成されます。以下ではこのアカウントを使います。
- `main.lua` は起動時に `/usr/bin/sudo.lua` を `root:root`、モード `4755` に設定します。この処理が無いイメージでは NX-17 は成立しません。
- 現状のユーザーランドには `chmod` や `vi` の実装がないため、検証イメージではスクリプトを `root/usr/bin/` に置いてビルドしてください。`main.lua` が `/usr/bin` の各ファイルを `0755` にします。

```text
# ホスト側の例
copy security/poc/nx16_meta_setuid.lua root/usr/bin/nx16_meta_setuid.lua
copy security/poc/nx17_shared_api_sudo.lua root/usr/bin/nx17_shared_api_sudo.lua
# 通常の手順でビルド・デプロイする
```

ログイン後、`debug` ユーザーで次を実行します。

## ホスト側の確認（Nexus 不要）

Nexus を起動せずに、2つの判断点だけを確認できます。実物の `sudo.lua` と `permission.lua` を使い、共有プロキシと `.meta` の解釈を模擬します。

```text
$ lua security/poc/selftest.lua
NX-04: a forged event from user code reaches the active terminal's reader
NX-16: .meta line parses and 4755 selects euid 0 (rwsr-xr-x)
NX-17: sudo executed the payload as root without a password
all host-side checks passed
```

これは実際の Nexus 上での実行ではありません。最終的な確認は検証イメージで行ってください。

## NX-17: 共有 API を差し替えて sudo を欺瞞する

```text
$ nx17_shared_api_sudo
```

スクリプトは次の順に動作します。

1. ホームに `nx17_payload.lua` を書き込む。
2. `require("process")` が返す共有プロキシに `rawset()` で `getCurrent` を追加し、常に `uid=0, euid=0` を返させる。
3. `/usr/bin/sudo.lua` を実行する。`sudo` は同じ共有プロキシから呼び出し元を取得するため、root からの実行と誤認する。
4. `sudo` は `/etc/sudoers` の `root ALL=(root) ALL` に一致させ、パスワード確認を省略し、payload を root で実行する。

期待する出力の例:

```text
nx17: overriding the shared process.getCurrent() proxy
nx17-payload: pid=... uid=0 euid=0
nx17-payload: /etc/shadow[1]=root:<hash>:...
nx17: sudo exited with status 0
nx17: if the payload printed euid=0 and a shadow line, NX-17 is confirmed
```

`euid=0` と `/etc/shadow` の内容が表示されれば、一般ユーザーから root に到達しています。

## NX-16: `.meta` を偽装して setuid 実行させる

```text
$ nx16_meta_setuid
```

スクリプトは次の順に動作します。

1. ホームに `nx16_payload.lua` を書き込む。
2. ホームの `.meta` を作り、カーネルのメタデータ同期が payload の行を書くまで待つ。
3. payload の行だけを `uid=0`、モード `4755` に書き換える。`.meta` の他の行はそのまま残す。
4. 再起動後に payload を実行するよう表示する。

```text
nx16: planted a forged entry for /home/debug/nx16_payload.lua
nx16: power-cycle the computer, log in as the same user, then run:
  /home/debug/nx16_payload.lua
```

電源を切り、同じユーザーでログインし直してから、表示されたパスを実行します。

```text
$ /home/debug/nx16_payload.lua
nx16-payload: pid=... uid=100 euid=0
nx16-payload: /etc/shadow[1]=root:<hash>:...
```

`uid=100` のまま `euid=0` になり、`/etc/shadow` を読めていれば、`.meta` を介した setuid 偽装が成立しています。再起動前に同じ payload を実行した場合は `euid=100` となり、`/etc/shadow` は拒否されるはずです（陰性対照）。

### 注意点

- `.meta` を偽装した後にホームでファイルを作成・削除すると、カーネルの同期が `.meta` を上書きし、偽装が消えます。再起動まではホームを変更しないでください。
- NX-17 はホームに payload を書くため、NX-16 の偽装を壊します。両方を試す場合は、NX-17 を先に実行し、NX-16 を最後に実行してください。
- 検証後はイメージを破棄するか、ホスト側で `nx16_payload.lua`、`nx17_payload.lua`、`.meta` を削除してください。

## NX-04: イベント配送でアクティブ端末にキー入力を注入する

一般ユーザー向けの `event` API に、カーネル内部に限定すべき `dispatch`・`setForeground`・`removeQueue` が残っています（`env.lua` で user 層から外しているのは `addHook`・`removeHook`・`markIdle` だけ）。`event.dispatch(ev)` は登録済みフックを全部呼び、tty ドライバーは `event.addHook(tty.signal)` で入力フックを登録しています。`tty.signal(ev)` は keyboard アドレス（`ev[2]`）を見ずに `ttys[activeId]` へそのまま流すため、非 root プロセスが偽の `text_input` と Enter を `dispatch` するだけで、アクティブ端末で入力を読んでいるプログラムの行バッファにそのまま入ります。そのプログラムが root シェルなら、注入された行が root で実行されます。

### 前提と想定する攻撃

- root がコンソール（アクティブ端末）でシェルを使っている。
- 同じインスタンスで、非 root ユーザーのプロセスが同時に動いている。共有環境では別ログイン、単一コンソールでは `at`／`crontab` で仕込んだ非 root ジョブなどを使う。攻撃者が自分の前景で直接動かすと、アクティブ端末の reader が攻撃者自身になり注入先がずれるため、背景（`&`）か別プロセスから実行する。

```text
$ nx04_event_injection &
```

スクリプトは次の順に動作します。

1. 実行するコマンド（`id -u > /root/nx04_proof` …）を組み立てる。`/root` は root しか書けない。
2. `event.dispatch(table.pack("text_input", <任意>, コマンド))` でコマンド文字列を、続けて `event.dispatch(table.pack("key_down", <任意>, 13, 28))` で Enter を注入する。
3. フック経由で `tty.signal` が走り、アクティブ端末の reader（root シェル）がその行を読む。
4. root シェルが行を実行し、`/root/nx04_proof` を作成する。

期待する出力の例:

```text
nx04: injecting a command into the active terminal
nx04: /root/nx04_proof created:
0
nx04 euid=0
nx04: if it shows euid=0, NX-04 is confirmed
```

`/root/nx04_proof` が作成され `euid=0` を示していれば、非 root プロセスから root シェルへのキー入力注入（NX-04）が成立しています。`event.removeQueue(pid)` で他プロセスのイベントキューを消せる点（入力停止による DoS）も同じ API 露出に含まれます。

### 注意点

- アクティブ端末の reader が root でないと昇格にはなりません（攻撃者自身の非 root シェルに注入しても害はありません）。root の reader と非 root の注入プロセスが同時に存在する状況を用意してください。
- 検証後はイメージを破棄するか、ホスト側で `/root/nx04_proof` を削除してください。

## 失敗したときの確認点

- `nx17: cannot execute sudo` または `set-user-ID privilege is unavailable`:
  `/usr/bin/sudo.lua` の所有者とモードを確認してください（`root:root`、`4755`）。
- `nx17-payload: /etc/shadow denied`:
  `sudo` の `setuser` が失敗しています。`sudo.lua` の所有者・モードと、実行ユーザーを確認してください。
- `nx16: .meta did not receive the payload entry`:
  ホームが書き込み可能か、カーネルの同期スレッドが動作しているかを確認してください。
- `nx16-payload: /etc/shadow denied`:
  `.meta` の偽装行が読み込まれていません。再起動前にホームを変更していないか、`.meta` の行形式を確認してください。

## 制約

- 実機（OpenComputers / Ocelot）での実行結果は未確認です。
- スクリプトは静的レビューで確認した経路を再現するもので、Nexus の修正版に対する回帰テストではありません。
- 修正後は、`NX-16` の受け入れ条件（`.meta` を変更しても `euid 0` で起動できない）と、`NX-17` の受け入れ条件（共有 API を変更しても `sudo` の判断が変わらない）をこのスクリプトで確認できます。
- `NX-04` の受け入れ条件（非 root プロセスが他プロセスの配送先やキューを変更できない）は、修正後に `dispatch`・`setForeground`・`removeQueue` が user 層から拒否されることで確認します。
