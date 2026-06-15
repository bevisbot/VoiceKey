#!/bin/bash
# 一次性安装 Whisper 引擎:编译 whisper.cpp + 下载 turbo 模型 + 部署到 App 支持目录。
# 已装过则可重跑(会覆盖二进制;模型存在则跳过下载)。
set -e
cd "$(dirname "$0")"

CMAKE="$(pwd)/tools/cmake-3.30.5-macos-universal/CMake.app/Contents/bin/cmake"
DST="$HOME/Library/Application Support/VoiceKey/whisper"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"

# 1. CMake(没有就下载官方二进制)
if [ ! -x "$CMAKE" ]; then
  echo "==> 下载 CMake…"
  mkdir -p tools && cd tools
  curl -fL -o cmake.tar.gz "https://github.com/Kitware/CMake/releases/download/v3.30.5/cmake-3.30.5-macos-universal.tar.gz"
  tar xzf cmake.tar.gz && cd ..
fi

# 2. whisper.cpp 源码
[ -d whisper.cpp ] || git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git

# 3. 编译(静态、Metal)
echo "==> 编译 whisper.cpp…"
"$CMAKE" -B whisper.cpp/build -S whisper.cpp \
  -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DCMAKE_BUILD_TYPE=Release
"$CMAKE" --build whisper.cpp/build --config Release -j 8

# 4. 部署二进制 + 模型
mkdir -p "$DST"
cp whisper.cpp/build/bin/whisper-server "$DST/whisper-server"
chmod +x "$DST/whisper-server"
if [ ! -f "$DST/ggml-large-v3-turbo.bin" ]; then
  echo "==> 下载 turbo 模型(~1.6G)…"
  curl -fL -o "$DST/ggml-large-v3-turbo.bin" "$MODEL_URL"
fi

echo "==> 完成。文件在:$DST"
ls -lh "$DST"
