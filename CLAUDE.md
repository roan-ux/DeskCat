# DeskCat

## Publishing

This repo is public at github.com/roan-ux/DeskCat, and pushing to `main` publishes:

- Changes in `Sources/`, `Sounds/`, `Package.swift`, `scripts/make-app.sh` or `VERSION` build the app on GitHub and publish a new release (`.github/workflows/release.yml`). The website's Download button always serves the newest release.
- Changes in `site/` redeploy the website, https://roan-ux.github.io/DeskCat/ (`.github/workflows/pages.yml`).

So after committing a change the user asked for, push it (`git push`) so it goes live. Versions are `VERSION` plus a running number (0.1.1, 0.1.2, ...); bump `VERSION` for a bigger release.

## The website's cat

`site/cat.js` is a JavaScript port of the Mac cat (`CatSim.swift`, `CatDrawing.swift`, `Toy.swift`, `BoxView.swift`) that runs the demo on the website. It is not generated: when the cat's behaviour or drawing changes in Swift, port the same change to `site/cat.js` if it should show on the website. Two deliberate differences: the web cat is silent, and it comes out of the box sooner (the `WEB` timings). The web tail is drawn as one tapered shape that starts inside the hips.
