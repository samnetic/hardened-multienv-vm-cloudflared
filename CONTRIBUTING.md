# Contributing to Hardened Multi-Environment VM

Thank you for considering contributing to this project! We welcome contributions from the community.

## How to Contribute

### Reporting Bugs

If you find a bug, please create an issue with:

- **Clear title** - Describe the issue concisely
- **Environment details** - OS version, cloud provider, etc.
- **Steps to reproduce** - Exact commands you ran
- **Expected behavior** - What you expected to happen
- **Actual behavior** - What actually happened
- **Logs** - Relevant error messages or logs

### Suggesting Features

Feature requests are welcome! Please create an issue with:

- **Use case** - Why this feature would be useful
- **Proposed solution** - How you envision it working
- **Alternatives considered** - Other approaches you've thought about

### Contributing Code

1. **Fork the repository**
   ```bash
   gh repo fork samnetic/hardened-multienv-vm-cloudflared --clone
   cd hardened-multienv-vm-cloudflared
   ```

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Follow existing code style
   - Add comments for complex logic
   - Update documentation if needed

4. **Test your changes**
   - Test on fresh Ubuntu 22.04/24.04 VM
   - Verify all setup steps work
   - Run verification script: `./scripts/verify-setup.sh`

5. **Commit with clear messages**
   ```bash
   git commit -m "feat: Add feature description"
   ```

   Follow [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation changes
   - `refactor:` - Code refactoring
   - `test:` - Test additions/changes
   - `chore:` - Maintenance tasks

6. **Push and create PR**
   ```bash
   git push origin feature/your-feature-name
   gh pr create --title "Your PR title" --body "Description of changes"
   ```

## Development Setup

### Prerequisites

- Ubuntu 22.04 or 24.04 LTS (or VM for testing)
- Git
- GitHub CLI (`gh`)
- Basic knowledge of Bash scripting

### Testing Changes

**Option 1: Local VM**
```bash
# Start fresh VM (VirtualBox, VMware, etc.)
# Run your modified bootstrap script
curl -fsSL http://your-test-server/bootstrap.sh | sudo bash
```

**Option 2: Cloud VM**
```bash
# Create test VM on cloud provider
# SSH to VM
# Clone your fork and run setup
git clone https://github.com/YOUR_USERNAME/hardened-multienv-vm-cloudflared.git /opt/hosting-blueprint
cd /opt/hosting-blueprint
sudo ./setup.sh
```

### Code Style

- **Bash scripts**: Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- **Line length**: Keep under 100 characters when possible
- **Comments**: Explain WHY, not WHAT (code should be self-documenting)
- **Error handling**: Use `set -euo pipefail` in scripts
- **Functions**: One purpose per function, clear naming

### Documentation

When adding features:
- Update relevant docs in `docs/` directory
- Update `README.md` if user-facing
- Add examples where helpful
- Keep documentation concise and scannable

## Security

If you discover a security vulnerability:

1. **DO NOT** create a public issue
2. Email: security@samnetic.com (or create private security advisory)
3. Include:
   - Description of vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We take security seriously and will respond promptly.

## Pull Request Review Process

1. **Automated checks** - GitHub Actions will run verification
2. **Code review** - Maintainers will review your changes
3. **Testing** - We may test on multiple cloud providers
4. **Merge** - Once approved, we'll merge your PR

**Review time:** Typically 2-7 days depending on complexity.

## What We're Looking For

### High Priority
- Security improvements
- Cloud provider compatibility (Oracle, AWS, GCP, Azure, DigitalOcean, etc.)
- Setup experience improvements
- Bug fixes
- Documentation improvements

### Medium Priority
- New features (discuss in issue first)
- Performance optimizations
- Monitoring/observability enhancements
- GitOps workflow improvements

### Low Priority
- Code style refactoring (unless it improves readability significantly)
- Optional features that increase complexity

## Questions?

- **General questions**: Create a GitHub Discussion
- **Bug reports**: Create an issue with bug template
- **Feature requests**: Create an issue with feature template
- **Security**: Email security@samnetic.com

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Code of Conduct

This project adheres to the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

---

Thank you for contributing to making VM security more accessible! 🔒
