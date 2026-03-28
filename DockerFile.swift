# For Swift Development
FROM swift:latest

# --- Core dev tooling (keep lean, no recommends) ---
RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        zsh npm file curl ripgrep jq util-linux bubblewrap \
        make \
        python-is-python3 \
  && rm -rf /var/lib/apt/lists/*

# --- Codex CLI ---
RUN npm install -g @openai/codex \
    --omit=dev \
    --no-fund \
    --no-audit \
    && npm cache clean --force

# --- Wrapper scripts (swift-format is already in swift:latest) ---
RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '' \
  '# Prefer Sources/Tests if present, otherwise format whole repo' \
  'if [ -d Sources ] || [ -d Tests ]; then' \
  '  swift-format format -i -r Sources Tests 2>/dev/null || true' \
  'else' \
  '  swift-format format -i -r .' \
  'fi' \
  > /usr/local/bin/format \
  && chmod +x /usr/local/bin/format

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '' \
  '# swift-format lint exits non-zero on violations' \
  'if [ -d Sources ] || [ -d Tests ]; then' \
  '  swift-format lint -r Sources Tests 2>/dev/null || swift-format lint -r .' \
  'else' \
  '  swift-format lint -r .' \
  'fi' \
  > /usr/local/bin/lint \
  && chmod +x /usr/local/bin/lint

# --- Add user ---
RUN groupadd coder \
 && useradd -m -g coder -d /home/coder -s /bin/bash coder \
 && mkdir -p /home/coder/.codex /workdir \
 && chown -R coder:coder /home/coder /workdir

# Make sure HOME is correct for subsequent RUNs when we switch user
ENV HOME=/home/coder

# Copy Codex default configuration and local model metadata config
COPY --chown=coder:coder config.toml local_models.json /home/coder/.codex/

# Swiftly paths (user-owned, so codex can install toolchains later if needed)
ENV SWIFTLY_HOME_DIR=/home/coder/.swiftly
ENV SWIFTLY_BIN_DIR=/home/coder/.local/bin
ENV PATH=/home/coder/.local/bin:$PATH

RUN mkdir -p /home/coder/.local/bin /home/coder/.swiftly \
 && chown -R coder:coder /home/coder/.local /home/coder/.swiftly

RUN mkdir -p /etc/codexctl \
 && cp /home/coder/.codex/config.toml /etc/codexctl/config.toml \
 && BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
 && cat > /etc/codexctl/image.md <<EOF
You are running inside the \`codex-swift\` image.

Environment:
- containerized Ubuntu-based Linux (package manager \`apt-get\`, package tools \`dpkg\`)
- running as the non-root user \`coder\`
- shared host workspace at \`/workdir\`
- architecture: check with \`uname -m\` if needed

Image metadata:
- image: \`codex-swift\`
- built_at_utc: \`${BUILD_TIME}\`

Built-in CLI tools:
- base tools: \`bash\`, \`zsh\`, \`curl\`, \`file\`, \`jq\`, \`rg\`, \`bwrap\`
- programming tools: \`node\`, \`npm\`, \`make\`, \`python\`, \`swift\`, \`swift-format\`, \`swiftly\`, plus the wrapper commands \`format\` and \`lint\`

Programming environments:
- Swift on Linux
- Node.js with npm
- Python

Assume Linux Swift toolchains and Linux build behavior. Do not assume access to macOS, Xcode, iOS SDKs, or Apple simulator frameworks inside this container.
EOF
RUN ln -sf /etc/codexctl/image.md /home/coder/.codex/AGENTS.md

# From here on, run as coder so swiftly writes user-owned files
USER coder
WORKDIR /workdir

# --- Add swiftly to manage swift toolchains (no extra toolchain install) ---
RUN curl -fsSL https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz \
    | tar -xz -C /tmp \
 && /tmp/swiftly init \
    --quiet-shell-followup \
    --no-modify-profile \
    --skip-install \
    --assume-yes \
 && rm -rf /tmp/swiftly

# Configure git
RUN git config --global user.email "codex@localhost" \
 && git config --global user.name "Codex CLI" \
 && git config --global init.defaultBranch "main" \
 && git config --global --add safe.directory /workdir

# Hardened entrypoint
ENTRYPOINT ["setpriv","--inh-caps=-all","--ambient-caps=-all","--bounding-set=-all","--no-new-privs","--"]
CMD ["codex","--profile","gpt-oss"]
