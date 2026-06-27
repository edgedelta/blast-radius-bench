FROM python:3.12-slim

# CLI tooling so the agent can grep/jq/awk the telemetry.
RUN apt-get update && apt-get install -y --no-install-recommends \
        jq grep gawk coreutils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workdir

# Copy the scenario telemetry into /workdir. NOTE: tests/ (ground truth) is NOT copied;
# it is injected only at verification time.
COPY workdir/ /workdir/

CMD ["/bin/bash"]
