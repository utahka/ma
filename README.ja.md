# Awai

[English](README.md) | 日本語

## 概要

Awai（間・あわい）は macOS 用の小さな Markdown エディタです。

- **Obsidian 互換のミニマルなエディタ。** Obsidian の vault のような、素の `.md` が並ぶフォルダを開き、ライブプレビューで編集します。ファイルは素の Markdown のまま保たれ、デイリーノートやブックマークといった Obsidian の設定も読み込み、Bases（`.base`）は編集できる表として表示します。
- **AI と人間の「間」に立つエディタ。** AI エージェントが書いたノートも、自分で書いたノートも、同じ素のファイルとして置かれます。Awai はそれらを人が読み、直し、並べ替えるための場所です。
- **macOS 専用で、作者自身に最適化。** Swift と AppKit で書いており、作者の使い方に合わせて作っています。

## インストール

配布用のバイナリはまだありません。ソースからビルドしてください。

必要なもの:

- macOS 15 以降
- Swift 6（Xcode または Command Line Tools）

```sh
git clone https://github.com/utahka/awai.git
cd awai
make install  # build/Awai.app を作り、/Applications にコピーする
```

インストールせずに試すときは `make run` を実行します。

## ライセンス

[MIT](LICENSE)
