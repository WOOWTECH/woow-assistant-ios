#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Compile and exercise the real App/LearningStore along with every transcript core suite.
# The checker never executes its compiled live entry point.
exec python3 scripts/check_transcript_references_app.py
