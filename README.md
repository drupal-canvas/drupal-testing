# drupal-testing

Docker images for testing Drupal projects in CI.

## Images

| Image | Dockerfile target | Contents |
| --- | --- | --- |
| `ghcr.io/drupal-canvas/drupal-testing` | `default` | PHP 8.3 + Apache, Node.js 24, Composer, Chrome/ChromeDriver, Playwright browsers. |
| `ghcr.io/drupal-canvas/drupal-testing/canvas` | `canvas` | The above, plus warm caches for [Drupal Canvas](https://www.drupal.org/project/canvas). |

### Canvas image

The `canvas` target clones Canvas (`CANVAS_REF`, default `1.x`) and goes through
the same install steps Canvas's CI does: `npm ci`, `npm run build -w ui`,
`npx playwright install`, `npx cypress install`, and the Composer
`create-project` + `require` for the `DRUPAL_CORE` version set in Canvas's
`.gitlab-ci.yml` (override with `--build-arg DRUPAL_CORE=...`). Then it deletes the checkout
and keeps only the caches, under `/opt/canvas-cache`. Both images are rebuilt
nightly (and can be triggered by hand from the Actions tab), so the `main` tag
follows Canvas's `1.x` branch:

| Cache | Env var | Path |
| --- | --- | --- |
| Composer | `COMPOSER_CACHE_DIR` | `/opt/canvas-cache/composer` |
| npm | `npm_config_cache` | `/opt/canvas-cache/npm` |
| Turborepo | `TURBO_CACHE_DIR` | `/opt/canvas-cache/turbo` |
| Playwright | `PLAYWRIGHT_BROWSERS_PATH` | `/opt/canvas-cache/ms-playwright` |
| Cypress | `CYPRESS_CACHE_FOLDER` | `/opt/canvas-cache/cypress` |

Canvas's `.gitlab-ci.yml` sets these variables to `$CI_PROJECT_DIR/.cache/*`,
which overrides the image. To use the baked-in caches, remove those variables
from the CI config, or seed the GitLab cache from the image before installing:

```sh
mkdir -p .cache && cp -an /opt/canvas-cache/. .cache/
```

Build locally:

```sh
docker buildx build --target canvas -t drupal-testing-canvas .
```
