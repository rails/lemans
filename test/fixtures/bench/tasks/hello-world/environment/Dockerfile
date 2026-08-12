FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# A repository is optional — lemans would `git init` one for its baseline —
# but a real task ships as a checkout, so the fixture does too.
RUN git init -q \
 && git config user.email harness@lemans.test \
 && git config user.name lemans \
 && echo "a task lives here" > README.md \
 && git add -A \
 && git commit -qm baseline
