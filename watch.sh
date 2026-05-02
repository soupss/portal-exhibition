#!/bin/bash

PORT=3000
PIPE="/tmp/shader_ws_pipe"

rm -f $PIPE
mkfifo $PIPE

exec 3<> $PIPE

websocat --text -E ws-listen:127.0.0.1:$PORT broadcast:- <&3 &
WS_PID=$!

trap "echo -e '\nShutting down...'; kill $WS_PID 2>/dev/null; rm -f $PIPE; exec 3>&-; exit" INT TERM EXIT

echo "WebSocket server listening on ws://localhost:$PORT"
echo "Watching shaders/ for .glsl changes..."

compile_and_notify() {
    echo -e "Transpiling shader..."
    naga --shader-stage compute --input-kind glsl shaders/compute.glsl shaders/compute.wgsl
    if [ $? -eq 0 ]; then
        echo "Success!"
        echo "shader_updated" >&3
    else
        echo "Failed!"
    fi
}

fswatch -o shaders/*.glsl | while read num; do
    compile_and_notify
    sleep 0.5
done
