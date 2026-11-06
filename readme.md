# AI Idle Stack Watchdog (`ai-idle-restart`)

A containerised, highly adaptive watchdog process designed to monitor local AI services (`llama.cpp`, `Ollama`, etc.) inside a Shared Docker Compose project stack. 

When your Large Language Model (LLM) or embedding engine finishes executing tasks, it holds onto system resources and host GPU Memory (VRAM). This container automatically detects idleness by inspecting container log signatures and cycles the specific resource hog, releasing **100% of VRAM/System Memory back to the Host OS** until it is queried again.

---

## Key Features

- **Automagic Target Detection:** Completely decoupled from hardware vendor locks. Autodetects targets by analyzing keyword signatures (`llama`, `ollama`, `vllm`, `localai`) or checking resource passthroughs across **NVIDIA, AMD/ATI, and Intel ARC GPUs**.
- **Explicit Target Override:** Allows you to completely bypass discovery via an optional environment parameter.
- **Granular Execution Mappings:** Choose whether to standard restart, force-recreate, or cycle the system up and down natively.
- **Clean Container Lifecycles:** Tracks container initialisation dates to avoid cold-boot loops.

---

## Configuration Variables

| Environment Variable | Allowed Arguments | Default | Description |
| :--- | :--- | :--- | :--- |
| `IDLE_TIMEOUT` | Any integer (in minutes) | `15` | Total amount of inactive minutes tracked before recycling your target container. |
| `ACTION` | `UPDOWN`, `Recreate`, `Restart` | `UPDOWN` | Mapped intervention strategy. **`UPDOWN`** completely stops and removes the target process space, serving as the cleanest way to clear GPU allocations. |
| `AI_CONTAINER_MODE` | `D`, `F`, `A` | `D` | System state profiles: <br>• **`D`**: Background Daemon mode (`-d`) <br>• **`F`**: Attached Foreground execution <br>• **`A`**: Abort-on-container-exit lifecycle security. |
| `AI_SERVICE_NAME` | Name of Compose Service | *Optional* | Manual service definition override. Skips automagic discovery entirely. |

---

## Deployment Integration

Add this lightweight service block directly to the bottom of your existing `docker-compose.yml` file:

```yaml
services:
  # Your existing AI configuration space (e.g. llama-cpp / ollama)
  llama-cpp:
    container_name: llama-cpp
    image: ghcr.io/ggml-org/llama.cpp:server-cuda
    restart: unless-stopped
    # ... rest of your parameters

  # The memory protection layer watchdog
  ai-watchdog:
    container_name: ai-stack-watchdog
    image: ghcr.io/skinnybuddah/ai-idle-restart:latest
    restart: unless-stopped
    volumes:
      # Required to query metadata and manage container states
      - /var/run/docker.sock:/var/run/docker.sock
      # Mounts current directory context so Docker Compose can map target actions
      - .:/stack
    working_dir: /stack
    environment:
      - IDLE_TIMEOUT=15
      - ACTION=UPDOWN
      - AI_CONTAINER_MODE=D
      - AI_SERVICE_NAME=llama-cpp # Optional: Remove to let automagic discovery take over
```

---

## Initialisation Log Diagnostics

Upon deployment, check the container logs to ensure the watchdog has correctly resolved your service mapping topology:

```bash
docker logs ai-stack-watchdog
```

### Healthy Diagnostic Output Example:
```text
==================================================
    🤖 AI IDLE WATCHDOG INITIALIZATION 🤖        
==================================================
[*] Scanning Docker Compose stack for known AI engines...
[✓] Auto-detected AI Engine service: 'llama-cpp'
--------------------------------------------------
📢 WATCHDOG CONFIGURATION PROFILE SUMMARY:
Refers directly to variables configured above
👉 TARGET ENGINE SERVICE : llama-cpp
👉 IDLE RUNTIME TIMEOUT  : 15 minutes
👉 INTERVENTION ACTION   : UPDOWN
👉 SYSTEM EXECUTION MODE : D (Compose flag: -d)
==================================================
[*] Watchdog fully active and monitoring log signatures...
```
