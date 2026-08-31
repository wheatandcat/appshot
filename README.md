# appshot

##  ビルド

```sh
swiftc -O appshot.swift -o appshot
```

## 実行

### 開いているアプリの一覧

```sh
./appshot --apps
```

### 開いているアプリのスクリーンショット

```sh
./appshot Chrome -o images/chrome.png
```