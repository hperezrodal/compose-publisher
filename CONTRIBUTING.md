# Contributing to Compose-Publisher

Thank you for your interest in contributing to Compose-Publisher! This document provides guidelines and instructions for contributing to this Ansible collection focused on container development and deployment.

## Prerequisites

Before you start contributing, make sure you have the following tools and knowledge:

### Required Tools

1. **Ansible**
   - Version 2.9 or higher
   - Basic understanding of Ansible concepts
   - Experience with playbooks and roles

2. **Docker**
   - Version 20.10.0 or higher
   - Docker Compose
   - Understanding of container concepts
   - Experience with multi-container applications

3. **Git**
   - Basic Git knowledge
   - GitHub account
   - Understanding of branching and pull requests

4. **Development Environment**
   - A text editor or IDE (VS Code, Vim, etc.)
   - Terminal emulator
   - Local Docker environment for testing
   - Access to remote hosts for testing deployments

### Recommended Knowledge

1. **Container Development**
   - Dockerfile best practices
   - Multi-stage builds
   - Container optimization
   - Security considerations

2. **Ansible Development**
   - Collection structure
   - Role development
   - Playbook best practices
   - Variable management
   - Inventory management

3. **Development Practices**
   - Version control best practices
   - Code review process
   - Testing methodologies
   - Documentation standards

### System Requirements

- **Operating System**: Linux or macOS
- **CPU**: 2+ cores recommended
- **RAM**: 4GB minimum, 8GB recommended
- **Storage**: 10GB free space minimum
- **Network**: Stable internet connection for Docker pulls and updates

### Setting Up Your Environment

1. Install Ansible:
   ```bash
   # For Ubuntu/Debian
   sudo apt-get update
   sudo apt-get install ansible
   ```

2. Install Docker:
   ```bash
   sudo apt-get install docker.io docker-compose
   sudo usermod -aG docker $USER
   ```

3. Clone the repository:
   ```bash
   git clone https://github.com/hperezrodal/compose-publisher.git
   cd compose-publisher
   ```

4. Install the collection:
   ```bash
   ansible-galaxy collection install hperezrodal.compose-publisher
   ```

## Code of Conduct

By participating in this project, you agree to abide by our Code of Conduct. Please be respectful and considerate of others.

## How to Contribute

### Reporting Issues

1. Check if the issue has already been reported in the [Issues](https://github.com/hperezrodal/compose-publisher/issues) section
2. If not, create a new issue with:
   - A clear, descriptive title
   - Detailed description of the problem
   - Steps to reproduce
   - Expected vs actual behavior
   - Environment details (OS, Ansible version, Docker version)
   - Any relevant error messages or logs

### Feature Requests

1. Check if the feature has already been requested
2. Create a new issue with:
   - A clear, descriptive title
   - Detailed description of the feature
   - Use cases and benefits
   - Any relevant examples or references

### Pull Requests

1. Fork the repository
2. Create a new branch for your feature/fix:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. Make your changes following the coding standards
4. Test your changes thoroughly
5. Update documentation if necessary
6. Submit a pull request with:
   - A clear description of the changes
   - Reference to any related issues
   - Examples of usage if applicable

## Development Guidelines

### Code Standards

- Follow Ansible best practices:
  - Use meaningful variable names
  - Add comments for complex logic
  - Follow the existing code style
  - Use proper indentation
  - Include error handling

### Collection Development

1. When adding new roles:
   - Follow Ansible role structure
   - Document all variables
   - Add appropriate error handling
   - Include tests
   - Update documentation

2. For playbook changes:
   - Use meaningful names
   - Include proper error handling
   - Document all variables
   - Keep security best practices in mind
   - Test with different environments

### Implemented Roles

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

### Testing

1. Test your changes locally:
   - Build and test containers
   - Test deployment to local environment
   - Test deployment to remote environment
   - Verify all features work as expected

2. Test edge cases and error conditions
3. Ensure backward compatibility
4. Document test cases

### Documentation

1. Update README.md for:
   - New features
   - Configuration changes
   - Usage examples
   - Breaking changes

2. Add inline comments for:
   - Complex logic
   - Configuration options
   - Environment variables
   - Required parameters

## Release Process

1. Version numbering follows [Semantic Versioning](https://semver.org/)
2. Create a release branch:
   ```bash
   git checkout -b release/vX.Y.Z
   ```
3. Update version numbers and changelog
4. Create a pull request for review
5. After approval, merge and tag the release

## Getting Help

- Open an issue for questions
- Join our community discussions
- Check the documentation

## License

By contributing to this project, you agree that your contributions will be licensed under the project's MIT License. 