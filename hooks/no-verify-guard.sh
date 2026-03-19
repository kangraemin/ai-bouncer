#!/bin/bash
# no-verify-guard: PreToolUse hook
# Blocks git commands that attempt to bypass hooks via skip flags
# Prevents agents from circumventing gate enforcement
#
# Powered by block-no-verify@1.1.2
# https://github.com/tupe12334/block-no-verify

exec npx --yes block-no-verify@1.1.2
