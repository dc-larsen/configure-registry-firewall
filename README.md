# Socket Registry Firewall configuration scripts

Machine-wide scripts that point package managers at your Socket Firewall instance (Registry mode). Deploy them to your fleet through your endpoint management tool so every package install routes through the firewall.

| Script | Platform | Run as | Deploy via |
|---|---|---|---|
| `configure-registry-firewall-macos.sh` | macOS | root | Kandji, Jamf, Intune, or any MDM custom script |
| `configure-registry-firewall-windows.ps1` | Windows | SYSTEM or Administrator | Intune, SCCM, or any endpoint management tool |

## Usage

1. Open the script for your platform.
2. Set the firewall hostname at the top (`FIREWALL_HOST` on macOS, `$FirewallHost` on Windows). Replace the `sfw.yourcompany.com:8443` placeholder with your instance.
3. Uncomment the registries your team uses. npm and PyPI are enabled by default.
4. Deploy through your endpoint management tool.

## What gets configured

Enabled by default:

| Tool | macOS | Windows |
|---|---|---|
| npm | `/etc/npmrc` | `<Node.js install>\etc\npmrc` |
| pip | `/Library/Application Support/pip/pip.conf` | `C:\ProgramData\pip\pip.ini` |
| uv | `/etc/uv/uv.toml` | `C:\ProgramData\uv\uv.toml` |

Each script also sets `NPM_CONFIG_REGISTRY`, `PIP_INDEX_URL`, and `UV_INDEX_URL` system-wide (shell profiles on macOS, machine environment variables on Windows) as a fallback for tools that ignore config files.

Available as commented-out blocks: Maven, Go, NuGet, Cargo, RubyGems, Conda.

## Safety

- Every file is backed up before it is modified.
- On any failure, all backups are restored and the script exits non-zero. No partial state is left behind.
- Re-running is safe. Existing entries are updated in place rather than duplicated.

## Notes

- **Already-running shells**: environment variables apply to new sign-ins and newly started processes. Open shells keep their old values until restarted.
- **Intune on Windows**: check "Run script in 64-bit PowerShell host" when assigning the script. The script also includes a relaunch shim that handles this automatically if the box is left unchecked.
- **Poetry**: Poetry has no global override for the default PyPI source. Each project needs a `[[tool.poetry.source]]` block in `pyproject.toml`. The exact snippet is in the comments at the bottom of each script.

## Verifying

On a configured machine:

```sh
npm config get registry
pip config list
```

Both should show your firewall hostname. A test install of any package should appear in your Socket Firewall logs.

## License

MIT. Use, modify, and redistribute these scripts freely.
