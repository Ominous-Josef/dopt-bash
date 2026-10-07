# dopt - Directory Optional Package Manager

> **The Backstory:** I use Fedora, and most of the standalone apps I use come packaged as `.tar.gz` archives. This means that whenever there is an update, I have to manually go through the entire extraction and installation process all over again, which gets frustrating. I made this script to help me install and update those apps automatically. I don't know if anyone else has this exact issue, but if you do, I hope this helps you!
> 
> *Note: For those in need of something a bit more sophisticated, I created a repo for the main dopt project in Golang over at [Ominous-Josef/dopt](https://github.com/Ominous-Josef/dopt).*

`dopt` is a small, manifest-driven helper for installing and updating standalone Linux apps that ship as `.tar.gz` archives: the unofficial tarballs no package manager tracks. It downloads (or picks up) the archive, installs it into an opt folder (`~/.local/opt` by default, or `/opt` system-wide), links a command into your `PATH`, and creates a desktop shortcut. It works alongside your system package manager, not instead of it.

## Features
- **JSON Manifest Driven:** Configuration is entirely externalized to simple JSON files.
- **Architecture Awareness:** Automatically pulls the correct binary (x86_64 vs aarch64) based on the host architecture.
- **Desktop Integration:** Automatically creates `.desktop` files for GUI applications and binds them to icons found within the package.
- **Process Management:** Detects if the target application is running, safely terminates it before upgrading, and prompts to launch the app after deployment.
- **Graceful Aborts:** Any unexpected failure or cancellation post-download will automatically rescue the payload and generate a fast-resume command.
- **Interactive Recovery:** If a local package scan fails, it doesn't just crash—it prompts you to dynamically provide a URL or exact path instead.
- **Conflict Resolution:** Safely detects when you try to update a global app locally, offering to auto-escalate with `sudo` or safely isolate the new local desktop shortcut.
- **Smart Updates:** When updating interactively, `dopt` reads the previous installation's command link and desktop shortcut to auto-populate the setup wizard.
- **App Discovery:** If you forgot the App ID for an update, type `?` in the wizard to list the apps `dopt` installed (and any other folders in your opt directory).
- **Safe Updates:** New versions are staged and verified before being swapped in, with automatic rollback on failure. `dopt` never touches package-managed folders or commands it didn't create.
- **Flexible Deployments:** Install straight from a network URL, from a local archive file, or let `dopt` scan a directory for the latest matching version.

## Prerequisites
`dopt` relies on standard Unix utilities, but specifically requires:
- `bash` (4.0+)
- `curl` (for network downloads)
- `jq` (**Only required** if using a JSON manifest)
- Standard GNU/Linux tools: `tar`, `gzip`, coreutils, findutils, `pgrep` (all preinstalled on Fedora and most distributions)
- *(Optional)* `rpm` or `dpkg`, used to detect package-managed folders, and `desktop-file-validate` to check generated shortcuts

```bash
# Example prerequisite installation (Fedora/RHEL)
sudo dnf install jq curl
```

## Usage

### Syntax
```bash
./dopt.sh [options]
```

> [!WARNING]
> Security Notice: When using the `--global` flag, `dopt` requires `root` privileges (`sudo`) to execute, as it installs system-wide to `/opt` and `/usr/local/bin`. Ensure you trust the URLs provided in your manifest files.

### Installation Modes

`dopt` uses a modern, local-first architecture to keep your system safe and clean:

**1. Local Mode (Default)**
If you run `dopt` normally (without `sudo`), it installs the application into isolated folders inside your user directory.
- **App Files:** `~/.local/opt/<app-id>`
- **Executable:** `~/.local/bin/<symlink>`
- **Desktop Icon:** `~/.local/share/applications/<app-id>.desktop`

**2. Global Mode (`--global`)**
If you pass the `-g` or `--global` flag (which requires `sudo`), `dopt` installs the application system-wide so it is available to all users on the machine.
- **App Files:** `/opt/<app-id>`
- **Executable:** `/usr/local/bin/<symlink>`
- **Desktop Icon:** `/usr/share/applications/<app-id>.desktop`

### Options

**Manifest (Optional):**
- `-m, --manifest <json>`: The path to the application manifest recipe.
- `-a, --app-id <id>`: Provide the App ID directly if running without a manifest.
- `-s, --symlink-as <name>`: The command name to link. Overrides the manifest's `symlink_as` and skips the wizard prompt.

If no manifest is provided, `dopt` will launch an **Interactive Wizard** to guide you through the setup.

**Deployment Targets (Choose one):**
- `-d, --download`: Download the archive using the manifest's default server endpoint.
- `-u, --url <url>`: Download using a specific direct link, overriding the manifest.
- `-f, --file <path>`: Directly deploy from a local archive file (e.g., `app-1.0.tar.gz`).
- `-p, --path <dir>`: Scan a specific directory for the newest matching local archive.

**Modifiers:**
- `-g, --global`: Install the application system-wide to `/opt` (requires `sudo`).
- `-c, --cleanup`: After a successful setup, delete the archive: a download is simply not kept, and a local archive (`-f` or scanned) is deleted after a confirmation prompt (no prompt with `-i`).
- `-i, --install`: Skip `dopt`'s confirmation prompts. If the app is running, it is terminated automatically and relaunched after the update. Anything that would need a decision (replacing an unregistered folder, a command-name clash) aborts instead. The wizard still asks its setup questions; use a manifest for fully unattended runs.
- `-v, --version`: Show the `dopt` version.
- `-h, --help`: Show the help menu.

### Updating Applications

Updating an application is the same command as installing it. The golden rule is: **Same App ID = Update**.

When you run `dopt` with a new `.tar.gz` payload, as long as the `app_id` matches the existing installation (either defined in the JSON manifest, passed via `-a`, or typed into the interactive prompt), `dopt` will replace the old installation with the new version. No special update flags are required!

Updates are swapped in atomically: the new version is staged next to the old one and verified first, and if anything fails mid-update the previous installation is restored. `dopt` only ever installs into, and replaces, `<opt dir>/<app_id>` (`~/.local/opt/<app_id>` or `/opt/<app_id>`).

**Ownership:** `dopt` keeps a small registry in a hidden `.dopt` folder (`~/.local/opt/.dopt/` or `/opt/.dopt/`), with one file per installed app. App folders themselves are left exactly as the vendor shipped them.
- Folders owned by a system package (RPM or deb) are never touched, even if registered. `dopt` names the package and suggests either a different App ID (to install alongside it) or removing the package first.
- Registered folders are upgraded normally. Each entry records the folder's identity (inode and creation time), so if the folder was deleted and recreated by something else, it no longer counts as registered.
- Anything else (for example, installs made by older versions of `dopt`) triggers a one-time "Replace it?" prompt that shows the folder's size and contents. With `-i`, `dopt` refuses instead of asking.

When updating through the **Interactive Wizard**, your previous answers (name, command name, binary, icon, categories) are pre-filled from the existing install. Type `?` at the wizard's App ID prompt to see registered apps, plus any other folders in your opt directory.

**Command-name clashes:** `dopt` never overwrites a file in `~/.local/bin` or `/usr/local/bin` that it didn't create, and warns when the name already exists elsewhere on your `PATH` (for example `git`). You can pick a different name on the spot, continue anyway when the name only exists elsewhere on `PATH`, or abort. With `-i`, it aborts. Use `-s <name>` to set the name up front.

If an update is aborted after a download (e.g., to keep a running app open, or due to a permission error), `dopt` saves the downloaded archive into your current directory and prints the exact command to resume later without re-downloading. Only valid archives are kept, and existing files are never overwritten: an identical copy is reused, otherwise the archive is saved as `name-1.tar.gz`, `name-2.tar.gz`, and so on.

### Examples

**1. Local Install from the internet:**
```bash
./dopt.sh -m examples/example-manifest.json -d
```

**2. Global Install from a specific local archive (Requires sudo):**
```bash
sudo ./dopt.sh -g -m examples/example-manifest.json -f ~/Downloads/my-app-latest.tar.gz
```

**3. Scan the `~/Downloads` folder for the newest release and clean up the archive after:**
```bash
./dopt.sh -m examples/example-manifest.json -p ~/Downloads -c
```

**4. Interactive Install (No Manifest):**
If you don't have a manifest, you can just point `dopt` directly at a tarball. It will launch an interactive setup wizard that asks for the App ID, name, command name and binary.
```bash
./dopt.sh -f ~/Downloads/some-new-app-linux-x64.tar.gz
```

**5. Scripted Install (No Manifest):**
Bypass the interactive wizard by providing the App ID directly via the `-a` flag.
```bash
./dopt.sh -a com.some.app -f ~/Downloads/some-new-app-linux-x64.tar.gz
```

**6. Download from a Direct URL (No Manifest):**
You can also download and install straight from a direct link without needing a manifest.
```bash
./dopt.sh -a com.some.app -u https://example.com/downloads/some-app-linux.tar.gz
```

## The Manifest File (`recipe.json`)

The manifest is a JSON file that defines the application parameters. See `examples/example-manifest.json` for a full template.

### Fields

| Field | Type | Description |
|---|---|---|
| `app_id` | String | **Required.** A unique identifier (e.g., `com.myorg.app`). Used as the install folder name and for desktop entries. Letters, digits, `.`, `_` and `-` only. |
| `name` | String | *(Optional)* The human-readable name of the application. Defaults to `app_id`. |
| `comment` | String | *(Optional)* A short description used in the `.desktop` file. |
| `binary_pattern` | String | The filename pattern of the executable. `dopt` searches up to 3 levels deep (shallowest match wins) for this to symlink. Required unless `binary_path` is set. |
| `binary_path` | String | The exact relative path to the binary inside the app folder (if the archive has a single top-level folder, paths are relative to it). Overrides `binary_pattern`. Required unless `binary_pattern` is set. |
| `icon_path` | String | *(Optional)* The exact relative path or filename of the icon to use for the `.desktop` file. |
| `cli_only` | Boolean/String | *(Optional)* Set to `true` if the application has no GUI. Prevents `.desktop` file creation. |
| `symlink_as` | String | *(Optional)* The name of the command symlink created in `~/.local/bin` or `/usr/local/bin` (e.g., `myapp`). Defaults to `app_id`. Can be overridden with `-s`. |
| `categories` | String | *(Optional)* Categories for the `.desktop` file (e.g., `Utility;Development;`). Defaults to `Utility;`. |
| `exec_flags` | String | *(Optional)* Default flags appended to the binary in the `.desktop` Exec line. |
| `default_url_x64` | String | The URL to download the `x86_64` Linux tarball. |
| `default_url_arm64` | String | The URL to download the `aarch64` Linux tarball. |

## Disclaimer & Security Responsibility

> [!CAUTION]
> **No Cryptographic Verification:** `dopt` is a deployment engine. It **does not** cryptographically verify signatures or the safety of the payloads it installs. 
> 
> `dopt` installs and runs software exactly as provided. In local mode it runs as you; with `--global` it runs as root and writes to `/opt` and `/usr/local/bin`. Either way:
> - You must 100% trust the source `URL` you provide.
> - You are responsible for verifying the integrity of any `manifest.json` file you download from the internet.
> - You are responsible for verifying the integrity of local `.tar.gz` archives before passing them to `dopt`.

## Limitations & Future Work

- **Archive format:** Currently, `dopt` strictly expects standard `tar.gz` (`.tar.gz`) archives.
- **Hardcoded paths:** Depending on the mode, core structural paths (`~/.local/opt`, `/opt`, `/usr/local/bin`) are hardcoded into the engine logic.
- **Install location:** Applications always live in `<opt dir>/<app_id>`; custom install directories are not supported.
- **Platform:** GNU/Linux only (relies on GNU `find`, `stat` and `readlink`).
- **Package detection:** Only RPM and dpkg are checked. On other systems, an unregistered folder still triggers the "Replace it?" prompt.
