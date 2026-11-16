# drupal-testing

Docker images for testing Drupal projects in CI.

## Images

| Image | Dockerfile target | Platforms | Published | Contents |
| --- | --- | --- | --- | --- |
| `ghcr.io/drupal-canvas/drupal-testing` | `default` | amd64, arm64 | On pushes to `main` and `v*` tags | PHP 8.3 + Apache, Node.js 24, Composer, Chrome for Testing + ChromeDriver, all Playwright browsers and their OS dependencies. |
| `ghcr.io/drupal-canvas/drupal-testing/chromium` | `chromium` | amd64, arm64 | On pushes to `main` and `v*` tags | The above, but with only Playwright's Chromium and the OS dependencies it needs. Same tags as the generic image. |
| `ghcr.io/drupal-canvas/drupal-testing/canvas:nightly` | `canvas` | amd64 | Nightly, or by hand from the Actions tab | The Chromium image's OS dependencies (no generic Playwright browsers), plus warm caches for [Drupal Canvas](https://www.drupal.org/project/canvas). |

### Canvas image

The `canvas` image has one tag, `nightly`, which is rebuilt every night against
Canvas's `1.x` branch. A throwaway build stage clones Canvas (`CANVAS_REF`,
default `1.x`) and goes through the same install steps Canvas's CI does:

- the Composer `create-project` + `require`, once for `DRUPAL_CORE` and once for
  `DRUPAL_CORE_NEXT_MINOR`, both read from Canvas's `.gitlab-ci.yml` (override
  with `--build-arg DRUPAL_CORE=...` / `--build-arg DRUPAL_CORE_NEXT_MINOR=...`)
- `npm ci` and `npm run build -w ui`
- `npx playwright install --only-shell chromium` (Canvas only tests in headless
  Chromium) and `npx cypress install`

Only the resulting caches are copied into the image, under `/opt/canvas-cache`:

| Cache | Set by | Path |
| --- | --- | --- |
| Composer | `COMPOSER_CACHE_DIR` | `/opt/canvas-cache/composer` |
| npm | `npm_config_cache` | `/opt/canvas-cache/npm` |
| Turborepo | `TURBO_CACHE_DIR` | `/opt/canvas-cache/turbo` |
| Playwright | `PLAYWRIGHT_BROWSERS_PATH` | `/opt/canvas-cache/ms-playwright` |
| Cypress | `CYPRESS_CACHE_FOLDER` | `/opt/canvas-cache/cypress` |
| Astro | The repo's `.cache/astro` | `/opt/canvas-cache/astro` |
| TypeScript | The repo's `.cache/tsc` | `/opt/canvas-cache/tsc` |

The first five are environment variables in the image, so tools pick them up
unless CI overrides them. Canvas's `.gitlab-ci.yml` currently sets them to
`$CI_PROJECT_DIR/.cache/*`, so those variables need removing to use the image's
caches. Astro and TypeScript use the repo's own `.cache` directory, so link
those in:

```sh
mkdir -p "$CI_PROJECT_DIR/.cache"
ln -sfn "$CANVAS_CACHE_DIR/astro" "$CI_PROJECT_DIR/.cache/astro"
ln -sfn "$CANVAS_CACHE_DIR/tsc" "$CI_PROJECT_DIR/.cache/tsc"
```

`composer config --global cache-files-maxsize 2GiB` itself.

Canvas's CI should install Playwright browsers the same way. A bare
`npx playwright install` downloads every browser on every job.

`nightly` is a moving tag, so the GitLab runner needs to pull it each time
(`pull_policy: always`, or `[always, if-not-present]`) rather than reuse a
stale local copy.

Build locally:

```sh
docker buildx build --platform linux/amd64 --target canvas -t drupal-testing-canvas .
```
