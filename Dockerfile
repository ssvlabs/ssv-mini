FROM fedora:39

# NOTE: ethereum-package uses ServiceConfig(publish_udp=...). This requires Kurtosis engine >= 1.15.2.
# If you upgrade Kurtosis, restart the engine to pick up the new Starlark API:
#   kurtosis engine restart

ARG KURTOSIS_CLI_VERSION=1.15.2
# Install necessary packages
RUN dnf update -y && \
    dnf install -y \
    curl \
    wget \
    tar \
    git \
    make \
    jq \
    yq \
    socat \
    dnf-plugins-core && \
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo && \
    dnf install -y docker-ce-cli && \
    dnf clean all

# Install Kurtosis CLI via RPM repository
RUN echo -e '[kurtosis]\nname=Kurtosis\nbaseurl=https://yum.fury.io/kurtosis-tech/\nenabled=1\ngpgcheck=0' | tee /etc/yum.repos.d/kurtosis.repo && \
    dnf install -y "kurtosis-cli-${KURTOSIS_CLI_VERSION}-*" && \
    dnf clean all

# Set working directory
WORKDIR /app

# Copy all repository files except kubernetes directory
COPY . /app/

# Make scripts executable
RUN chmod +x scripts/*.sh

# Default command
CMD ["/bin/bash"]
