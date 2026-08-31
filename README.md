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

### 開いているアプリのスクリーンショット（影なし）

```sh
./appshot Chrome -o images/chrome_no_shadow.png --no-shadow
```

### 開いているアプリの前面に表示させてスクリーンショット

```sh
./appshot Chrome -o images/chrome_activate.png --activate
```