# Ma

English | [日本語](README.ja.md)

## About

Ma (間, "the space between") is a small Markdown editor for macOS.

- **Minimal and Obsidian-compatible.** Open a folder of plain `.md` files, such as an Obsidian vault, and edit it with live preview. Files stay plain Markdown, and Ma reads Obsidian settings like daily notes and bookmarks.
- **An editor that stands between AI and humans.** Notes written by AI agents and notes written by you live in the same plain files. Ma is the place where you read, fix, and rearrange them by hand.
- **macOS only, tuned for one person.** Ma is built with Swift and AppKit and is optimized for the author's own workflow.

## Installation

There are no prebuilt binaries yet. Build from source.

Requirements:

- macOS 15 or later
- Swift 6 (Xcode or the Command Line Tools)

```sh
git clone https://github.com/utahka/ma.git
cd ma
make install  # builds build/Ma.app and copies it to /Applications
```

To try it without installing, run `make run`.

## License

[MIT](LICENSE)
