#!/usr/bin/env bash
# Tile PNG frames into one contact sheet: scripts/sheet.sh out.png cols frame1.png frame2.png ...
out=$1; cols=$2; shift 2
files=("$@"); n=${#files[@]}
inputs=(); filt=""; layout=""; stack=""
for i in "${!files[@]}"; do
  f=${files[$i]}; inputs+=(-i "$f")
  label=$(basename "$f" .png | awk -F- '{print $(NF)}')
  filt+="[$i:v]scale=960:540,drawtext=text='${label}':x=12:y=10:fontsize=26:fontcolor=white:box=1:boxcolor=black@0.6[v$i];"
  layout+="$(( (i % cols) * 960 ))_$(( (i / cols) * 540 ))|"; stack+="[v$i]"
done
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${filt}${stack}xstack=inputs=$n:layout=${layout%|}:fill=black" "$out"
