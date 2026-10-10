#!/bin/sh
# Writes git commit hash, branch name and working tree status into an xcconfig
# file so they can be embedded in Info.plist at build time. The keys match the
# ones read by Pippin's Bundle extensions (gitCommitHash, gitBranch, gitStatusClean).

GIT_COMMIT=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git -C "${SRCROOT}" symbolic-ref --short HEAD 2>/dev/null || echo "detached")

if [ -z "$(git -C "${SRCROOT}" status --porcelain 2>/dev/null)" ]; then
    GIT_STATUS_CLEAN=1
else
    GIT_STATUS_CLEAN=0
fi

cat > "${SRCROOT}/config/GitInfo.xcconfig" <<XCCONFIG
GIT_COMMIT_HASH = ${GIT_COMMIT}
GIT_BRANCH = ${GIT_BRANCH}
GIT_STATUS_CLEAN = ${GIT_STATUS_CLEAN}
XCCONFIG
