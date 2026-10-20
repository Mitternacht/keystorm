# Keystorm website

Static site: plain HTML, CSS and a little JavaScript. No build step, no frameworks, no trackers, no external fonts or CDNs.

- `index.html`: product page
- `privacy.html`: privacy page
- `assets/css/site.css`, `assets/js/site.js`, `assets/img/`: styles, script, icons and the link-preview image (`og.jpg`)

All links and asset paths are relative, so the site works at `https://mitternacht.github.io/keystorm/`.

## Preview locally

```bash
python3 -m http.server 4173 --directory website
```

Then open http://localhost:4173.

## Publish with GitHub Pages (personal account)

The repo is `github.com/Mitternacht/keystorm`, and the site is served from the `website/` folder by a GitHub Actions workflow.

1. Add `.github/workflows/pages.yml` to the repo:

   ```yaml
   name: Pages
   on:
     push:
       branches: [main]
       paths: ["website/**"]
     workflow_dispatch:
   permissions:
     contents: read
     pages: write
     id-token: write
   concurrency:
     group: pages
     cancel-in-progress: true
   jobs:
     deploy:
       runs-on: ubuntu-latest
       environment:
         name: github-pages
         url: ${{ steps.deployment.outputs.page_url }}
       steps:
         - uses: actions/checkout@v4
         - uses: actions/configure-pages@v5
         - uses: actions/upload-pages-artifact@v3
           with:
             path: website
         - id: deployment
           uses: actions/deploy-pages@v4
   ```

2. On GitHub: **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. Push to `main`. The site appears at `https://mitternacht.github.io/keystorm/`.

## Keeping it honest

The page only states what the app does today (see the repository README). Interface visuals are HTML/CSS recreations, never desktop screenshots. Update the copy when a feature changes, and keep the line that says which modes are tuned for which languages accurate.
