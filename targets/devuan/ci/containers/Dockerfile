# syntax=docker/dockerfile:1
FROM debian:bookworm-slim

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# Bootstrap Devuan keyring so debootstrap can verify package signatures.
# We trust one insecure fetch of the keyring, then re-update with verification.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
 && echo "deb http://deb.devuan.org/merged excalibur main" > /etc/apt/sources.list.d/devuan.list \
 && apt-get -o Acquire::AllowInsecureRepositories=true update \
 && apt-get -o APT::Get::AllowUnauthenticated=true install -y --no-install-recommends devuan-keyring \
 && apt-get update

# Build deps (arch-independent)
RUN apt-get install -y --no-install-recommends \
        debootstrap \
        squashfs-tools \
        xorriso \
        mtools \
        dosfstools \
        grub-common \
        grub2-common \
        wget \
        git \
        xz-utils

# Arch-specific GRUB packages
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        apt-get install -y --no-install-recommends \
            grub-pc-bin grub-efi-amd64-bin; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
        apt-get install -y --no-install-recommends \
            grub-efi-arm64-bin; \
    fi \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
