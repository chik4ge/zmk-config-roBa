# zmk-config-roBa

<img src="keymap-drawer/roBa.svg" >

## Local build

This repository can be built locally with Docker.

```bash
./scripts/local-build.sh
```

The script automatically refreshes the workspace or forces pristine builds when
`config/west.yml`, `build.yaml`, `config/`, `boards/`, or `zephyr/module.yml`
changes.

Build only one target:

```bash
./scripts/local-build.sh roBa_R
./scripts/local-build.sh roBa_L
./scripts/local-build.sh settings_reset
```

Force image refresh, west update, and pristine builds:

```bash
./scripts/local-build.sh --pull --update --pristine
```

Artifacts are written to `dist/`.
