# Torrents as websites (plan)

> Status: **planned, not implemented.** The one piece that exists today is the
> **icon**, deliberately shaped as a favicon so the rest of this can be built on
> top of it without rework. See `folder_meta.dart` (`icon`, `iconStems`,
> `iconExts`) and `rns_service.folderIconToken`.

## The idea

A torrent here is already a **folder** with a stable key (`ntorrent1…`), signed
contents, and a `data/` directory that carries its listing. That is most of a
static website. If a torrent folder can hold `data/index.html`, then the same
thing that is a torrent is also a **site**: a stable address, content that can be
updated without the address changing, served from every seeder, no host to pay
and nothing to take down.

The unit stays the folder. Nothing new to publish, sign or fetch — a website is
just a torrent that happens to carry HTML.

## Why the icon is a favicon (the part built now)

A website names its tab icon two ways, and we mirror both exactly:

- the well-known file `/favicon.ico` → we resolve `data/favicon.*` (then
  `data/icon.*`) when the listing names no icon;
- `<link rel="icon" href="…">` → the listing's `meta.json` `"icon"` key names
  the file explicitly.

So the icon a publisher sets today (written as `data/favicon.<ext>`, and
recorded in `meta.json`) is **already** the browser-tab icon this plan needs.
`svg`/`ico` are accepted alongside the raster formats for that reason. No second
concept, no migration.

## The shape on disk

```
<torrent folder>/
  data/
    meta.json         listing (title, cat, tags, icon, …) — structured metadata
    favicon.png       the icon → the tab icon
    index.html        the site root
    style.css
    app.js
    img/…             any static asset, referenced by relative path
  <the actual shared content, if any>
```

`index.html` is optional. A torrent with no `index.html` is what it is today (a
file listing); one with it is a site. Nothing regresses.

## How it would be served

Two layers, both generic, neither implemented yet:

1. **A resolver** `folderFile(folderId, "data/index.html")` → bytes + MIME. The
   host already fetches `data/*` content-addressed (that is how the icon and
   cover arrive before a download). Serving a site is the same fetch plus a
   MIME-by-extension table and relative-path resolution within the folder.
   Refuse anything climbing out of the folder (same boundary as `_mediaName`).

2. **A gateway**, one of:
   - **in-app viewer** — a native/webview surface pointed at the resolver,
     `ntorrent1…` in the address bar, links resolved inside the folder;
   - **local HTTP gateway** — `http://127.0.0.1:PORT/<ntorrent1…>/` maps to the
     folder so any browser can open it (the extension of the NomadNet-style page
     browser already in the Reticulum wapp);
   - **`.onion`/I2P-style** long-lived address derived from the folder key, for
     opening from outside the app (further out).

The site is served from **every seeder**, so it is up as long as anyone holds
it — the same property that makes the torrent resilient makes the site
un-takedownable.

## Security (must hold before any of this ships)

- **No script trust by default.** HTML/CSS render; JavaScript is off unless the
  viewer explicitly opts a folder in. A signed folder proves *who published*,
  not *that the content is safe to run*.
- **Sandbox the origin.** Each `ntorrent1…` is its own origin; no ambient access
  to the app, the mesh identity, other folders, or the file system. A gateway
  must not let a page read `.folder.json` or anything outside `data/`/the folder.
- **Path safety.** Every in-page path resolves against the folder root and is
  refused if it escapes — the boundary `_mediaName`/`_normRel` already enforce.
- **Size/time budgets** on fetches so a hostile site cannot wedge the viewer.

## What stays generic (the HAL-separation rule)

The engine gains only generic mechanisms — a folder-file resolver with MIME, and
a viewer/gateway surface. "This folder is a website" is a property of its files
(`data/index.html` exists), not app logic baked into the core. The torrents wapp
keeps owning the torrent-specific UX. See `keep-host-generic` /
`wapps-repo-architecture`.

## Not now

Everything above except the favicon-shaped icon. This document exists so the
icon was designed to fit it, and so the next person starts from a plan rather
than a redesign.
