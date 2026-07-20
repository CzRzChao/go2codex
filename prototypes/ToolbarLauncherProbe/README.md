# Toolbar Launcher Probe

This probe builds a valid Apple Silicon-only dual-entry application bundle for Finder toolbar installation testing. Both entries display as `Go2Codex Debug`, while the nested toolbar entry uses the debug Launcher bundle identifier.

The nested Launcher has no Finder, terminal, Codex, or Claude integration. When invoked normally it shows one local confirmation dialog and exits. Passing `--self-test` prints a message and exits without presenting UI.

The build script requires an output directory that does not already exist:

```sh
./build-probe.sh /tmp/go2codex-probe
```

The resulting Finder target is:

```text
/tmp/go2codex-probe/Go2Codex Debug.app/Contents/Applications/Go2CodexToolbarLauncherDebug.app
```

Building the bundle does not read or write Finder preferences and does not restart Finder.
