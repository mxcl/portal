# Tasks

## Serve

```sh
PORT=$(env -u FORCE_COLOR -u CLICOLOR_FORCE npx --yes get-port-cli)
npx --yes watch-http-server . -p "$PORT" -o -a localhost
```

## Portal page

The Portal source lives in `www/`. To update its published static files:

```sh
(cd www && npm ci)
npm run build
git add www portal
```

Commit and push to `gh-pages`; GitHub Pages publishes this branch to mxcl.dev.
Verify `/portal/`, `/portal/security/`, and `/portal/privacy/` after deployment.
