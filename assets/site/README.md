# The documentation site's design

The pages at <https://open.noeticecho.space/reminisce-elixir/> are built by GitHub Pages'
own Jekyll from this repository's `main` (`_config.yml` says how). Their design is the
NoeticEcho organisation's: every file in this directory is a copy, byte for byte, of the
organisation's site, the repository
[NoeticEcho/NoeticEcho.github.io](https://github.com/NoeticEcho/NoeticEcho.github.io)
served at <https://open.noeticecho.space/>. Each project's docs site ships the same files.

| Here | There | What |
|---|---|---|
| `css/tokens/` | `assets/css/tokens/` | `colors.css`, `typography.css`, `spacing.css` and `base.css`, from the NoeticEcho UI design system |
| `css/fonts.css` | `assets/css/fonts.css` | The font faces, latin subset |
| `css/site.css` | `assets/css/site.css` | The pages' layout, built only from those tokens |
| `fonts/` | `assets/fonts/` | Literata, IBM Plex Sans and JetBrains Mono (WOFF2), with their licence, the SIL Open Font License 1.1, in `LICENSE.txt` |
| `theme.js` | `assets/theme.js` | The Ink / Paper switch. A reader's choice is kept in `localStorage` under `noeticecho.theme`, shared with the organisation's site |
| `images/favicon.svg`, `images/favicon.png`, `images/apple-touch-icon.png` | `favicon.svg`, `favicon.png`, `apple-touch-icon.png` | The mark, as icons |

The layout, the includes and the navigation (`_layouts/`, `_includes/`, `_data/nav.yml`)
are this site's own, the same as the organisation's other project docs but for the
project's name.

## Updating it

Never edit a file here: change it in the organisation's site, then copy it.

1. Copy the changed files from a checkout of the organisation's site, unchanged, to the
   paths in the table: for instance
   `cp ../NoeticEcho.github.io/assets/css/site.css assets/site/css/site.css`.
2. Write each copied file's new SHA-256 (`sha256sum`) in `test/site_test.exs`, which holds
   every file here to the bytes it names. For a font or a PNG, write it too in the list of
   binary files the release checks let through: they cannot read a binary file, so they
   publish one only as the bytes they name.
3. Build the site (below) and look at a page in both themes.

## Building it locally

With Ruby and Bundler, and a `Gemfile` holding `gem "github-pages", group: :jekyll_plugins`
(it is not committed, and `_config.yml` excludes it):

```sh
bundle install
bundle exec jekyll serve
```

and open <http://127.0.0.1:4000/reminisce-elixir/>.
