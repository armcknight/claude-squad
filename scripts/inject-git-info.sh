#!/bin/sh
# Writes git commit hash and branch name into an xcconfig file
# so they can be embedded in Info.plist at build time.

GIT_COMMIT=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git -C "${SRCROOT}" symbolic-ref --short HEAD 2>/dev/null || echo "detached")

cat > "${SRCROOT}/config/GitInfo.xcconfig" <<EOF
GIT_COMMIT_HASH = ${GIT_COMMIT}
GIT_BRANCH_NAME = ${GIT_BRANCH}
EOF
