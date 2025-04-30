# Compose-Publisher

## Labels

![GitHub Release](https://img.shields.io/github/v/release/compose-publisher/bash-library?style=flat-square)
[![GitHub Issues](https://img.shields.io/github/issues/hperezrodal/compose-publisher)](https://github.com/hperezrodal/compose-publisher/issues)
[![GitHub Stars](https://img.shields.io/github/stars/hperezrodal/compose-publisher)](https://github.com/hperezrodal/compose-publisher/stargazers)
![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macos-lightgrey?style=flat-square)
[![License](https://img.shields.io/github/license/hperezrodal/compose-publisher)](LICENSE)

## Description

Compose-Publisher is an Ansible collection specifically designed for developers who need to quickly build and deploy Docker containers from their local development environment to remote hosts. It streamlines the workflow of building containers locally and publishing them to remote servers, making the development-to-deployment process more efficient.

Key features:
- Local container building with Docker Compose
- Automated container publishing to remote hosts
- Development environment configuration management
- Quick deployment of container stacks
- Simplified remote host setup and management

This collection is ideal for developers who:
- Build containers locally during development
- Need to quickly test changes on remote environments
- Want to maintain consistent container configurations
- Need to deploy to multiple remote hosts
- Prefer a standardized approach to container publishing

## Project Structure

### Key Files
- `galaxy.yml` - Ansible collection metadata and configuration
- `playbooks/` - Contains main Ansible playbooks:
  - `docker-build.yml` - Playbook for building Docker images
  - `deployer.yml` - Playbook for deployment tasks
  - `setup.yml` - Playbook for initial setup and configuration
- `roles/` - Custom Ansible roles
- `examples/` - Example configurations and usage scenarios

## Prerequisites

### Required Tools
- Ansible 2.9 or later
- Docker (for container-related tasks)
- Python 3.6 or later
- Git

### Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/hperezrodal/compose-publisher.git
   cd compose-publisher
   ```

2. Install the collection:
   ```bash
   ansible-galaxy collection install hperezrodal.compose-publisher
   ```

## Features
- Docker image building and management
- Automated deployment workflows
- Configuration management
- Custom Ansible roles for common tasks
- Example playbooks for quick start

## Implemented Roles

The collection includes several roles designed to handle different aspects of container development and deployment:

1. **docker-build**
   - Purpose: Manages the building of Docker images from local development
   - Key features:
     - Local image building with Docker Compose
     - Image tagging and versioning
     - Build argument management
     - Cache optimization
   - Usage: Primarily used in development workflow to build container images

2. **environment**
   - Purpose: Sets up and configures the deployment environment
   - Key features:
     - Remote host preparation
     - Docker and Docker Compose installation
     - Network configuration
     - Volume management
   - Usage: Prepares remote hosts for container deployment

3. **deployer**
   - Purpose: Handles the deployment of container stacks
   - Key features:
     - Container stack deployment
     - Service management
     - Health checks
     - Rollback capabilities
   - Usage: Deploys and manages container stacks on remote hosts

4. **setup**
   - Purpose: Initial project setup and configuration
   - Key features:
     - Project structure creation
     - Configuration file generation
     - Environment variable setup
     - Initial deployment preparation
   - Usage: Sets up new projects and initializes deployment environments

When contributing new features or modifications, ensure they align with the existing role structure and follow the established patterns.

## Usage

### Quick Start
1. Install the collection as described above
2. Review the example playbooks in the `examples/` directory
3. Create your own playbook or modify existing ones to suit your needs
4. Run your playbook:
   ```bash
   ansible-playbook your-playbook.yml
   ```

## Best Practices
- Always review and test playbooks in a development environment before production use
- Use version control for your playbooks and configurations
- Follow the principle of least privilege when setting up permissions
- Document any custom configurations or modifications
- Keep your Ansible and Python dependencies up to date

## Contributing

Contributions are always welcome! Please read the [contribution guidelines](CONTRIBUTING.md) first.

## License

MIT License - See [LICENSE](LICENSE) file for details

---

Made with ❤️ by [hperezrodal](https://github.com/hperezrodal) 