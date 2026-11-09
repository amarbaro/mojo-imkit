# Changelog

Full notes in `docs/releases/`. Newest first. Format: the release-note template.

- [v0.8.1](docs/releases/v0.8.1.md) (2026-11-09): 5.6 MB instead of 13.5 MB for a render_into app; nine bug fixes.
- [v0.8.0](docs/releases/v0.8.0.md) (2026-11-09): three themes, UTF-8 text, slider/menu/scroll/table/plot, animation, DPI, backdrop blur, render_into (-70% frame)
- [v0.7.3](docs/releases/v0.7.3.md) (2026-11-09): text field no longer aborts on long input (String capacity bug); bounded SDL text read
- [v0.7.2](docs/releases/v0.7.2.md) (2026-11-08): typed text, `Ui.field`, `Layer.set_image`, button colour, pushed-text lifetime fix
- [v0.6.4](docs/releases/v0.6.4.md) (2026-11-08): packaging: compiler pin to build minor
- [v0.6.3](docs/releases/v0.6.3.md) (2026-11-07): docs: CHANGELOG names no home path
- [v0.6.2](docs/releases/v0.6.2.md) (2026-11-04): builds on the Mojo 1.3 nightly; conda recipe; ui.fmt removed
- [v0.6.1](docs/releases/v0.6.1.md) (2026-10-29): builds on the stable Mojo 1.2.0 and MAX 26.7.0 release
- [v0.6.0](docs/releases/v0.6.0.md) (2026-10-26): Audio stream, public packaging: CI script, CPU Ui test, API page
- [v0.5.0](docs/releases/v0.5.0.md) (2026-10-09): Window.key_down: keys held between press and release (hold-to-act controls)
- [v0.4.0](docs/releases/v0.4.0.md) (2026-10-09): Layer on the app's context, compact tile bins (23 KB per frame, ~15 % faster render), unfinished frames refused
- [v0.3.0](docs/releases/v0.3.0.md) (2026-10-09): images: Ui.image draws the app's own RGBA pixels inside the UI
- [v0.2.1](docs/releases/v0.2.1.md) (2026-10-09): scripted mode ignores a real mouse (SDL3 gives it which = 0)
- [v0.2.0](docs/releases/v0.2.0.md) (2026-10-09): Reusable Layer owns compose buffers, kernel, and host RGBA output
- [v0.1.0](docs/releases/v0.1.0.md) (2026-10-09): first release: imkit, an immediate-mode GUI for Mojo drawn on the GPU (window, font, ui), split out of the host app
