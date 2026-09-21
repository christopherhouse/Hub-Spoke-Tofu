# Self-hosted GitHub Actions runner for Azure Container Apps jobs.
#
# Built server-side by ACR Tasks (`az acr build`), never locally and never on a runner: a
# Container Apps job cannot run Docker inside the container, so a runner cannot rebuild this
# image. See .github/workflows/build-runner-image.yml.
#
# The Microsoft sample runner image is deliberately not used. Its entrypoint mints a
# registration token from a personal access token, and this design authenticates as a GitHub
# App instead, which needs a JWT -> installation token -> registration token exchange.
#
# WHAT IS AND IS NOT HERE
#
# The tool set is "whatever this repository's own workflows need, and nothing speculative".
# On the Consumption workload profile a cold node pulls this image before the job starts, so
# every megabyte is queue latency. Anything a single workflow needs should be installed by
# that workflow with a `setup-*` action rather than added here.
#
# Deliberately absent, and not fixable here:
#
#   - Docker. A Container Apps job cannot run a container inside the container. That rules out
#     `docker build`, any action declaring `runs: docker`, and `jobs.<id>.services` service
#     containers. Image builds go through ACR Tasks.
FROM ubuntu:24.04

# Pinned so a rebuild is reproducible. It also has an expiry date: `--disableupdate` in the
# entrypoint stops the runner self-updating, and GitHub refuses connections from runners more
# than about 30 days behind. The weekly scheduled rebuild in build-runner-image.yml is what
# keeps this current; check https://github.com/actions/runner/releases before bumping.
ARG RUNNER_VERSION=2.337.0
ARG RUNNER_ARCH=x64

# Node for the runner's own JavaScript actions is bundled in the runner tarball. This is the
# system Node, for workflow steps that shell out to `node` or `npm` directly.
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    RUNNER_MANUALLY_TRAP_SIG=1 \
    ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1 \
    AZURE_CONFIG_DIR=/home/runner/.azure \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache

# ---------------------------------------------------------------------------------------
# Base tooling
#
# curl, jq and openssl are the GitHub App JWT exchange in the entrypoint. git and git-lfs are
# actions/checkout. python3 runs this repository's own scripts. The runner's remaining native
# dependencies are left to ./bin/installdependencies.sh below rather than listed here, because
# their package names carry ABI version suffixes that change on every base image bump.
# ---------------------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        git \
        git-lfs \
        gnupg \
        jq \
        lsb-release \
        openssl \
        python3 \
        python3-venv \
        rsync \
        shellcheck \
        sudo \
        tar \
        unzip \
        wget \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------------------
# Third-party apt repositories
#
# Each key is fetched over HTTPS into its own keyring and each source line is pinned to that
# keyring with signed-by. A key dropped in /etc/apt/trusted.gpg.d would be trusted for every
# repository, which is how one compromised vendor becomes root on the image.
# ---------------------------------------------------------------------------------------
RUN set -eux; \
    codename="$(lsb_release -cs)"; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${codename} main" \
        > /etc/apt/sources.list.d/azure-cli.list; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli.gpg; \
    chmod 0644 /etc/apt/keyrings/githubcli.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends azure-cli gh nodejs; \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------------------
# The runner account
#
# The runner refuses to run as root, so it gets its own unprivileged account. Passwordless
# sudo matches the official GitHub-hosted images, and the `setup-*` actions assume it. The
# blast radius is one ephemeral, single-job container holding no credentials beyond that job's
# own token, which is the same trust boundary a hosted runner has.
# ---------------------------------------------------------------------------------------
RUN useradd --create-home --shell /bin/bash runner \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && mkdir -p "$AGENT_TOOLSDIRECTORY" \
    && chown runner:runner "$AGENT_TOOLSDIRECTORY"

WORKDIR /home/runner

# installdependencies.sh needs root and must run after the tarball is extracted. It is the
# runner's own list of native prerequisites, which is why they are not restated above.
RUN set -eux; \
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz; \
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner /home/runner

COPY --chown=runner:runner entrypoint.sh /home/runner/entrypoint.sh
RUN chmod +x /home/runner/entrypoint.sh

USER runner

# Installed as the runner account, not root: `az bicep` resolves the Bicep CLI relative to
# AZURE_CONFIG_DIR, so a copy under /root would be invisible at run time. Going through the
# Azure CLI rather than downloading Bicep separately means `az bicep` and a bare `bicep` call
# cannot end up on different versions.
RUN az config set core.collect_telemetry=false --only-show-errors \
    && az bicep install \
    && az bicep version

ENTRYPOINT ["/home/runner/entrypoint.sh"]
