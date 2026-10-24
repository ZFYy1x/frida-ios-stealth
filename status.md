# CI build status

- status: **failure**
- frida_version: unknown
- commit: 5fda93b2458ec3bf51c199970775e672c36c9887
- run: https://github.com/ZFYy1x/frida-ios-stealth/actions/runs/40077219535
- utc: 2026-10-24T08:16:14Z

## deb artifacts
```
no out/ dir
```

## patch report
```
# patch report  (frida root: /Users/runner/work/frida-ios-stealth/frida-ios-stealth/frida)
# Florida pinned: 6d4b2e88ebe2bace12322db93470b0e68d4240c9

SKIPPED(does-not-apply)   [florida] frida-core/0001-Florida-string_frida_rpc.patch
APPLIED                   [florida] frida-core/0002-Florida-frida_agent_so.patch
SKIPPED(does-not-apply)   [florida] frida-core/0003-Florida-symbol_frida_agent_main.patch
SKIPPED(does-not-apply)   [florida] frida-core/0004-Florida-thread_gum_js_loop.patch
SKIPPED(does-not-apply)   [florida] frida-core/0005-Florida-thread_gmain.patch
SKIPPED(does-not-apply)   [florida] frida-core/0006-Florida-protocol_unexpected_command.patch
SKIPPED(does-not-apply)   [florida] frida-core/0007-Florida-update-python-script.patch
APPLIED                   [florida] frida-core/0008-Florida-pool-frida.patch
APPLIED                   [florida] frida-core/0009-Florida-memfd-name-jit-cache.patch
APPLIED                   [florida] frida-core/0010-exec-anti-anti-frida.py.patch
APPLIED                   [florida] frida-gum/0001-Florida-pool-frida.patch
APPLIED                   [ios] frida-core/0001-ios-rpc-string-obfuscation.patch

# Patches touching linux/*, droidy/*, memfd (Linux/Android code paths) may
# apply to files present in the tree but those files are not compiled into
# the iOS/Darwin server. The anti-anti-frida.py symbol pass is ELF-oriented
# and only runs on the non-Darwin embed path; on iOS it is effectively a no-op.
# [ios] patches are re-derived for the current frida and carry the real
# iOS-relevant anti-detect edits (e.g. rpc-string obfuscation).
```

_full tail in build-tail.log on this branch_
