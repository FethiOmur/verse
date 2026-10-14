#!/bin/sh
# Refresh the verbatim copy of the production matcher (read-only source).
cp "$(dirname "$0")/../../../app/Sources/VerseTurns/Bank.swift" "$(dirname "$0")/Sources/ngramref/Bank.swift"
shasum -a 256 "$(dirname "$0")/Sources/ngramref/Bank.swift"
