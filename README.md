# dopt - Dynamic Optional Package Manager

> **The Backstory:** I use Fedora, and most of the standalone apps I use come packaged as `.tar.gz` archives. This means that whenever there is an update, I have to manually go through the entire extraction and installation process all over again, which gets frustrating. I made this script to help me install and update those apps automatically. I don't know if anyone else has this exact issue, but if you do, I hope this helps you!
> 
> *Note: For those in need of something a bit more sophisticated, I created a repo for the main dopt project in Golang over at [Ominous-Josef/dopt](https://github.com/Ominous-Josef/dopt).*

`dopt` is a lightweight, manifest-driven package manager engine for standalone Linux software. It automates downloading, extracting, installing, and setting up desktop integration for applications distributed as tarballs.

## Features
- **JSON Manifest Driven:** Configuration is entirely externalized to simple JSON files.
- **Architecture Awareness:** Automatically pulls the correct binary (x86_64 vs aarch64) based on the host architecture.
- **Desktop Integration:** Automatically creates `.desktop` files for GUI applications and binds them to icons found within the package.
- **Process Management:** Detects if the target application is running, safely terminates it before upgrading, and can restart it automatically afterwards.
- **Flexible Deployments:** Install straight from a network URL, from a local archive file, or let `dopt` scan a directory for the latest matching version.

## Prerequisites
`dopt` relies on standard Unix utilities, but specifically requires:
- `bash` (4.0+)
- `curl` (for network downloads)
- `jq` (for parsing the JSON manifest)

```bash
# Example prerequisite installation (Fedora/RHEL)
sudo dnf install jq curl
```

## Usage

### Syntax
```bash
sudo ./dopt.sh [options]
```

> [!WARNING]
> Security Notice: `dopt` requires `root` privileges (`sudo`) to execute, as it creates symlinks in `/usr/local/bin` and installs desktop entries to `/usr/share/applications`. Ensure you trust the URLs provided in your manifest files.

### Options

**Manifest (Optional):**
- `-m, --manifest <json>`: The path to the application manifest recipe.
- `-a, --app-id <id>`: Provide the App ID directly if running without a manifest.

If no manifest is provided, `dopt` will launch an **Interactive Wizard** to guide you through the setup.

**Deployment Targets (Choose one):**
- `-d, --download`: Download the archive using the manifest's default server endpoint.
- `-u, --url <url>`: Download using a specific direct link, overriding the manifest.
- `-f, --file <path>`: Directly deploy from a local archive file (e.g., `app-1.0.tar.gz`).
- `-p, --path <dir>`: Scan a specific directory for the newest matching local archive.

**Modifiers:**
- `-c, --cleanup`: Delete the downloaded tarball after a successful setup.
- `-i, --install`: Force a fresh installation, bypassing user prompts if no existing version is found.
- `-h, --help`: Show the help menu.

### Examples

**1. Install/Update from the internet:**
```bash
sudo ./dopt.sh -m examples/example-manifest.json -d
```

**2. Install from a specific local archive:**
```bash
sudo ./dopt.sh -m examples/example-manifest.json -f ~/Downloads/my-app-latest.tar.gz
```

**3. Scan the `~/Downloads` folder for the newest release and clean up the archive after:**
```bash
sudo ./dopt.sh -m examples/example-manifest.json -p ~/Downloads -c
```

## The Manifest File (`recipe.json`)

The manifest is a JSON file that defines the application parameters. See `examples/example-manifest.json` for a full template.

### Fields

| Field | Type | Description |
|---|---|---|
| `app_id` | String | A unique identifier (e.g., `com.myorg.app`). Used for naming backup files and desktop entries. |
| `name` | String | The human-readable name of the application. |
| `comment` | String | A short description used in the `.desktop` file. |
| `default_install_dir` | String | Where the application should be placed if it isn't already installed (e.g., `/opt/my-app`). |
| `binary_pattern` | String | The filename pattern of the executable inside the archive. `dopt` will search for this to symlink. |
| `binary_path` | String | *(Optional)* The exact relative path to the binary within the archive. Overrides `binary_pattern`. |
| `cli_only` | Boolean/String | Set to `"true"` if the application has no GUI. Prevents `.desktop` file creation. |
| `symlink_as` | String | The name of the symlink created in `/usr/local/bin` (e.g., `myapp`). |
| `categories` | String | Categories for the `.desktop` file (e.g., `Utility;Development;`). |
| `exec_flags` | String | *(Optional)* Default flags appended to the binary in the `.desktop` Exec line. |
| `default_url_x64` | String | The URL to download the `x86_64` Linux tarball. |
| `default_url_arm64` | String | The URL to download the `aarch64` Linux tarball. |

## Disclaimer & Security Responsibility

> [!CAUTION]
> **No Cryptographic Verification:** `dopt` is a deployment engine. It **does not** cryptographically verify signatures or the safety of the payloads it installs. 
> 
> Because `dopt` runs with `sudo` privileges to install system-wide applications:
> - You must 100% trust the source `URL` you provide.
> - You are responsible for verifying the integrity of any `manifest.json` file you download from the internet.
> - You are responsible for verifying the integrity of local `.tar.gz` archives before passing them to `dopt`.

## Limitations & Future Work

- **Archive format:** Currently, `dopt` strictly expects standard `tar.gz` (`.tar.gz`) archives.
- **Hardcoded paths:** System paths for bins (`/usr/local/bin`) and desktop files (`/usr/share/applications`) are hardcoded.
- **Deletions:** The update process deletes the existing `INSTALL_DIR` before copying the new framework. While safeguards exist to protect core OS directories, misconfigurations could still be dangerous. Use with caution!
