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

# Install Kurtosis CLI via RPM repository
RUN echo -e '[kurtosis]\nname=Kurtosis\nbaseurl=https://yum.fury.io/kurtosis-tech/\nenabled=1\ngpgcheck=0' | tee /etc/yum.repos.d/kurtosis.repo && \
    dnf install -y kurtosis-cli && \
    dnf clean all

# Set working directory
WORKDIR /app

# Copy all repository files except kubernetes directory
COPY . /app/

# Make scripts executable
RUN chmod +x scripts/*.sh

# Default command
CMD ["/bin/bash"]
