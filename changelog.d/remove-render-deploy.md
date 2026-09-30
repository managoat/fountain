### Upgrade notes

- **Render is no longer a supported host** (#PR). Fountain cannot run on
  Render with the credential broker on, and the broker is becoming
  mandatory. `render.yaml` and the Render guide are gone, and
  `RENDER_EXTERNAL_URL` no longer stands in for `PUBLIC_URL`. An instance
  still on Render must set `PUBLIC_URL` explicitly to keep booting, and
  should move to another host.
