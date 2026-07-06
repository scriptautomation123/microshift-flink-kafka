# External Access Scripts

This directory contains the additive deployment and validation scripts for the Kafka external-access overlay.

## Files

- `lib.sh`: shared shell helpers.
- `render.sh`: renders the overlay into `.rendered/<mode>/`.
- `deploy.sh`: applies the rendered manifests.
- `check.sh`: validates the rendered overlay and prints broker bootstrap details.

## Usage

```bash
cd kafka/openshift/external-access
cp env/example.env env/dev.env
# edit env/dev.env

scripts/render.sh env/dev.env
scripts/deploy.sh env/dev.env
scripts/check.sh env/dev.env
```

## Supported Modes

- `nodeport`
- `loadbalancer`

Set `EXTERNAL_ACCESS_MODE` in the env file before rendering or deploying.
