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

# --------------------------------------------------------
# AUTOMAGIC DETECTION ENGINE
# --------------------------------------------------------

# Step 1: Check if the user forced an explicit service override via environment variable
if [ -n "$AI_SERVICE_NAME" ]; then
    echo "[!] Override Detected: Using user-defined service name from AI_SERVICE_NAME."
    # Verify if the service actually exists in the current compose project
    if docker compose ps --services | grep -qxF "$AI_SERVICE_NAME"; then
        TARGET_SERVICE="$AI_SERVICE_NAME"
        echo "[✓] Verified: Service '$TARGET_SERVICE' successfully found in Docker Compose configuration."
    else
        echo "[X] WARNING: Forced service '$AI_SERVICE_NAME' was not found in 'docker compose ps --services'."
        echo "    Attempting to proceed with it anyway..."
        TARGET_SERVICE="$AI_SERVICE_NAME"
    fi
fi

# Step 2: Fallback to keyword auto-detection if no explicit override was specified
if [ -z "$TARGET_SERVICE" ]; then
    echo "[*] Scanning Docker Compose stack for known AI engines..."
    
    # Priority list of engine keywords (covers llama.cpp, ollama, vllm, localai, tgi, etc.)
    AI_KEYWORDS="llama-cpp|llama.cpp|ollama|localai|vllm|tgi|tabby|litellm|stable-diffusion|koboldcpp"
    
    # Get all services in the stack, filter by key phrases, take the topmost match
    DETECTED=$(docker compose ps --services | grep -E -i "$AI_KEYWORDS" | head -n 1)
    
    if [ -n "$DETECTED" ]; then
        TARGET_SERVICE="$DETECTED"
        echo "[✓] Auto-detected AI Engine service: '$TARGET_SERVICE'"
    fi
fi

# Step 3: Hardware-independent fallback (GPU / Acceleration passthrough scanning)
if [ -z "$TARGET_SERVICE" ]; then
    echo "[*] Keyword scanning yielded no results. Scanning configurations for GPU hardware mappings..."
    
    # Inspect all container definitions in JSON format to identify GPU devices or runtime layers
    # This captures: 'nvidia', 'renderD128', 'dri', 'kfd' (Intel/AMD/ATI GPU device structures)
    DETECTED_GPU_SVC=$(docker compose ps --format json 2>/dev/null | \
                      grep -E -i "nvidia|devices|gpu|dri/render|kfd|dri" | \
                      awk -F'"Service": "' '{print $2}' | awk -F'"' '{print $1}' | head -n 1)
    
    if [ -n "$DETECTED_GPU_SVC" ]; then
        TARGET_SERVICE="$DETECTED_GPU_SVC"
        echo "[✓] Auto-detected accelerated engine via device passthroughs: '$TARGET_SERVICE'"
    fi
fi

# Step 4: Final hard fallback if everything else fails completely
if [ -z "$TARGET_SERVICE" ]; then
    echo "[!] Initialization Warning: Autodetection failed completely."
    echo "    Defaulting blind fallback to target service name: 'llama-cpp'"
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
# CORE LIFE CYCLE MONITORING LOOP
# --------------------------------------------------------
while true; do
    # Capture standard request and generation signatures across all common AI backends
    LAST_LOG_TIME=$(docker compose logs --tail 200 "$TARGET_SERVICE" 2>&1 | \
                    grep -E -i "POST|GET|HTTP|slot|HTTP/1.1|\[GIN\]|v1/|generation|tokenize|predict" | tail -n 1 | \
                    awk '{print $1,$2}' || true)

    if [ -z "$LAST_LOG_TIME" ]; then
        # Fall back to container start time to prevent cold-boot restart storms
        LAST_LOG_EPOCH=$(docker compose inspect "$TARGET_SERVICE" --format '{{pid .State.StartedAt}}' 2>/dev/null || date +%s)
    else
        LAST_LOG_EPOCH=$(date -d "$LAST_LOG_TIME" +%s 2>/dev/null || date +%s)
    fi

    CURRENT_EPOCH=$(date +%s)
    IDLE_TIME=$((CURRENT_EPOCH - LAST_LOG_EPOCH))

    if [ "$IDLE_TIME" -ge "$IDLE_TIMEOUT_SECS" ]; then
        echo "$(date): Active engine service '$TARGET_SERVICE' has reached the idle threshold ($((IDLE_TIME / 60)) minutes). Executing $CHOSEN_ACTION..."

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

        # Cool-down to let the backend safely initialize, pass health checks, and parse storage paths
        sleep 180
    fi

    sleep 30
done
