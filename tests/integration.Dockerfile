# The disposable controller tests/integration.sh runs Ansible in.
#
# Every pin this image is built from lives in tests/integration.sh and arrives
# as a build argument, so Renovate keeps tracking one copy of each and the
# fallback path -- installing the same packages inside a bare base image when no
# built image is available -- cannot drift from what is baked here. There are no
# defaults on purpose: a build that forgets an argument must fail rather than
# quietly produce a controller with a different Ansible in it.
#
# The image is content-addressed by the harness: its tag is a digest over this
# file, requirements.yml and those pins, so a change to any of them is a new tag
# and never a stale layer. Nothing else about it is cached.
ARG CONTROLLER_BASE_IMAGE
FROM ${CONTROLLER_BASE_IMAGE}

ARG ANSIBLE_CORE_VERSION
ARG REQUESTS_VERSION
ARG RUBY_PACKAGE
ARG CURL_PACKAGE

# Links the published package to this repository, which is what lets the
# workflow's own GITHUB_TOKEN write it and what makes the package inherit the
# repository's visibility.
LABEL org.opencontainers.image.source="https://github.com/yonatankarp/nas-platform"

# Deliberately no ENTRYPOINT and no CMD. The sandbox teardown runs
# `docker run <image> python - ...` against this image and relies on the base
# image's bare command; setting either here breaks cleanup rather than the
# converge, which is the failure that is hardest to read.

RUN test -n "${RUBY_PACKAGE}" && test -n "${CURL_PACKAGE}" && \
    apk add --no-cache --quiet docker-cli docker-cli-compose git tar openssl \
      apache2-utils openssh-client "${RUBY_PACKAGE}" "${CURL_PACKAGE}"

RUN test -n "${ANSIBLE_CORE_VERSION}" && test -n "${REQUESTS_VERSION}" && \
    pip install --quiet --no-input "ansible-core==${ANSIBLE_CORE_VERSION}" \
      "requests==${REQUESTS_VERSION}"

# The collections land in root's collection path, which is where the controller
# container -- which runs as root -- looks for them. Copied in rather than bind
# mounted so the layer is complete on its own.
COPY requirements.yml /toolchain/requirements.yml
RUN ansible-galaxy collection install -r /toolchain/requirements.yml >/dev/null
