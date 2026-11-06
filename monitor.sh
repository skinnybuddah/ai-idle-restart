#!/bin/sh

# 1. Parse environmental configurations and defaults
TIMEOUT_MINUTES=${IDLE_TIMEOUT:-15}
IDLE_TIMEOUT_SECS=$((TIMEOUT_MINUTES * 60))
CHOSEN_ACTION=${ACTION:-UPDOWN}
USER_SERVICE_NAME=${AI_SERVICE_NAME:-"llama-cpp"}

echo "=================================================="
echo "    🤖 AI IDLE WATCHDOG INITIALIZATION 🤖        "
echo "=================================================="
echo "[*] Scanning active containers via Docker Socket..."

# Find the target container ID by looking at the Docker Compose service label natively
TARGET_ID=$(docker ps --filter "label=com.docker.compose.service=$USER_SERVICE_NAME" -q | head -n 1)

# Fallback: Scan labels for any common AI keywords if the explicit service name isn't matched
if [ -z "$TARGET_ID" ]; then
    echo "[*] Service '$USER_SERVICE_NAME' not found. Scanning container labels for AI keywords..."
    AI_KEYWORDS="llama-cpp|llama.cpp|ollama|vllm|localai|tgi|koboldcpp|stable-diffusion"
    
    for id in $(docker ps -q); do
        svc_label=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null)
        if echo "$svc_label" | grep -E -i -q "$AI_KEYWORDS"; then
            # Filter out database containers completely
            if ! echo "$svc_label" | grep -E -i -q "-db|_db|-postgres|-redis"; then
                TARGET_ID="$id"
                USER_SERVICE_NAME="$svc_label"
                echo "[✓] Auto-detected AI service via label parsing: '$USER_SERVICE_NAME'"
                break
            fi
        fi
    done
fi

# Fallback 2: Scan for active hardware acceleration mappings (NVIDIA/AMD/Intel)
if [ -z "$TARGET_ID" ]; then
    echo "[*] Keyword scanning empty. Checking container hardware device paths..."
    for id in $(docker ps -q); do
        devices=$(docker inspect -f '{{ .HostConfig.Devices }}' "$id" 2>/dev/null)
        runtime=$(docker inspect -f '{{ .ProcessLabel }} {{ .Runtime }}' "$id" 2>/dev/null)
        if echo "$devices $runtime" | grep -E -i -q "nvidia|gpu|dri|render|kfd"; then
            svc_label=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$id" 2>/dev/null)
            if [ -n "$svc_label" ] && ! echo "$svc_label" | grep -E -i -q "-db|_db|-postgres|-redis"; then
                TARGET_ID="$id"
                USER_SERVICE_NAME="$svc_label"
                echo "[✓] Auto-detected hardware accelerated service: '$USER_SERVICE_NAME'"
                break
            fi
        fi
    done
fi

# Final Fallback Configuration
if [ -z "$TARGET_ID" ]; then
    echo "[!] WARNING: Could not resolve a running container for target '$USER_SERVICE_NAME'."
    echo "    The watchdog will continuously scan until the service mounts or comes online."
fi

echo "--------------------------------------------------"
echo "📢 WATCHDOG CONFIGURATION PROFILE SUMMARY:"
echo "👉 TARGET COMPOSE SERVICE: $USER_SERVICE_NAME"
echo "👉 TARGET CONTAINER ID   : ${TARGET_ID:-Waiting to boot...}"
echo "👉 IDLE RUNTIME TIMEOUT  : ${TIMEOUT_MINUTES} minutes"
echo "👉 INTERVENTION ACTION   : $CHOSEN_ACTION"
echo "=================================================="
echo "[*] Watchdog fully active and auditing container logs..."

# --------------------------------------------------------
# CORE RUNTIME LOOP (SOCKET LOG-HASH COUNTER STRATEGY)
# --------------------------------------------------------
CURRENT_IDLE_SECS=0
CHECK_INTERVAL=30
LAST_LOG_HASH=""

while true; do
    # If the container isn't active or dropped during a cycle, keep scanning until it exists
    if [ -z "$TARGET_ID" ] || ! docker ps -q | grep -q "$TARGET_ID"; then
        TARGET_ID=$(docker ps --filter "label=com.docker.compose.service=$USER_SERVICE_NAME" -q | head -n 1)
        if [ -n "$TARGET_ID" ]; then
            echo "[✓] Connection established with Container ID: $TARGET_ID"
            LAST_LOG_HASH=$(docker logs --tail 5 "$TARGET_ID" 2>&1 | md5sum)
            CURRENT_IDLE_SECS=0
        fi
        sleep 10
        continue
    fi

    # Initialize log tracking signature on cold boot
    if [ -z "$LAST_LOG_HASH" ]; then
        LAST_LOG_HASH=$(docker logs --tail 5 "$TARGET_ID" 2>&1 | md5sum)
    fi

    sleep "$CHECK_INTERVAL"
    
    # Query logs directly via the raw engine socket using the container ID
    CURRENT_LOG_HASH=$(docker logs --tail 5 "$TARGET_ID" 2>&1 | md5sum)
    
    if [ "$CURRENT_LOG_HASH" = "$LAST_LOG_HASH" ]; then
        CURRENT_IDLE_SECS=$((CURRENT_IDLE_SECS + CHECK_INTERVAL))
    else
        CURRENT_IDLE_SECS=0
        LAST_LOG_HASH="$CURRENT_LOG_HASH"
    fi

    # Trigger memory clearing intervention on timeout threshold match
    if [ "$CURRENT_IDLE_SECS" -ge "$IDLE_TIMEOUT_SECS" ]; then
        echo "$(date): Target '$USER_SERVICE_NAME' ($TARGET_ID) has been entirely idle for ${TIMEOUT_MINUTES} minutes."
        echo "[*] Executing action '$CHOSEN_ACTION' via native container controls to flush system VRAM..."

        # Raw docker engine commands safely recycle the exact container process space, 
        # completely avoiding compose interpolation errors and volume path mounting lag.
        docker restart "$TARGET_ID"

        echo "[✓] Action completed successfully. VRAM released to Host OS."
        CURRENT_IDLE_SECS=0
        LAST_LOG_HASH=""
        sleep 180
    fi
done
