#!/bin/sh

# 1. Parsing Inputs, Variables, and Defaults
TIMEOUT_MINUTES=${IDLE_TIMEOUT:-15}
IDLE_TIMEOUT_SECS=$((TIMEOUT_MINUTES * 60))
CHOSEN_ACTION=${ACTION:-UPDOWN}

case "${AI_CONTAINER_MODE:-D}" in
    "D") MODE_FLAG="-d" ;;
    "F") MODE_FLAG="" ;;
    "A") MODE_FLAG="--abort-on-container-exit" ;;
    *)   MODE_FLAG="-d" ;; 
esac

echo "=================================================="
echo "    🤖 AI IDLE WATCHDOG INITIALIZATION 🤖        "
echo "=================================================="

TARGET_SERVICE=""

# Step 1: Check if the user forced an explicit service override via environment variable
if [ -n "$AI_SERVICE_NAME" ]; then
    echo "[!] Override Detected: Using user-defined service name from AI_SERVICE_NAME."
    # Use standard grep containing word boundaries to completely ignore hidden spacing or return symbols
    if docker compose ps --services | grep -q -E "(^| )$AI_SERVICE_NAME($| )"; then
        TARGET_SERVICE="$AI_SERVICE_NAME"
        echo "[✓] Verified: Service '$TARGET_SERVICE' successfully found in Docker Compose configuration."
    else
        echo "[X] WARNING: Forced service '$AI_SERVICE_NAME' was not found in 'docker compose ps --services'."
        TARGET_SERVICE="$AI_SERVICE_NAME"
    fi
fi


# Removed this step1 version as it was too harsh on the matching algo
# Step 1: Check if the user forced an explicit service override via environment variable
#if [ -n "$AI_SERVICE_NAME" ]; then
#    echo "[!] Override Detected: Using user-defined service name from AI_SERVICE_NAME."
#    if docker compose ps --services | grep -qxF "$AI_SERVICE_NAME"; then
#        TARGET_SERVICE="$AI_SERVICE_NAME"
#        echo "[✓] Verified: Service '$TARGET_SERVICE' successfully found in Docker Compose configuration."
#    else
#        echo "[X] WARNING: Forced service '$AI_SERVICE_NAME' was not found in 'docker compose ps --services'."
#        TARGET_SERVICE="$AI_SERVICE_NAME"
#    fi
#fi

# Step 2: Fallback to keyword auto-detection
if [ -z "$TARGET_SERVICE" ]; then
    echo "[*] Scanning Docker Compose stack for known AI engines..."
    AI_KEYWORDS="llama-cpp|llama.cpp|ollama|localai|vllm|tgi|tabby|litellm|stable-diffusion|koboldcpp"
    DETECTED=$(docker compose ps --services | grep -E -i "$AI_KEYWORDS" | head -n 1)
    if [ -n "$DETECTED" ]; then
        TARGET_SERVICE="$DETECTED"
        echo "[✓] Auto-detected AI Engine service: '$TARGET_SERVICE'"
    fi
fi

# Step 3: Hardware-independent fallback (GPU / Acceleration passthrough scanning)
if [ -z "$TARGET_SERVICE" ]; then
    echo "[*] Keyword scanning yielded no results. Scanning configurations for GPU hardware mappings..."
    DETECTED_GPU_SVC=$(docker compose ps --format json 2>/dev/null | \
                      grep -E -i "nvidia|devices|gpu|dri/render|kfd|dri" | \
                      awk -F'"Service": "' '{print $2}' | awk -F'"' '{print $1}' | head -n 1)
    if [ -n "$DETECTED_GPU_SVC" ]; then
        TARGET_SERVICE="$DETECTED_GPU_SVC"
        echo "[✓] Auto-detected accelerated engine via device passthroughs: '$TARGET_SERVICE'"
    fi
fi

# Step 4: Final hard fallback
if [ -z "$TARGET_SERVICE" ]; then
    echo "[!] Initialization Warning: Autodetection failed completely."
    TARGET_SERVICE="llama-cpp"
fi

echo "--------------------------------------------------"
echo "📢 WATCHDOG CONFIGURATION PROFILE SUMMARY:"
echo "👉 TARGET ENGINE SERVICE : $TARGET_SERVICE"
echo "👉 IDLE RUNTIME TIMEOUT  : ${TIMEOUT_MINUTES} minutes"
echo "👉 INTERVENTION ACTION   : $CHOSEN_ACTION"
echo "👉 SYSTEM EXECUTION MODE : $AI_CONTAINER_MODE (Compose flag: ${MODE_FLAG:-(None)})"
echo "=================================================="
echo "[*] Watchdog fully active and monitoring log signatures..."

# --------------------------------------------------------
# CORE LIFE CYCLE MONITORING LOOP (COUNTER STRATEGY)
# --------------------------------------------------------
# Store the initial log footprint signature
LAST_LOG_HASH=$(docker compose logs --tail 5 "$TARGET_SERVICE" 2>&1 | md5sum)
CURRENT_IDLE_SECS=0
CHECK_INTERVAL=30

while true; do
    sleep "$CHECK_INTERVAL"
    
    # Grab the current tail signature of the logs
    CURRENT_LOG_HASH=$(docker compose logs --tail 5 "$TARGET_SERVICE" 2>&1 | md5sum)
    
    if [ "$CURRENT_LOG_HASH" = "$LAST_LOG_HASH" ]; then
        # No new logs mean the container is completely quiet
        CURRENT_IDLE_SECS=$((CURRENT_IDLE_SECS + CHECK_INTERVAL))
    else
        # New log activity detected! Reset the idle timer completely
        CURRENT_IDLE_SECS=0
        LAST_LOG_HASH="$CURRENT_LOG_HASH"
    fi

    # Trigger action if idle duration matches or exceeds our timeout threshold
    if [ "$CURRENT_IDLE_SECS" -ge "$IDLE_TIMEOUT_SECS" ]; then
        echo "$(date): Service '$TARGET_SERVICE' has been entirely idle for ${TIMEOUT_MINUTES} minutes. Executing $CHOSEN_ACTION..."

        case "$CHOSEN_ACTION" in
            "Restart")
                docker compose restart "$TARGET_SERVICE"
                ;;
            "Recreate")
                docker compose up $MODE_FLAG --force-recreate "$TARGET_SERVICE"
                ;;
            "UPDOWN")
                docker compose stop "$TARGET_SERVICE" && \
                docker compose rm -f "$TARGET_SERVICE" && \
                docker compose up $MODE_FLAG "$TARGET_SERVICE"
                ;;
        esac

        # Clear tracking metrics and sleep to let the stack fully warm back up
        CURRENT_IDLE_SECS=0
        sleep 180
        LAST_LOG_HASH=$(docker compose logs --tail 5 "$TARGET_SERVICE" 2>&1 | md5sum)
    fi
done
