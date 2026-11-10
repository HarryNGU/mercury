#!/bin/zsh
# Puts whisper.cpp inside a Mercury.app so dictation and captions work on Macs without Homebrew.
# Copies the tools, their libraries and the speed modules into Contents/Helpers/whisper and points
# each one at the copies beside it. Usage: tools/bundle-whisper.sh path/to/Mercury.app
set -euo pipefail
APP=$1
# Voice: carry whisper.cpp inside the app so dictation and captions work on Macs without Homebrew.
# Copies the tools, their libraries and the speed modules, and points each at the copies beside it.
H="$APP/Contents/Helpers/whisper"
if [[ -x /opt/homebrew/bin/whisper-cli && -f /opt/homebrew/opt/whisper.cpp/lib/libwhisper.1.dylib ]]; then
  mkdir -p "$H"
  cp -L /opt/homebrew/bin/whisper-cli /opt/homebrew/bin/whisper-server "$H/"
  cp -L /opt/homebrew/opt/whisper.cpp/lib/libwhisper.1.dylib /opt/homebrew/opt/ggml/lib/libggml.0.dylib \
        /opt/homebrew/opt/ggml/lib/libggml-base.0.dylib /opt/homebrew/opt/libomp/lib/libomp.dylib "$H/"
  cp -L /opt/homebrew/opt/ggml/libexec/*.so "$H/"
  chmod u+w "$H"/*
  for f in "$H"/*; do
    for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local/opt|@rpath)'); do
      install_name_tool -change "$dep" "@loader_path/${dep:t}" "$f" 2>/dev/null
    done
    [[ $f == *.dylib ]] && install_name_tool -id "@loader_path/${f:t}" "$f" 2>/dev/null
    for rp in $(otool -l "$f" | awk '/LC_RPATH/ {getline; getline; print $2}'); do install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null; done
  done
  if otool -L "$H"/* | grep -q /opt/homebrew; then echo "warning: whisper copy still points at Homebrew"; fi
else
  echo "note: whisper.cpp not found, so this build has no built in voice (brew install whisper-cpp)"
fi

