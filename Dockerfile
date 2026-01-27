FROM fedora:39

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

# Install Kurtosis CLI (1.15.0+ required for publish_udp support in ethereum-package)
RUN curl -L "https://github.com/kurtosis-tech/kurtosis/releases/download/1.15.2/kurtosis-cli_1.15.2_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin kurtosis

# Set working directory
WORKDIR /app

# Copy all repository files except kubernetes directory
COPY . /app/

# Make scripts executable
RUN chmod +x scripts/*.sh

# Default command
CMD ["/bin/bash"]
