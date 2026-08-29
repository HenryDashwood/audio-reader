#!/bin/sh

set -eu

# Xcode Cloud's Test workflow is manual-only; GitHub Actions owns automatic CI.
# Hearful uses only Apple's system voices, so there is no speech-model or
# package bootstrap step in Xcode Cloud.
