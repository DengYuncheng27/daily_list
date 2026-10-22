"""Package clean source and already-built applications without bundled caches."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "releases"
SKIP_DIRS = {
    ".git", ".dart_tool", ".idea", ".gradle", ".kotlin", ".cxx", ".pytest_cache",
    "__pycache__", "build", "releases", "ephemeral", ".symlinks", "Pods",
    "DerivedData", "node_modules",
}
SKIP_FILES = {
    "local.properties", "key.properties", "Generated.xcconfig",
    "flutter_export_environment.sh", ".flutter-plugins",
    ".flutter-plugins-dependencies", ".env", ".DS_Store",
}
SKIP_SUFFIXES = {".iml", ".pyc", ".log", ".db", ".sqlite3", ".jks", ".keystore"}


def source_files():
    for directory, dirs, files in os.walk(ROOT, followlinks=False):
        dirs[:] = sorted(
            name for name in dirs
            if name not in SKIP_DIRS and not (Path(directory) / name).is_symlink()
        )
        for name in sorted(files):
            path = Path(directory) / name
            if (
                name in SKIP_FILES or path.suffix in SKIP_SUFFIXES
                or ".sqlite3-" in name or path.is_symlink()
                or (name.startswith(".env.") and not name.endswith(".example"))
            ):
                continue
            yield path


def add_file(archive: zipfile.ZipFile, path: Path, target: str):
    info = zipfile.ZipInfo.from_file(path, target)
    info.create_system = 3
    mode = 0o755 if path.name == "gradlew" else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    with path.open("rb") as source, archive.open(info, "w") as destination:
        shutil.copyfileobj(source, destination)


def zip_tree(source: Path, target: Path, prefix=""):
    if not source.is_dir():
        raise SystemExit(f"Build output missing: {source}")
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_file() and not path.is_symlink():
                add_file(archive, path, prefix + path.relative_to(source).as_posix())
        if prefix == "Dayflow/":
            archive.writestr(
                "Dayflow/开始使用.txt",
                "日序 Dayflow\n\n解压整个文件夹后运行 dayflow.exe，保留 DLL 和 data 目录。\n"
                "可先体验示例，也可填写自己的 HTTPS 服务器并注册/登录。\n"
                "默认原生 API 为 http://127.0.0.1:8000，可在登录页修改。\n"
                "当前开发电脑的临时 API 地址为 http://127.0.0.1:50267。\n"
                "本包需要 Windows x64 与 Microsoft Visual C++ 2015-2022 x64 运行库。\n"
                "云同步需要配套服务；提醒仅在应用开启时显示。\n",
            )


def main():
    OUT.mkdir(exist_ok=True)
    source_zip = OUT / "dayflow-source.zip"
    with zipfile.ZipFile(source_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in source_files():
            add_file(archive, path, "dayflow/" + path.relative_to(ROOT).as_posix())
    zip_tree(
        ROOT / "client/build/windows/x64/runner/Release",
        OUT / "dayflow-windows-x64.zip", "Dayflow/",
    )
    zip_tree(ROOT / "client/build/web", OUT / "dayflow-web.zip")
    apk = ROOT / "client/build/app/outputs/flutter-apk/app-debug.apk"
    if not apk.is_file():
        raise SystemExit("Build Android debug APK before packaging.")
    shutil.copy2(apk, OUT / "dayflow-android-debug.apk")
    products = [source_zip, OUT / "dayflow-windows-x64.zip", OUT / "dayflow-web.zip", OUT / "dayflow-android-debug.apk"]
    checksums = []
    for path in products:
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        checksums.append(f"{digest}  {path.name}")
        if path.suffix == ".zip":
            with zipfile.ZipFile(path) as archive:
                bad_entry = archive.testzip()
                if bad_entry:
                    raise SystemExit(f"Corrupt ZIP member: {bad_entry}")
        print(f"{path.name}: {path.stat().st_size / 1024 / 1024:.1f} MiB")
    (OUT / "SHA256SUMS.txt").write_text("\n".join(checksums) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
