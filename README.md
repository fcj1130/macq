# MacQ

[English](README.md) | [简体中文](README.zh-CN.md)

A compact toolbox app for macOS — small daily utilities in one menu-bar-friendly app.

## Features

- **Magic Mouse** — smooth scrolling, speed control, and axis inversion for physical mouse wheels (trackpad untouched).
- **Magic Clipboard** — clipboard history with search, type filters, and paste-back via a Spotlight-style floating panel.
- **Magic Right Click** — Finder context menu: copy path, open terminal, and new file (with rename, like the system's new folder).
- **Screenshot** — region/window capture, annotations (rect, arrow, pen, text, mosaic), offline OCR, and scrolling screenshots.
- **Developer Toolbox** — JSON formatter, Base64, URL encode, timestamp, UUID, hash, QR code (generate & scan), color picker, random password.
- Menu bar icon, dark/light theme, English & Simplified Chinese UI, launch at login.

## Requirements

- macOS 14.0+
- Xcode + [xcodegen](https://github.com/yonaskolb/XcodeGen) (for building from source)

Some tools need system permissions (Accessibility, Input Monitoring, Screen Recording). MacQ asks for them on first use.

## Build & Run

```bash
# Build (Debug) and launch — everyday development
./Scripts/run.sh
```

## Package

```bash
# Build Release and produce dist/MacQ-<version>.dmg
./Scripts/package.sh          # version defaults to the project version
./Scripts/package.sh 0.3.0    # or pass one explicitly
```
