# Shell Environment

The `shell_environment` role provides a modern, feature-rich shell environment across all hosts with Zsh, Powerlevel10k theming, intelligent history management, and a comprehensive set of CLI tools and aliases.

## Features

- **Zsh** - Modern shell with advanced completion and scripting capabilities
- **Oh My Zsh** - Framework with plugins (git, docker, kubectl, sudo, history)
- **Powerlevel10k** - Fast, customizable prompt with git status and context information
- **Atuin** - Encrypted shell history sync across all hosts with searchable database
- **Neovim** - Modern text editor with LSP support and custom configuration
- **Modern CLI Tools**:
  - `eza` - Modern ls replacement with git integration and icons
  - `zoxide` - Smart cd replacement that learns your most-used directories
  - `fzf` - Fuzzy finder for files, history, and command completion
  - `bat` - cat with syntax highlighting and git integration
  - `ripgrep` - Fast recursive grep replacement
  - `fd` - Fast find replacement
  - `yazi` - Terminal file manager
- **Shell Aliases** - Comprehensive set of shortcuts for common operations
- **Vi Mode** - Vim keybindings in the shell (optional)

## User Targeting

The role uses a **combined approach** for determining which users receive the shell environment:

1. **Explicit users** from `shell_environment_shell_users` in host_vars
2. **Auto-discovered users** with UID >= 1000 and valid shell (not nologin/false)
3. Both lists are **combined and deduplicated**

This ensures both root (UID 0) and regular users get the shell environment.

### Configuration Example

```yaml
# host_vars/hostname.yml
shell_environment_shell_users:
  - "root:/root:/bin/bash"
```

With this configuration:
- Root gets the shell environment (from explicit list)
- Regular users (UID >= 1000) also get it (from auto-discovery)
- System service users with nologin shells are excluded

## Deployment

Deploy to a specific host:

```bash
make <hostname> tags=shell
```

Deploy to all hosts:

```bash
make site tags=shell
```

## Shell Aliases

The role provides numerous aliases for common operations:

### Docker
- `d` - docker
- `dps` - docker ps (formatted table)
- `dpsa` - docker ps -a (all containers)
- `dlog` - docker logs -f (follow logs)
- `dexec` - docker exec -it (interactive shell)

### Git
- `gst` - git status
- `glog` - git log --oneline --graph
- `gtr` - git log --oneline --graph --all

### Navigation
- `..` - cd ..
- `...` - cd ../..
- `....` - cd ../../..

### File Management
- `ls` - eza with git status and icons (if available)
- `ll` - eza -la (long format with hidden files)
- `lt` - eza --tree (tree view)
- `y` - yazi (file manager)

### Utilities
- `v`, `vi`, `vim` - neovim
- `cl` - clear screen and list files
- `x` - exit
- `reload` - reload zsh configuration

## Customization

### Per-Host Overrides

Override defaults in `host_vars/<hostname>.yml`:

```yaml
# Use minimal neovim config instead of custom
shell_environment_neovim_config_style: "minimal"

# Install only essential CLI tools
shell_environment_cli_tools: [tldr, htop]

# Disable specific features
shell_environment_p10k_enabled: false
shell_environment_atuin_integration: false
```

### User-Specific Customization

Each user can add local customizations that won't be overwritten by Ansible:

- `~/.zshrc.local` - Additional zsh configuration
- `~/.zsh_aliases.local` - Additional aliases
- `~/.config/nvim/` - Neovim configuration (if not using Ansible-managed config)

### Available Configuration Variables

See `roles/shell_environment/defaults/main.yml` for all available configuration options, including:

- Neovim version and config style
- Oh My Zsh plugins
- Powerlevel10k style (lean, classic, rainbow, pure)
- Atuin sync server address
- CLI tools list
- Feature toggles (vim mode, SSH setup, etc.)

## Atuin Shell History Sync

Atuin provides encrypted, searchable shell history synchronized across all hosts.

**Key bindings:**
- `Ctrl+R` - Search history across all hosts
- `Up Arrow` - Navigate command history

**Configuration:** The sync server address is configured in role defaults. Individual hosts can override:

```yaml
shell_environment_atuin_sync_address: "http://192.168.2.106:8888"
```

## Powerlevel10k Prompt

The default prompt style is "lean" with the following information:

**Left side:**
- User@host (colored by privilege level)
- Current time
- Current directory (truncated)
- Git status (branch, changes)
- Vi mode indicator

**Right side:**
- Exit status of last command
- Command execution time
- Background jobs
- Python virtual environment

**Configuration:** Change prompt style per host:

```yaml
shell_environment_p10k_style: "rainbow"  # lean, classic, rainbow, pure
```

## Vi Mode

Vi mode provides vim keybindings in the shell (enabled by default).

**Key features:**
- `kj` or `ESC` - Enter normal mode
- Cursor shape changes (line in insert, block in normal)
- All standard vim navigation (h, j, k, l, w, b, etc.)
- Visual mode for selecting text

**Disable per host:**

```yaml
shell_environment_vim_mode_enabled: false
```

## Troubleshooting

### Shell environment not applying to root

Ensure root is explicitly listed in host_vars:

```yaml
shell_environment_shell_users:
  - "root:/root:/bin/bash"
```

### Shell environment not applying to regular users

Check that:
1. User has UID >= 1000
2. User's shell is not `/usr/sbin/nologin` or `/bin/false`
3. Run `getent passwd | awk -F: '$3 >= 1000 && $7 !~ /nologin|false/ {print $1":"$6":"$7}'` to see discovered users

### Atuin not syncing

Verify the sync server is accessible:

```bash
curl http://192.168.2.106:8888/health
```

### Prompt not showing

Ensure Powerlevel10k is enabled and zsh is the default shell:

```bash
echo $SHELL  # Should show /bin/zsh or /usr/bin/zsh
which p10k   # Should find the p10k command
```

## Related Documentation

- [Ansible Build Commands](ansible_build_commands.md) - Deployment workflows
- [SystemD](systemd.md) - Service management
