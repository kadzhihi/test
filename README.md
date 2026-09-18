# SafariJS Helper for IOSControl + Dopamine rootless

Goal:

`IOSControl Lua -> execute() -> /var/jb/usr/local/bin/safarijs -> local Web Inspector -> real MobileSafari tab -> Runtime.evaluate`

This is NOT a separate WKWebView browser and does NOT inject a tweak into MobileSafari.

## Why this route

The helper attempts to connect locally to Apple's Web Inspector Mach services and speaks the WIR `_rpc_*` protocol:
- `_rpc_reportIdentifier:`
- `_rpc_getConnectedApplications:`
- `_rpc_forwardGetListing:`
- `_rpc_forwardSocketSetup:`
- `_rpc_forwardSocketData:`
- `Runtime.evaluate`

For target-based inspection (modern iOS), it waits for `Target.targetCreated` and wraps `Runtime.evaluate` with `Target.sendMessageToTarget`.

## Important prerequisite

On the phone:

Settings -> Safari -> Advanced -> Web Inspector -> ON

Open a normal webpage in Safari before testing.

## Build

1. Upload this project to GitHub.
2. Actions -> `Build SafariJS Helper`.
3. Download artifact `SafariJS-Dopamine-rootless`.
4. Install the `.deb` in Sileo.

Installed command:

`/var/jb/usr/local/bin/safarijs`

## Commands

Probe local Web Inspector transport:

```sh
/var/jb/usr/local/bin/safarijs probe
```

List inspectable apps/pages:

```sh
/var/jb/usr/local/bin/safarijs list
```

Evaluate JavaScript:

```sh
/var/jb/usr/local/bin/safarijs eval 'document.title'
```

For IOSControl, prefer `eval-file` so quotes/newlines in JavaScript are not damaged by the shell:

```sh
/var/jb/usr/local/bin/safarijs eval-file /path/to/script.js
```

## IOSControl

Run `ioscontrol_safarijs_test.lua`.

The test:
1. opens `https://example.com` in the real Safari,
2. probes the Web Inspector transport,
3. lists targets,
4. evaluates `document.title`.

Expected final result contains `Example Domain`.

## Diagnostic behavior

This package intentionally reports the exact failing stage as JSON.

If `probe` fails at `xpc-webinspector`, the local Mach service rejected the helper or the needed debugger entitlement is not honored by the current jailbreak configuration. That is a transport/entitlement problem, not a JavaScript problem.

If `probe` succeeds but `list` finds no Safari page, check Web Inspector is enabled and Safari has a normal webpage open.

If `list` succeeds but `eval` times out, the target protocol handshake needs adjustment for that exact iOS/WebKit build.
