#!/usr/bin/env bash
set -euo pipefail
bin="$(mktemp -t dockmint-invoker-tests)"
trap 'rm -f "$bin"' EXIT
swiftc -parse-as-library Dockmint/DockDecisionEngine.swift Dockmint/AppExposeInvoker.swift \
    tools/app_expose_invoker_tests.swift -o "$bin"
"$bin"
