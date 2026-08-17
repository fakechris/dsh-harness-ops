# RELEASE — DSH plugin distribution research + dsh-harness-ops release policy

> Answers three questions: **Do we need to repackage on every update? What is the
> versioning/release mechanism? Should we publish to npm eventually?**
> 中文版：[RELEASE.md](RELEASE.md)

---

## 1. The official mechanism (research findings; official docs + live verification)

### 1.1 Two concepts

The official plugin ecosystem is built on two concepts (per the official
[publish guide](https://github.com/deepseek-harness/deepseek-harness/blob/main/docs/user/develop/basic/publish.md),
"Two concepts, two manifests"):

| Concept | Manifest | Answers |
|---|---|---|
| **bundle** (a plugin) | `dsh.bundle` (patch file) | "what does this package contribute?" — one configuration layer (cordis.patch.yml) shipped as an npm package |
| **profile** (a runnable composition) | `dsh.profile` (bundles list) | "which bundles compose this setup, in what order?" |

A bundle is what you **author and distribute**; a profile is what a user boots.
`dsh plugin` creates and maintains profiles.

### 1.2 The install command: `dsh plugin --profile <name> <pnpm args...>`

The official implementation forwards the arguments **verbatim to pnpm inside the
profile directory** (`apps/cli/src/args.ts`: "Manage a profile's plugins: forward
args to pnpm inside the profile directory"). So all four sources are valid:

```sh
dsh plugin --profile web add .                      # local checkout (pnpm link:)
dsh plugin --profile web add github:you/repo#<sha>  # git install (sources, not artifacts)
dsh plugin --profile web add your-npm-package       # npm package (prebuilt lib/)
dsh plugin --profile web add ./pkg-0.1.0.tgz        # pnpm pack tarball
```

**Live verification** (this machine, 2026-08-12): `dsh plugin --profile demo add .`
auto-initialized the profile, `pnpm link`ed the plugin, appended the bundle to
`dsh.profile.bundles`; `dsh --profile demo --dump-config` showed the
`# == @fakechris/dsh-restart-recover` layer. The production `web` profile already
follows this mechanism (bundles: `dsh-base / dsh-web-app / dsh-track / dsh-restart-recover`).

### 1.3 The git-install "build-script catch" (official wording)

A git install fetches **sources, not built artifacts**: a TypeScript package
arrives without its `lib/` output and fails to load. Two things must happen:

- **The author** ships a `prepare` script (pnpm runs it after a git install) that
  builds the published entry points **self-contained** (no dev-only context such as a
  sibling monorepo checkout). Official example: [turtle-ui](https://github.com/deepseek-harness/turtle-ui).
- **The user** allowlists the build: pnpm ≥10 refuses to run a git dependency's
  `prepare` until explicitly allowed (`pnpm-workspace.yaml` → `allowBuilds`), and the
  official guide recommends **pinning a commit** (`github:you/repo#<sha>`) so a later
  push cannot silently change what runs.

If you'd rather not ask users for the allowance, distribute built artifacts instead
(official wording) — **neither form needs any build permission**:
- **Publish to npm** with `lib/` built at `pnpm publish` time;
- **Ship a tarball** from `pnpm pack`.

### 1.4 Official stance: a registry is NOT required

> "Publishing to a registry is not required — users can install straight from a git host."
> (official publish.md)

npm registry reality: the `@deepseek-ai/*` scope has **no published packages**
(`npm view @deepseek-ai/dsh-track` → 404). The official main repo's version is
`0.0.1-rc.1` (pre-release); its version anchor is the **dated snapshot branch**
(`snapshots/YYYYMMDDTHHMMSSZ-*`), with no semver-tag convention.

### 1.5 Bundle format (confirmed by the official plugin-template)

Key `package.json` fields: `dsh.bundle.patch` (→ cordis.patch.yml), `main`/`exports`
(lib/), `files` (published-content whitelist), `private: true` (**default: not published
to npm**), a `prepare` script (auto-build on git install), and a `verify:self-contained`
script.

### 1.6 Bundle deps & artifacts (official make-dsh-plugin / bundle-plugins.md)

- **Empty dependencies is by design**: a bundle must NOT declare `@deepseek-ai/*`
  (the profile's pnpm closure injects them at mount time; declaring them fails public
  resolution). Repository plugins are the opposite.
- **Git-source install syntax**: `dsh plugin --profile web add "github:owner/repo#<commit>&path:/<subdir>"`,
  pointing at the bundle package dir (`&path:/` + leading `/`); never the repo root.
- **Two artifact routes**:
  - **Committed artifacts (official recommendation)**: `lib/` and everything `files`
    declares is committed → a git install runs no build, a true one-liner, zero extra steps;
  - **Self-building `prepare` (fallback)**: builds on git install — but pnpm ≥10 blocks
    git-dependency `prepare` by default; the user must allow it in the profile's
    `pnpm-workspace.yaml` `allowBuilds` (one extra interactive step).
- `plugins/dsh-restart-recover` currently uses the **prepare route** (`lib/` is
  gitignored); org-internal installs via `install.sh` (local checkout + pnpm link) have
  no `allowBuilds` friction. Switch to committed artifacts if we ever distribute via a
  public git source.

---

## 2. dsh-harness-ops release policy (this repo)

### 2.1 "Do we need to repackage on every update?"

**No manual packaging.** This repo is a **hybrid** (4 skills + 1 bundle plugin); each
component uses its own mechanism:

| Component | Type | Distribution/install | Update action |
|---|---|---|---|
| `skills/dsh-snapshot-ab`, `dsh-web-guard`, `dsh-session-recovery` | skill | copy into `~/.dsh/skills/` (official scan dir) | re-copy via `install.sh` |
| `plugins/dsh-restart-recover` | bundle | `dsh plugin --profile web add @fakechris/dsh-restart-recover@<version>` (published npm artifact) | `update.sh` reinstalls from npm |

The npm tarball includes `lib/`. Production profiles do not use a local `link:`,
so cleaning ignored checkout artifacts cannot prevent `dsh web` from starting.
The `prepare` script remains for plugin development and pre-publish builds. Skills need no build.

**`bash scripts/update.sh` does the whole update in one command**:
`git pull --ff-only → re-run install.sh → reinstall the bundle from npm`.

### 2.2 Versioning

- Root `VERSION` file (SemVer; currently `0.3.0`)
- git tag: `vX.Y.Z` (e.g. `v0.3.0`) per release
- `CHANGELOG.md`: one section per version, linking squash-merged PRs
- Rule: `fix:` → patch; `feat:` → minor; breaking → major (bump after merge, before tag)

### 2.3 Release flow (normalized)

```sh
# 1) Changes go through PRs (squash merge, AGENTS.md L4)
# 2) After merge: bump version + update CHANGELOG
echo "0.3.1" > VERSION
# 3) Tag and ship
git add VERSION CHANGELOG.md && git commit -m "chore(release): v0.3.1"
git tag v0.3.1 && git push origin main --tags
# 4) Consumers update
bash scripts/update.sh
```

**Release = git push + tag** (the repo is the distribution unit); the bundle
(`plugins/dsh-restart-recover`) can additionally publish to npm (see §3, updated
2026-08-13: moved to the `@fakechris` scope with `publishConfig.access=public`;
`npm publish --registry=https://registry.npmjs.org` from that directory).

### 2.4 Install

```sh
git clone https://github.com/dsh-external/dsh-harness-ops.git
bash scripts/install.sh          # skills → ~/.dsh/skills + bundle → web profile
bash skills/dsh-web-guard/scripts/install.sh   # optional: self-healing daemon
```

---

## 3. Should we publish to npm eventually?

### Verdict: **not now**; the bundle part stays publish-ready.

1. **The official guide explicitly says a registry is not required** (§1.4) — GitHub is
   the distribution unit, fully sufficient inside a private org.
2. **npm cannot distribute skills**: skills are a **directory mechanism**
   (`~/.dsh/skills/` scan); only `plugins/dsh-restart-recover` (a bundle) could be
   published. Adding npm for one sub-component means a whole extra semver/CI/permission
   surface for little gain.
3. Today, `private: true` + profile pnpm links already cover local/team installs.
4. **The official npm presence is a private restricted scope** (researched 2026-08-12):
   the official monorepo publishes to npmjs.com under the `@deepseek-ai` **private scope**
   (211 packages, `0.0.1-rc.1`, NPM_TOKEN access, GitHub Actions manual dispatch from
   `dsh-v*` tags). The public-npm 404s are the restricted design, not "not published".
   **Third parties (us) currently have no access to that private registry** (even the
   official devDep `dsh-repository-plugin` is still 404 there), so neither public nor
   private npm is realistic for third-party plugins today.

### When it WOULD be worth publishing to npm (any of these):

- **Official private registry opens to the org** (the official decision notes call the
  private npm lib the future mainstream distribution: `npx -p @deepseek-ai/dsh@0.0.1-rc.1 dsh web`)
  — then follow the official channel;
- **Public distribution** of the bundle to users outside the org (git install forces
  them to `allowBuilds`; npm prebuilt avoids that friction);
- **Semver range resolution** in profiles (`^0.3.0` instead of a pinned commit);
- **Offline tarballs** via `pnpm pack`.

Then publish only `plugins/dsh-restart-recover` (drop `private: true`, build `lib/`
before `pnpm publish`). The repo-level version (VERSION/tag) and the npm package
version can evolve independently.

---

## 4. Hub listing (automatic after release; keep it compliant)

- **Mechanism** (dsh-external/hub, private): `catalog.source.json` (human classification
  layer) + `scripts/generate.mjs` (automatic layer: GitHub API metadata, refreshed by a
  local **Agent Loop every 2 hours**; currently 241 repos).
- Unclassified repos get a "please add to catalog.source.json" warning — classification
  is not required for release, but recommended.
- **description / topics compliance** (official template):
  - description: one line "what it is + how to install", template
    `DSH plugin: <what it does>; install via <install-command>`;
  - topics: ecosystem tags (`dsh` / `deepseek-harness`, add `dsh-bundle` for bundles) +
    functional tags, 3–6 total; `gh repo edit <owner>/<repo> --add-topic ...`.
- **Self-check** (2026-08-12): dsh-harness-ops topics are compliant (6:
  `deepseek-harness` `dsh` `ops` `restart` `self-heal` `snapshot-ab`); the description
  says what it is but lacks "how to install" — add
  `install via: git clone + bash scripts/install.sh` at the next revision. The repo is
  visible in the hub automatic layer; manual classification not yet in catalog.source.json.

---

## 4. References

- Official publish guide (authoritative): `docs/user/develop/basic/publish.md` in the
  DSH main repo (`.zh.md` for Chinese).
- Official plugin template: `dsh-external/plugin-template` (referenced by make-dsh-plugin).
- Plugin-ecosystem infra: `dsh-external/plugin-registry` (make-dsh-plugin skill / hub catalog).
- Official cordis tutorial: `docs/cordis-tutorial/` (chapters 01–07).
